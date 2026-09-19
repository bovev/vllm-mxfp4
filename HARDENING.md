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
   ├── --ipc=host               KEPT                required exception, see "Host IPC" below
   │
   ✕ --privileged               removed
   ✕ --network=host             removed (own network namespace, one published port)
   ✕ runtime socket             never mounted (the launcher refuses to)
   ✕ Hugging Face downloads     HF_HUB_OFFLINE=1, TRANSFORMERS_OFFLINE=1, no token
   ✕ telemetry                  VLLM_NO_USAGE_STATS=1, DO_NOT_TRACK=1, HF_HUB_DISABLE_TELEMETRY=1
```

These are kept for the first deployment (plan §9) and tested separately later:
`--cap-add SYS_PTRACE` and `--security-opt seccomp=unconfined`.

### Validated baseline (2026-09-19, TP=2)

| Setting | Baseline |
|---|---|
| `--privileged` | **no** |
| `--ipc=host` | **yes**: required by this TP=2/ROCm stack |
| `--network=host` | **no** |
| Explicit port publishing (`-p BIND_ADDR:PORT:PORT`) | **yes** |
| `/models`, `/patches`, `/r4d` | read-only |
| HF offline mode (`HF_HUB_OFFLINE=1`, `TRANSFORMERS_OFFLINE=1`, no token) | **yes** |

### Host IPC is a required exception

The first hardened launch (all changes applied, private IPC with `--shm-size 4g`) failed. We then
changed one variable only: `--shm-size 4g` went back to `--ipc=host`. `--privileged` stayed off,
networking stayed bridged with the one published port, and the mounts stayed read-only. With that
change the server came up. The log reached

```text
Application startup complete.
API server: HTTP server started
```

so the engine finished initialising and the API was listening. The A/B result:

```text
private IPC + --shm-size 4g   -> FAIL
--ipc=host                    -> WORKS
```

`--ipc=host` is therefore the launcher default (`IPC_HOST=1`). **Do not restore `--privileged` or
`--network=host`.** Host IPC does not justify them. The other removals were all active in the
working run, so each of them is validated.

What stays open: only 4g was tested for a private `/dev/shm`. `IPC_HOST=0 SHM_SIZE=16g` is the
retest if we ever want host IPC gone again. `verify-hardening.sh` reports `IpcMode=host` as a WARN
(a known exception), not a FAIL.

The patch step inside the container writes only to the image's `site-packages`. It never writes to
`/patches`. The patched vLLM is recreated on every start from the read-only repo, so a
compromised run cannot persist changes to the code the next run executes.

The API is published on loopback by default. `BIND_ADDR=0.0.0.0` is refused unless
`ALLOW_ALL_INTERFACES=1` is also set. `/v1` requires a bearer key when `API_KEY_FILE` exists, and a
key is mandatory for any non-loopback `BIND_ADDR` (see "LAN access" below).

## Knobs

Every relaxation is its own switch. Change **one at a time**, and write down which one a failure
needed. Do not fall back to `--privileged` or host networking.

| Variable | Default | Effect |
|---|---|---|
| `BIND_ADDR` | `127.0.0.1` | Host address the API is published on. Use the server's LAN IP for LAN access |
| `ALLOW_ALL_INTERFACES` | `0` | Required to publish on `0.0.0.0` (only behind a host firewall) |
| `IPC_HOST` | `1` | Keep `--ipc=host` (required, see above). `0` uses a private `/dev/shm` of `SHM_SIZE` (retest only) |
| `SHM_SIZE` | `4g` | Private `/dev/shm` size when `IPC_HOST=0`. `4g` fails at TP=2; `8g`/`16g` untested |
| `CAP_SYS_PTRACE` | `1` | `0` drops `--cap-add SYS_PTRACE` (second stage) |
| `SECCOMP_UNCONFINED` | `1` | `0` uses the runtime's default seccomp profile (second stage) |
| `CAP_DROP_ALL` | `0` | `1` adds `--cap-drop ALL` (third stage) |
| `API_KEY_FILE` | `~/.config/vllm-mxfp4/api-key` | Bearer key for `/v1`, used if the file exists (mode `600`). Mounted read-only, exported in-container; never in `docker inspect` |
| `ALLOW_NO_AUTH` | `0` | `1` allows a non-loopback `BIND_ADDR` without a key. Don't |
| `NETWORK` | _(default bridge)_ | Docker network to join, e.g. `ai-net` for Prometheus. `host`, `none` and `container:*` are refused |
| `NETWORK_ALIAS` | `vllm-server` | DNS name on `NETWORK`, so the scrape target is `vllm-server:8080` |
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
6. `./verify-hardening.sh`: checks `Privileged=false`, network mode not `host` (IPC mode `host` is a
   WARN, the known exception), the mount
   modes, the published address, the offline env, the absence of an HF token, and `/health`.
7. By hand: `sudo ss -lntp | grep 8080` shows only the intended address. From another machine the
   API must *not* answer while `BIND_ADDR=127.0.0.1`.
8. Benchmark C1/C2/C4/C8 at TP=2, and compare with numbers from the privileged launcher.

If step 5 or 8 fails, relax one knob, retry, and record the result in the table below.

| Change | Result | Date |
|---|---|---|
| `--privileged` removed | works (server up, with `--ipc=host`) | 2026-09-19 |
| `--network=host` → `-p BIND_ADDR:PORT` | works (server up, with `--ipc=host`) | 2026-09-19 |
| `--ipc=host` → `--shm-size 4g` | **fails**: engine does not finish startup. `--ipc=host` restored | 2026-09-19 |
| read-only mounts | works (server up, with `--ipc=host`) | 2026-09-19 |
| HF offline mode | works (server up, with `--ipc=host`) | 2026-09-19 |
| LAN access: `BIND_ADDR=<lan-ip>` + ipset allowlist + API key | works (Open WebUI, base URL must end in `/v1`) | 2026-09-19 |
| `NETWORK=ai-net`: Prometheus scrape of `/metrics` without a key | _untested_ | |

## Second stage (after the server is stable)

Test one change at a time. Each test covers startup, model load, kernel compilation, TP=2, long
prefill, speculative decode, and C1/C2/C4/C8.

1. `CAP_SYS_PTRACE=0`
2. `SECCOMP_UNCONFINED=0`
3. `CAP_DROP_ALL=1`. Inspect first with `docker exec vllm-mxfp4-qwen38 capsh --print`, and add back
   only proven needs

## LAN access (OpenCode, Open WebUI, other computers)

Two controls, both required. Neither is enough alone:

- **Host firewall allowlist** (an ipset of client IPs). vLLM's key only guards `/v1/*`: `/health`,
  `/metrics`, `/version`, `/tokenize` and `/detokenize` answer anyone who can reach the port, and
  the server itself is attack surface. The firewall keeps unlisted LAN devices off the port
  entirely.
- **API key.** LAN IPs are easy to take over (a guest device, a compromised IoT box), and the
  firewall does nothing about a spoofed or reassigned address. The key covers that for `/v1`.

The key is sent in clear text over plain HTTP, so this is for a trusted LAN only. Remote access
goes through a VPN (WireGuard/Tailscale). Never forward the port on the router.

Publish on the server's **LAN IP**, not `0.0.0.0`. From a client the result is the same, and it
stays off Docker bridges, VPN and other interfaces.

### 1. API key (once)

```bash
mkdir -p ~/.config/vllm-mxfp4
(umask 077; openssl rand -hex 32 > ~/.config/vllm-mxfp4/api-key)
```

The launcher refuses a key file readable by group or other. Clients use the same value. To rotate,
replace the file and restart the server, then update the clients.

### 2. Firewall allowlist (once, then one line per new client)

Give every client a DHCP reservation so its IP stays fixed. Docker-published ports go through
FORWARD, not INPUT, so **ufw and plain INPUT rules do not filter them**. The rule belongs in
`DOCKER-USER`.

```bash
sudo apt install ipset ipset-persistent iptables-persistent
ip -br addr                                    # LAN interface name, e.g. enp5s0
sudo ipset create vllm-clients hash:ip
sudo ipset add vllm-clients <main-pc-ip>
sudo iptables -I DOCKER-USER -i <lan-if> -p tcp -m conntrack --ctorigdstport 8080 --ctdir ORIGINAL   -m set ! --match-set vllm-clients src -j DROP
sudo netfilter-persistent save                 # ipsets and rules; the set is restored first
```

`--ctorigdstport` matches the port the client connected to, before Docker's DNAT. Adding a computer
later does not touch the rule:

```bash
sudo ipset add vllm-clients <ip> && sudo netfilter-persistent save
```

### 3. Serve on the LAN IP

```bash
docker stop vllm-mxfp4-qwen38
REQUIRE_PINS=1 BIND_ADDR=192.168.1.180 DRY_RUN=1 ./serve-mxfp4.sh   # publish + auth lines
REQUIRE_PINS=1 BIND_ADDR=192.168.1.180 DETACH=1 ./serve-mxfp4.sh
./verify-hardening.sh     # published only on 192.168.1.180; /v1 requires an API key
```

Without a key file the launcher refuses a non-loopback `BIND_ADDR`. The log shows
`[radiance] API key auth enabled for /v1`.

### 4. Verify

```text
server:          docker inspect vllm-mxfp4-qwen38 | grep -c "$(head -c 8 ~/.config/vllm-mxfp4/api-key)"   -> 0
                 sudo ss -lntp | grep 8080                               -> only 192.168.1.180:8080
allowed client:  curl.exe -i http://192.168.1.180:8080/health            -> 200
                 curl.exe -i http://192.168.1.180:8080/v1/models         -> 401
                 curl.exe -i -H "Authorization: Bearer <key>" http://192.168.1.180:8080/v1/models -> 200
other device:    the same requests time out (even with the key); DROP counter rises in
                 sudo iptables -L DOCKER-USER -v -n
```

### 5. Clients

- **OpenCode** (`opencode.json`):
  ```json
  {
    "$schema": "https://opencode.ai/config.json",
    "provider": {
      "vllm": {
        "npm": "@ai-sdk/openai-compatible",
        "name": "vLLM MXFP4",
        "options": { "baseURL": "http://192.168.1.180:8080/v1", "apiKey": "{env:VLLM_API_KEY}" },
        "models": { "Qwen3.8": { "name": "Qwen3.8 MXFP4" } }
      }
    }
  }
  ```
  Set `VLLM_API_KEY` in the user environment. Don't put the key in a committed file.
- **Open WebUI:** Admin Settings → Connections → OpenAI API → `http://192.168.1.180:8080/v1` plus
  the key. This also works when Open WebUI runs in Docker Desktop: its traffic leaves with the
  host's LAN IP, which is the one in the allowlist.

## Monitoring (Prometheus on a Docker network)

Prometheus scrapes `vllm-server:8080/metrics` over the Docker network `ai-net`. The launcher joins
that network under a stable alias. Don't use `docker network connect` for this, because the
connection is lost when the launcher replaces the container.

```bash
docker stop vllm-mxfp4-qwen38
REQUIRE_PINS=1 BIND_ADDR=192.168.1.180 NETWORK=ai-net DRY_RUN=1 ./serve-mxfp4.sh | grep -E "network|publish|auth"
REQUIRE_PINS=1 BIND_ADDR=192.168.1.180 NETWORK=ai-net DETACH=1 ./serve-mxfp4.sh
```

`--network ai-net` replaces the default bridge. The LAN publish (`-p BIND_ADDR:PORT`) works the
same on a user-defined bridge.

Check from inside the network, which is the path Prometheus uses:

```bash
docker run --rm --network ai-net curlimages/curl -s -o /dev/null -w '%{http_code}\n' http://vllm-server:8080/metrics    # 200: no key needed
docker run --rm --network ai-net curlimages/curl -s -o /dev/null -w '%{http_code}\n' http://vllm-server:8080/v1/models  # 401: key enforced
```

vLLM's key only guards `/v1/*`, so the scrape job needs no credentials. If `/metrics` ever returns
401, give the job `authorization: { type: Bearer, credentials_file: <key file mounted ro> }`.

**Tradeoff.** Containers on `ai-net` reach port 8080 directly. They never pass the `DOCKER-USER`
allowlist, which filters only the LAN interface. For them the API key is the only guard on `/v1`,
and `/metrics`, `/tokenize` and `/health` are open. In the other direction, the vLLM container can
reach every service on `ai-net`. The tighter setup is a network holding only Prometheus and vLLM:

```bash
docker network create vllm-metrics
docker network connect vllm-metrics prometheus
NETWORK=vllm-metrics ./serve-mxfp4.sh ...
```

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
