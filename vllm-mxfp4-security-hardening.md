# vLLM MXFP4 Security Hardening Guide

This document defines the recommended security hardening for running `GGZ14/vllm-mxfp4` on a dual AMD Radeon AI PRO R9700 Linux server.

The goal is to preserve the performance-critical GPU and kernel paths while reducing unnecessary host privileges, network exposure, and supply-chain risk.

## Scope

This guidance applies to the repository:

`https://github.com/GGZ14/vllm-mxfp4`

The review focused on:

- `docker-quickstart.sh`
- `setup-mxfp4.sh`
- `serve-mxfp4.sh`
- `Dockerfile`
- the runtime Python patch chain
- model and dependency downloads
- container privileges and networking
- writable host mounts

## Summary recommendation

Use the repository, but do **not** run the default serving container unchanged as a long-term service.

The performance-critical parts should be retained:

- `/dev/kfd`
- `/dev/dri`
- ROCm/Radiance runtime
- TP=2
- MXFP4/W4A8 kernels
- R4D kernels
- speculative decoding patches
- compiler/cache volumes

The following broad privileges should be removed unless testing proves they are required:

- `--privileged`
- `--ipc=host`
- `--network=host`

The serving container should also use read-only mounts for model files and repository code wherever possible.

---

## 1. Pin the repository version

Do not run a moving `main` branch as a production service.

After cloning the repository, record the exact commit:

```bash
git rev-parse HEAD
```

For example:

```text
3f65d4d...
```

Keep this commit recorded with the server configuration.

Before updating later:

```bash
git fetch

git log --oneline --decorate --graph HEAD..origin/main
```

Review the changes before moving to a new commit.

Avoid automatically running `git pull` before every container restart.

---

## 2. Pin the Docker image by digest

A tag such as:

```text
stilldeadcode/vllm-radiance:0.9.3
```

is mutable.

Pull the image once:

```bash
docker pull stilldeadcode/vllm-radiance:0.9.3
```

Then inspect the immutable digest:

```bash
docker image inspect stilldeadcode/vllm-radiance:0.9.3 \
  --format '{{index .RepoDigests 0}}'
```

Record the result and use the digest in the launcher, for example:

```text
stilldeadcode/vllm-radiance@sha256:<digest>
```

This ensures that future restarts use the same image bytes.

---

## 3. Remove `--privileged`

The default launcher grants the container broad host-level access with:

```bash
--privileged
```

This should be removed.

The GPU runtime should instead receive only the devices it actually needs:

```bash
--device /dev/kfd \
--device /dev/dri
```

Also add the host render and video groups:

```bash
--group-add "$(getent group render | cut -d: -f3)" \
--group-add "$(getent group video | cut -d: -f3)"
```

Verify the groups first:

```bash
getent group render
getent group video
```

### Why

`--privileged` gives the container access to substantially more host functionality than is needed for GPU inference.

If the service works with explicit GPU device access, there is no reason to retain blanket privilege.

---

## 4. Replace host IPC with a dedicated shared-memory allocation

Remove:

```bash
--ipc=host
```

Start with:

```bash
--shm-size 4g
```

If the workload later proves to need more shared memory, increase this deliberately:

```bash
--shm-size 8g
```

or:

```bash
--shm-size 16g
```

### Why

`--ipc=host` puts the container into the host IPC namespace.

A dedicated Docker shared-memory allocation provides the memory required by inference workloads without exposing host IPC objects.

Only restore `--ipc=host` if testing demonstrates a real requirement.

> **Outcome (2026-09-19):** testing showed the requirement. With `--shm-size 4g` the TP=2 ROCm
> engine did not finish startup. With `--ipc=host`, and everything else still hardened, it served.
> `--ipc=host` is kept. `--privileged` and `--network=host` stay removed. See `HARDENING.md`.

---

## 5. Replace host networking with explicit port publishing

Remove:

```bash
--network=host
```

For initial local testing, bind the API only to loopback:

```bash
-p 127.0.0.1:8080:8080
```

This means the service is reachable only from the server itself.

When another machine on the LAN needs access, bind only to the server's LAN address.

Example:

```bash
-p 192.168.1.180:8080:8080
```

Do not publish the service on all interfaces unless that is intentional.

Avoid:

```bash
-p 8080:8080
```

unless the host firewall explicitly restricts access.

### Verify exposure

After startup:

```bash
sudo ss -lntp | grep 8080
```

For localhost-only access, the expected listener is similar to:

```text
127.0.0.1:8080
```

For LAN access, it should show only the intended LAN IP.

---

## 6. Keep model and source mounts read-only

The serving container generally needs to read model data and repository patches, but it does not need to modify them.

Use read-only bind mounts where possible.

Recommended pattern:

```bash
-v "$HF_CACHE":/root/.cache/huggingface:ro \
-v "$MODELS":/models:ro \
-v "$PATCHES":/patches:ro \
-v "$R4D_SO":/r4d:ro
```

Keep only runtime compiler/cache paths writable:

```bash
-v "$CACHE":/cache
```

If a particular startup phase needs to write into one of the otherwise read-only locations, separate setup and serving into two phases rather than leaving the mount writable permanently.

### Why

If the serving process or one of its dependencies is compromised, read-only mounts prevent it from silently modifying:

- model files
- repository source
- patch scripts
- prebuilt kernel artifacts

---

## 7. Keep Hugging Face offline mode enabled while serving

Serving should continue to use:

```bash
-e HF_HUB_OFFLINE=1
```

This prevents the inference process from unexpectedly contacting Hugging Face during normal operation.

Perform downloads explicitly during setup instead.

This makes runtime behavior easier to audit and reproduce.

---

## 8. Disable unnecessary telemetry

Keep vLLM usage telemetry disabled:

```bash
-e VLLM_NO_USAGE_STATS=1
```

This is preferable for a private/local inference server.

---

## 9. Retain required GPU and debugging permissions initially

Do not remove the following during the first hardened deployment:

```bash
--device /dev/kfd
--device /dev/dri
--cap-add SYS_PTRACE
--security-opt seccomp=unconfined
```

The device mappings are required for AMD GPU access.

`SYS_PTRACE` and unconfined seccomp are used by the Radiance/RDNA4 stack and may be required by ROCm, AITER, JIT compilation, or debugging infrastructure.

After the system is stable, these can be tested independently.

For example:

1. Remove `SYS_PTRACE` only.
2. Restart and benchmark.
3. If stable, test a normal seccomp profile separately.

Do not remove several GPU/runtime permissions at once because that makes failures difficult to diagnose.

---

## 10. Keep the Docker socket out of the container

Do not mount:

```text
/var/run/docker.sock
```

into the inference container.

A Docker socket mount effectively gives a container control over Docker on the host and can usually be converted into root-equivalent host access.

The reviewed serving path does not require this.

---

## 11. Use a unique and explicit container name

Set a dedicated container name, for example:

```bash
--name vllm-mxfp4-qwen38
```

Avoid generic names that could collide with unrelated containers.

Before launching:

```bash
docker ps -a --format '{{.Names}}'
```

This is especially important because the launcher may remove an existing container with the configured name.

---

## 12. Pin Hugging Face model revisions

The setup scripts currently use Hugging Face snapshot downloads.

For reproducible deployments, record the exact model revisions used after the first successful installation.

For future rebuilds, use a fixed revision:

```python
snapshot_download(
    repo_id="amd/Qwen3.8-27B-Quark-AWQ-MXFP4",
    revision="<commit-hash>",
)
```

Do the same for the speculative drafter model.

### Why

Without a revision pin, rebuilding the server later could download different model files even though the repository name is unchanged.

---

## 13. Keep `libr4d` pinned

The repository already uses a fixed `libr4d` commit.

Keep that behavior.

Do not replace it with an automatic build from current `main` unless the change has been reviewed and benchmarked.

For GPU kernel projects, a specific known-good commit is substantially safer than following a moving branch.

---

## 14. Treat the runtime patch chain as trusted code

The serving process executes a substantial set of local Python patchers against the vLLM installation inside the container.

These patches affect areas such as:

- MXFP4 loading
- W4A8 kernels
- tensor-parallel geometry
- all-reduce
- attention
- GDN
- KV-cache handling
- speculative decoding
- DFlash
- Qwen model support

The patch system itself includes useful safeguards such as exact-source anchors and Python syntax validation, but these scripts are still executable code.

Before moving to a new repository commit, inspect changes to patch files:

```bash
git diff <old-commit>..<new-commit> -- '*.py' '*.sh'
```

Pay particular attention to new uses of:

```text
subprocess
os.system
shell=True
curl
wget
requests
urllib
socket
/etc
/root/.ssh
/var/run/docker.sock
systemctl
sudo
rm -rf
```

---

## 15. Run the repository's dry-run mode before launch

Before starting a new configuration, use:

```bash
DRY_RUN=1 ./serve-mxfp4.sh
```

Inspect the resulting Docker command.

Verify that it does **not** contain:

```text
--privileged
--network=host
--ipc=host
```

unless those were intentionally reintroduced.

Also verify:

- expected image digest
- expected GPU devices
- expected container name
- expected model path
- expected published IP and port
- read-only source/model mounts
- only cache directories writable

---

## 16. Recommended hardened Docker pattern

A hardened serving invocation should conceptually resemble:

```bash
docker run --rm \
  --name vllm-mxfp4-qwen38 \
  --shm-size 4g \
  --device /dev/kfd \
  --device /dev/dri \
  --group-add "$(getent group render | cut -d: -f3)" \
  --group-add "$(getent group video | cut -d: -f3)" \
  --cap-add SYS_PTRACE \
  --security-opt seccomp=unconfined \
  -p 127.0.0.1:8080:8080 \
  -e HF_HUB_OFFLINE=1 \
  -e VLLM_NO_USAGE_STATS=1 \
  -v "$MODELS":/models:ro \
  -v "$HF_CACHE":/root/.cache/huggingface:ro \
  -v "$PATCHES":/patches:ro \
  -v "$R4D_SO":/r4d:ro \
  -v "$CACHE":/cache \
  stilldeadcode/vllm-radiance@sha256:<PINNED_DIGEST> \
  ...
```

The actual final command should retain the environment variables and vLLM/Radiance arguments required by `vllm-mxfp4`.

Do not replace the project's performance settings with this simplified example blindly.

The purpose of this block is to show the desired container security boundary.

---

## 17. Verify the hardened container after startup

### Check container privileges

```bash
docker inspect vllm-mxfp4-qwen38 | less
```

Useful targeted checks:

```bash
docker inspect vllm-mxfp4-qwen38 \
  --format 'Privileged={{.HostConfig.Privileged}}'
```

Expected:

```text
Privileged=false
```

Check host networking:

```bash
docker inspect vllm-mxfp4-qwen38 \
  --format 'NetworkMode={{.HostConfig.NetworkMode}}'
```

Expected:

```text
NetworkMode=default
```

or another explicit Docker network, but not:

```text
host
```

Check IPC mode:

```bash
docker inspect vllm-mxfp4-qwen38 \
  --format 'IpcMode={{.HostConfig.IpcMode}}'
```

Expected to not be:

```text
host
```

### Check published port

```bash
sudo ss -lntp | grep 8080
```

### Check mounts

```bash
docker inspect vllm-mxfp4-qwen38 \
  --format '{{range .Mounts}}{{println .Source "->" .Destination "RW=" .RW}}{{end}}'
```

Models and source mounts should show:

```text
RW=false
```

Only intended cache directories should be writable.

---

## 18. Verify API reachability intentionally

For localhost-only deployment:

```bash
curl http://127.0.0.1:8080/health
```

From another computer, the same request should fail.

For LAN deployment, test from the explicitly permitted machine:

```bash
curl http://<server-lan-ip>:8080/health
```

Also verify that other VLANs, WAN interfaces, and public IPs cannot reach the service.

---

## 19. Add firewall restrictions before LAN exposure

If the API is accessible from another machine, restrict access at the host firewall as well as through Docker binding.

For example, permit TCP port `8080` only from the main workstation or trusted LAN subnet.

The exact firewall rule depends on the firewall already configured on the server.

Do not expose an unauthenticated vLLM OpenAI-compatible endpoint directly to the public Internet.

For future remote access, prefer one of:

- VPN
- WireGuard/Tailscale
- authenticated reverse proxy
- mTLS
- API gateway

---

## 20. Do not auto-update this stack

Avoid unattended automatic updates for:

- repository source
- Docker image
- vLLM
- ROCm
- AITER
- Triton
- R4D
- speculative drafter
- target model

This project is highly optimized around a specific software combination.

Use a deliberate update workflow:

```text
review changes
    ↓
pull new versions
    ↓
run separate test container
    ↓
benchmark C1 / C2 / C4 / C8
    ↓
verify output correctness
    ↓
verify GPU stability
    ↓
promote new version
```

---

## 21. Keep the existing server service available during migration

Do not remove the existing llama.cpp deployment until the vLLM stack has passed stability testing.

Run vLLM on a separate port initially.

Example:

```text
llama.cpp     -> existing port
vLLM MXFP4    -> 8080
```

This makes rollback immediate if the experimental vLLM stack crashes, regresses, or produces incorrect output.

---

## 22. First deployment checklist

Before the first hardened launch:

- [ ] Clone repository manually.
- [ ] Record `git rev-parse HEAD`.
- [ ] Review changes if not using a previously reviewed commit.
- [ ] Pull the Radiance image manually.
- [ ] Record the Docker image digest.
- [ ] Remove `--privileged`.
- [ ] Remove `--network=host`.
- [ ] Remove `--ipc=host`.
- [ ] Add `--shm-size 4g`.
- [ ] Retain `/dev/kfd`.
- [ ] Retain `/dev/dri`.
- [ ] Retain render/video groups.
- [ ] Retain `SYS_PTRACE` initially.
- [ ] Retain `seccomp=unconfined` initially.
- [ ] Bind API to `127.0.0.1` for the first run.
- [ ] Make model/source mounts read-only.
- [ ] Leave compilation cache writable.
- [ ] Keep `HF_HUB_OFFLINE=1` while serving.
- [ ] Keep vLLM usage telemetry disabled.
- [ ] Use a unique container name.
- [ ] Run `DRY_RUN=1` and inspect the generated Docker command.
- [ ] Launch the container.
- [ ] Verify `Privileged=false`.
- [ ] Verify network mode is not `host`.
- [ ] Verify IPC mode is not `host`.
- [ ] Verify the API listener with `ss`.
- [ ] Verify models/source are mounted read-only.
- [ ] Benchmark GPU stability and TP=2 performance.

---

## 23. Second-stage hardening

After the server is stable, test whether these permissions can be reduced further.

Test one change at a time.

### Test removing `SYS_PTRACE`

Remove:

```bash
--cap-add SYS_PTRACE
```

Then test:

- startup
- model load
- kernel compilation
- TP=2
- long prefill
- speculative decode
- C1/C2/C4/C8 concurrency

If everything remains stable, leave it removed.

### Test restoring the default seccomp profile

Remove:

```bash
--security-opt seccomp=unconfined
```

Repeat the same tests.

If ROCm or compiler operations fail, restore it.

### Consider dropping additional Linux capabilities

Once stable, inspect the actual capability set:

```bash
docker exec vllm-mxfp4-qwen38 capsh --print
```

A stricter configuration could eventually start with:

```bash
--cap-drop ALL
```

and add back only the specific capability proven necessary.

This is optional and should come after the inference stack is known-good.

---

## 24. Security posture after hardening

The desired trust boundary is:

```text
vLLM MXFP4 container
        │
        ├── read access to model weights
        ├── read access to patch repository
        ├── access to AMD GPU devices
        ├── writable compiler/runtime cache
        ├── explicitly published API port
        │
        ✕ no blanket --privileged access
        ✕ no Docker socket
        ✕ no host network namespace
        ✕ no host IPC namespace
        ✕ no writable model repository
        ✕ no writable source repository
        ✕ no runtime Hugging Face downloads
```

This retains the hardware-specific performance optimizations while substantially reducing the blast radius of a compromised inference process or dependency.

---

## Recommended decision

Use `GGZ14/vllm-mxfp4`, but deploy it with the hardening above rather than accepting the default Docker privilege model unchanged.

For the first hardened version, prioritize these four container-level changes:

1. Remove --privileged.
2. Replace --ipc=host with --shm-size 4g.
3. Replace --network=host with explicit interface/port publishing.
4. Mount models, Hugging Face data, patch source, and R4D artifacts read-only during serving.

Then add these model and network-safety controls:

5. Download all model weights, tokenizer files, drafter models, and other Hugging Face artifacts deliberately during the setup phase.
6. Serve models from explicit local paths such as /models/<model-name> rather than Hugging Face repository IDs.
7. Set HF_HUB_OFFLINE=1 and TRANSFORMERS_OFFLINE=1 in the serving container so missing files fail loudly instead of triggering downloads.
8. Do not provide HF_TOKEN to the serving container. Use it only during the download/setup phase when required.
9. Keep the Hugging Face cache persistent across recreations, but mount it read-only during normal serving once startup has been verified.
10. Treat offline Hugging Face settings as application-level protection only; they do not replace Docker/network firewall restrictions.

If the stack does not work after one of these changes, restore permissions individually and document exactly which capability is required. Do not fall back immediately to --privileged or host networking.

