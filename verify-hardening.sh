#!/bin/bash
# verify-hardening.sh -- check a running serve container against HARDENING.md's security boundary.
#
#   ./verify-hardening.sh                 checks the container NAME (default vllm-mxfp4-qwen38)
#   NAME=other ./verify-hardening.sh      a different container
#
# Read-only: it inspects the container and probes the API, and changes nothing. Exits non-zero if
# any FAIL line is printed. WARN lines are deliberate first-stage allowances (SYS_PTRACE, unconfined
# seccomp) or things that need a human (the LAN / firewall checks in HARDENING.md).
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=pins.sh
. "$SCRIPT_DIR/pins.sh"
pins_load

NAME=${NAME:-vllm-mxfp4-qwen38}
PORT=${PORT:-8080}
RUNTIME=${RUNTIME:-}
if [ -z "$RUNTIME" ]; then
  if   command -v podman >/dev/null 2>&1; then RUNTIME=podman
  elif command -v docker >/dev/null 2>&1; then RUNTIME=docker
  else echo "no container runtime found" >&2; exit 2
  fi
fi

FAILS=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAILS=$((FAILS + 1)); }
warn() { echo "  WARN  $*"; }
q()    { "$RUNTIME" inspect -f "$1" "$NAME" 2>/dev/null; }

"$RUNTIME" inspect "$NAME" >/dev/null 2>&1 || { echo "no container named $NAME (NAME=...)" >&2; exit 2; }
echo "checking $RUNTIME container $NAME"

# ---------------------------------------------------------------- privilege and namespaces
[ "$(q '{{.HostConfig.Privileged}}')" = false ] && pass "Privileged=false" || fail "container is --privileged"
net=$(q '{{.HostConfig.NetworkMode}}')
[ "$net" != host ] && pass "NetworkMode=$net" || fail "NetworkMode=host"
ipc=$(q '{{.HostConfig.IpcMode}}')
[ "$ipc" != host ] && pass "IpcMode=${ipc:-private}" || fail "IpcMode=host"
shm=$(q '{{.HostConfig.ShmSize}}')
[ -n "$shm" ] && [ "$shm" -gt 0 ] 2>/dev/null && pass "ShmSize=$((shm / 1024 / 1024)) MiB" || warn "ShmSize not reported"
[ "$(q '{{index .Config.Labels "io.vllm-mxfp4.managed"}}')" = 1 ] && pass "started by serve-mxfp4.sh (managed label)" \
  || warn "no io.vllm-mxfp4.managed label -- not started by the hardened launcher?"

caps=$(q '{{.HostConfig.CapAdd}}')
case "$caps" in *SYS_ADMIN*|*ALL*) fail "broad capabilities added: $caps" ;; esac
case "$caps" in *SYS_PTRACE*) warn "SYS_PTRACE kept (first stage; test removing it: CAP_SYS_PTRACE=0)" ;; esac
secopt=$(q '{{.HostConfig.SecurityOpt}}')
case "$secopt" in *seccomp=unconfined*|*seccomp:unconfined*) warn "seccomp unconfined (first stage; test SECCOMP_UNCONFINED=0)" ;;
  *) pass "default seccomp profile" ;; esac

devs=$(q '{{range .HostConfig.Devices}}{{.PathOnHost}} {{end}}')
case "$devs" in *"/dev/kfd"*) pass "GPU device /dev/kfd mapped" ;; *) warn "/dev/kfd not in the device list: $devs" ;; esac

# ---------------------------------------------------------------- image
img=$(q '{{.Config.Image}}')
if [ -n "$PIN_IMAGE" ] && [ "$img" = "$PIN_IMAGE" ]; then pass "image is the pinned digest"
elif [[ "$img" == *@sha256:* ]]; then warn "image $img is digest-pinned but differs from PIN_IMAGE=${PIN_IMAGE:-<unset>}"
else fail "image $img is a mutable tag (./pin-deployment.sh)"
fi

# ---------------------------------------------------------------- mounts
# Only /cache may be writable; the runtime control socket must not be mounted at all.
while read -r src dst rw; do
  [ -n "$dst" ] || continue
  case "$src$dst" in *docker.sock*|*podman.sock*|*containerd.sock*) fail "runtime socket mounted: $src -> $dst"; continue ;; esac
  case "$dst" in
    /cache) [ "$rw" = true ] && pass "$dst writable (compile cache)" || warn "$dst read-only -- JIT caches cannot persist" ;;
    *)      [ "$rw" = false ] && pass "$dst read-only" || fail "$dst is WRITABLE (from $src)" ;;
  esac
done < <(q '{{range .Mounts}}{{println .Source .Destination .RW}}{{end}}')

# ---------------------------------------------------------------- environment
env=$(q '{{range .Config.Env}}{{println .}}{{end}}')
for kv in HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 VLLM_NO_USAGE_STATS=1; do
  grep -qx "$kv" <<<"$env" && pass "$kv" || fail "$kv not set"
done
if grep -qE '^(HF_TOKEN|HUGGING_FACE_HUB_TOKEN)=.+' <<<"$env"; then fail "a Hugging Face token is passed to the serving container"
else pass "no Hugging Face token in the environment"
fi

# ---------------------------------------------------------------- published port
binds=$(q '{{json .HostConfig.PortBindings}}')
mapfile -t ips < <(grep -oE '"HostIp":"[^"]*"' <<<"$binds" | cut -d'"' -f4 | sort -u)
host_ips="${ips[*]:-}"
if [ -z "$binds" ] || [ "$binds" = "{}" ] || [ "$binds" = null ]; then
  [ "$net" = host ] || warn "no published ports -- the API is unreachable from the host"
else
  wide=0
  # an empty HostIp is docker's spelling of "every interface"
  for ip in "${ips[@]}"; do case "$ip" in ""|0.0.0.0|::) wide=1 ;; esac; done
  if [ "$wide" = 1 ]; then fail "port published on every interface: $binds"
  else pass "published only on: $host_ips"
  fi
fi
if command -v ss >/dev/null 2>&1; then
  echo "  listeners on :$PORT (host):"
  ss -lnt "( sport = :$PORT )" 2>/dev/null | sed -n '2,$p' | awk '{print "        " $4}'
fi

# ---------------------------------------------------------------- API
api=${host_ips%% *}; api=${api:-127.0.0.1}
if command -v curl >/dev/null 2>&1; then
  if curl -fsS -m 5 "http://$api:$PORT/health" >/dev/null 2>&1; then pass "http://$api:$PORT/health answers"
  else warn "http://$api:$PORT/health does not answer (still starting?)"
  fi
fi

echo
if [ "$FAILS" -gt 0 ]; then echo "$FAILS check(s) FAILED"; exit 1; fi
echo "all checks passed. Still manual (HARDENING.md): reachability from another host, firewall, benchmarks."
