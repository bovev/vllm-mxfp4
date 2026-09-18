# Security hardening

How this fork runs the MXFP4 server with a narrow container boundary, and how to operate it.
`vllm-mxfp4-security-hardening.md` has the reasoning behind each item. This file describes what is
implemented and how to use it.

The hardening keeps every path that matters for performance: `/dev/kfd` and `/dev/dri`, the
ROCm/Radiance runtime, TP=2, the MXFP4/W4A8 and R4D kernels, the speculative-decoding patches, and
the persistent compile caches. It removes host privileges those paths do not need.

## The boundary

```text
serve container (serve-mxfp4.sh)
   ├── /dev/kfd, /dev/dri + render/video groups     GPU access
   ├── /models                  read-only           checkpoints and drafter
   ├── /root/.cache/huggingface read-only           tokenizer files (HF_CACHE_RW=1 to relax)
   ├── /patches                 read-only           this repo: patchers, kernels, templates
   ├── /r4d                     read-only           the pinned libr4d build
   ├── /cache                   writable            vllm / inductor / triton / aiter / hf_modules
   ├── BIND_ADDR:PORT           published           127.0.0.1:8080 by default
   │
   ✕ --privileged               removed
   ✕ --network=host             removed (own network namespace, one published port)
   ✕ --ipc=host                 removed (--shm-size 4g)
   ✕ runtime socket             never mounted (the launcher refuses to)
   ✕ Hugging Face downloads     HF_HUB_OFFLINE=1, TRANSFORMERS_OFFLINE=1, no token
   ✕ telemetry                  VLLM_NO_USAGE_STATS=1, DO_NOT_TRACK=1, HF_HUB_DISABLE_TELEMETRY=1
```

These are kept for the first deployment (plan §9) and tested separately later:
`--cap-add SYS_PTRACE` and `--security-opt seccomp=unconfined`.

The patch step inside the container writes only to the image's `site-packages`. It never writes to
`/patches`. The patched vLLM is recreated on every start from the read-only repo, so a
compromised run cannot persist changes to the code the next run executes.

The API has no authentication. It is published on loopback by default. `BIND_ADDR=0.0.0.0` is
refused unless `ALLOW_ALL_INTERFACES=1` is also set.

## Knobs

Every relaxation is its own switch. Change **one at a time**, and write down which one a failure
needed. Do not fall back to `--privileged` or host networking.

| Variable | Default | Effect |
|---|---|---|
| `BIND_ADDR` | `127.0.0.1` | Host address the API is published on. Use the server's LAN IP for LAN access |
| `ALLOW_ALL_INTERFACES` | `0` | Required to publish on `0.0.0.0` (only behind a host firewall) |
| `SHM_SIZE` | `4g` | Private `/dev/shm`. Raise to `8g`/`16g` if RCCL or the engine runs short |
| `CAP_SYS_PTRACE` | `1` | `0` drops `--cap-add SYS_PTRACE` (second stage) |
| `SECCOMP_UNCONFINED` | `1` | `0` uses the runtime's default seccomp profile (second stage) |
| `CAP_DROP_ALL` | `0` | `1` adds `--cap-drop ALL` (third stage) |
| `HF_CACHE_RW` | `0` | `1` mounts the HF cache writable. Prefer fixing the need in setup |
| `NAME` | `vllm-mxfp4-qwen38` | Container name. Only containers labelled `io.vllm-mxfp4.managed=1` are removed or replaced |
| `REQUIRE_PINS` | `0` | `1` refuses to start from a mutable image tag |

## Pins: `deploy-pins.env`

| Pin | Recorded by |
|---|---|
| `PIN_REPO_COMMIT` | `./pin-deployment.sh` (`git rev-parse HEAD`) |
| `PIN_IMAGE` | `./pin-deployment.sh`, which pulls the tag once and records `repo@sha256:<digest>` |
| `PIN_SRC_REVISION` | `./setup-mxfp4.sh` on download, or `./pin-deployment.sh` from the HF cache |
| `PIN_DRAFT_REVISION` | `./setup-mxfp4.sh` on download, or `./pin-deployment.sh` from the drafter's metadata |

`serve-mxfp4.sh`, `setup-mxfp4.sh` and `docker-quickstart.sh` use `PIN_IMAGE` as the default
`IMAGE`. `setup-mxfp4.sh` downloads exactly the pinned revisions. Commit the file once it is
filled. `./pin-deployment.sh --show` compares the host with it.

libr4d stays pinned to the fixed commit `R4D_PIN` in `serve-mxfp4.sh`. Do not move it to a branch.

## First deployment

1. Clone, then review the commit if nobody has reviewed it yet (`./review-update.sh <old> <new>`).
2. `./setup-mxfp4.sh`: downloads (bridge network, the only step that gets `HF_TOKEN`), builds the
   checkpoint (`--network=none`) and libr4d. It records the HF revisions.
3. `./pin-deployment.sh`: records the repo commit and the image digest. Commit `deploy-pins.env`.
4. `DRY_RUN=1 ./serve-mxfp4.sh`: prints the security boundary, then the full command. It starts
   and removes nothing. Check the digest, devices, name, model path, published address, and that
   only `/cache` is writable.
5. `./serve-mxfp4.sh` (or `DETACH=1`). The existing llama.cpp server stays on its own port
   (plan §21).
6. `./verify-hardening.sh`: checks `Privileged=false`, network and IPC mode not `host`, the mount
   modes, the published address, the offline env, the absence of an HF token, and `/health`.
7. By hand: `sudo ss -lntp | grep 8080` shows only the intended address. From another machine the
   API must *not* answer while `BIND_ADDR=127.0.0.1`.
8. Benchmark C1/C2/C4/C8 at TP=2, and compare with numbers from the privileged launcher.

If step 5 or 8 fails, relax one knob, retry, and record the result in the table below.

| Change | Result | Date |
|---|---|---|
| `--privileged` removed | _untested_ | |
| `--network=host` → `-p BIND_ADDR:PORT` | _untested_ | |
| `--ipc=host` → `--shm-size 4g` | _untested_ | |
| read-only mounts | _untested_ | |

## Second stage (after the server is stable)

Test one change at a time. Each test covers startup, model load, kernel compilation, TP=2, long
prefill, speculative decode, and C1/C2/C4/C8.

1. `CAP_SYS_PTRACE=0`
2. `SECCOMP_UNCONFINED=0`
3. `CAP_DROP_ALL=1`. Inspect first with `docker exec vllm-mxfp4-qwen38 capsh --print`, and add back
   only proven needs

## LAN exposure and firewall

- Set `BIND_ADDR=<server LAN IP>`. Never publish on all interfaces without a firewall.
- Restrict TCP to the port at the host firewall as well, allowing only the workstation or the
  trusted subnet. Docker-published ports bypass plain `INPUT` rules; for ufw/iptables, filter in
  the `DOCKER-USER` chain. Example:
  `iptables -I DOCKER-USER -p tcp --dport 8080 ! -s 192.168.1.0/24 -j DROP`.
- Check from the allowed machine (`curl http://<lan-ip>:8080/health`). Also check that other VLANs
  and the WAN cannot reach the port.
- For remote access use a VPN (WireGuard/Tailscale), an authenticated reverse proxy, or mTLS. Never
  expose the endpoint directly.

## Updating (no auto-updates)

Nothing here updates itself, and nothing runs `git pull`. For an update:

```text
./review-update.sh                  commits, changed files, risky added lines, pin changes
git checkout <new>                  after reading the diff of every flagged file
./pin-deployment.sh [--repin-image] only if the image is meant to move
NAME=vllm-mxfp4-test PORT=8081 ./serve-mxfp4.sh     separate test container
benchmark C1/C2/C4/C8, check outputs, check GPU stability, ./verify-hardening.sh
promote: stop the old container, serve the new commit under the production NAME/PORT
```

`review-update.sh` flags added lines that touch `subprocess`, `os.system`, `shell=True`,
`curl`/`wget`/`requests`/`urllib`/`socket`, `/etc`, `~/.ssh`, the runtime socket, `systemctl`,
`sudo`, `rm -rf`, privilege flags, `torch.load`/`pickle`, `trust_remote_code`, and downloads.

## Not covered

These launchers keep their original flags. Do not use them for the long-term service without the
same treatment:

- `serve.sh` (ParoQuant) and `setup.sh` / `setup-paroquant.sh`
- `run_*.sh`
- the research scripts under `autoround-tests/`, `paroquant/`, `escha/` and `nvfp4-tests/`

`docker-compose.yml` (FP8 path) was already unprivileged. It now uses `shm_size`, loopback
publishing (`BIND_ADDR`) and offline mode.
