#!/bin/bash
# One-time setup for the MXFP4 serve. Checks the host, pulls the image, fetches AMD's checkpoint,
# builds the loadable form of it, fetches the drafter, and compiles libr4d -- then tells you the
# one command that starts the server.
#
# Safe to re-run: every step checks whether its output already exists and skips it. Nothing here
# is destructive, and nothing writes outside $MODELS, the HF cache and ~/.cache/radiance-libr4d.
set -euo pipefail

MODELS=${MODELS:-$HOME/models}
HF_CACHE=${HF_CACHE:-$HOME/.cache/huggingface}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# deploy-pins.env: image digest and the Hugging Face revisions this host is pinned to.
# shellcheck source=pins.sh
. "$SCRIPT_DIR/pins.sh"
pins_load
IMAGE=${IMAGE:-${PIN_IMAGE:-stilldeadcode/vllm-radiance:0.9.3}}
SRC_REPO=${SRC_REPO:-amd/Qwen3.8-27B-Quark-AWQ-MXFP4}
DRAFT_REPO=${DRAFT_REPO:-tcclaviger/Qwen3.8-27B-DFlash2-FP8}
# Model revisions. A repo id alone is mutable: re-running setup later could fetch different files.
# Empty = resolve the repo's current head ONCE, download exactly that commit, and record it in
# deploy-pins.env so every later rebuild fetches the same bytes.
SRC_REVISION=${SRC_REVISION:-$PIN_SRC_REVISION}
DRAFT_REVISION=${DRAFT_REVISION:-$PIN_DRAFT_REVISION}
SNAP=${SNAP:-$MODELS/Qwen3.8-27B-MXFP4-mtpfp8}
DRAFTER=${DRAFTER:-$MODELS/Qwen3.8-27B-DFlash2-FP8}

WANT_DRAFTER=1
ASSUME_YES=0
for a in "$@"; do
  case "$a" in
    -h|--help)
      cat <<'USAGE'
setup-mxfp4.sh -- one-time setup for the MXFP4 serve

  ./setup-mxfp4.sh              run every step that is not already done
  ./setup-mxfp4.sh --yes        don't ask before downloading (~40 GiB)
  ./setup-mxfp4.sh --no-drafter skip the DFlash2 drafter (then serve with SPEC_METHOD=mtp)

Environment:
  MODELS=~/models               where the checkpoints are written
  HF_CACHE=~/.cache/huggingface where the source download lands
  IMAGE=<pinned digest>         container image (default: PIN_IMAGE from deploy-pins.env)
  RUNTIME=podman|docker         container runtime (auto-detected)
  SRC_REVISION=<commit>         Hugging Face commit of SRC_REPO (default: PIN_SRC_REVISION)
  DRAFT_REVISION=<commit>       Hugging Face commit of DRAFT_REPO (default: PIN_DRAFT_REVISION)
  HF_TOKEN=...                  only if a repo needs it; passed to the download step ONLY,
                                never to the serving container

Downloads happen here and only here. The server runs with HF_HUB_OFFLINE=1 and the model
directories mounted read-only, so anything missing fails loudly instead of being fetched.

Disk: ~19 GiB for AMD's release, ~19 GiB for the checkpoint built from it, 2 GiB for the
drafter and ~10 GiB for the image. The source download can be deleted afterwards.
USAGE
      exit 0 ;;
    --yes|-y)      ASSUME_YES=1 ;;
    --no-drafter)  WANT_DRAFTER=0 ;;
    *) echo "unknown argument: $a (try --help)" >&2; exit 2 ;;
  esac
done

step() { echo; echo "=== $* ==="; }
ok()   { echo "  ok: $*"; }
die()  { echo "ERROR: $1" >&2; shift; for l in "$@"; do echo "  $l" >&2; done; exit 1; }

# ------------------------------------------------------------------ 1. host
step "1/6  host"

RUNTIME=${RUNTIME:-}
if [ -z "$RUNTIME" ]; then
  if   command -v podman >/dev/null 2>&1; then RUNTIME=podman
  elif command -v docker >/dev/null 2>&1; then RUNTIME=docker
  else die "no container runtime found" "install podman (preferred) or docker, then re-run"
  fi
fi
ok "container runtime: $RUNTIME"

[ -e /dev/kfd ] || die "/dev/kfd is missing -- the amdgpu kernel driver is not loaded" \
    "ROCm userspace ships inside the image, but the kernel driver must be on the host"
[ -d /dev/dri ] || die "/dev/dri is missing -- no GPU render nodes on this host"

# Same scan the launcher uses, so setup and serve cannot disagree about what hardware is here.
# It counts only cards big enough to hold a shard: a bare count of amdgpu render nodes includes
# integrated graphics, which is three rather than two on the development box.
# shellcheck source=gpu-detect.sh
. "$(cd "$(dirname "$0")" && pwd)/gpu-detect.sh"
if [ "$RAD_GPU_COUNT" -lt 1 ]; then
  echo "  WARNING: no AMD GPU with at least ${RAD_MIN_GPU_MIB} MiB of VRAM."
  echo "  Found:${RAD_GPU_SKIPPED:- nothing on the amdgpu driver}. Setup can still prepare everything else."
else
  ok "$RAD_GPU_COUNT AMD GPU(s) usable: $RAD_GPU_NAME, $RAD_GPU_MIB MiB each -> tensor-parallel $RAD_TP"
  if [ -n "$RAD_GPU_SKIPPED" ]; then
    echo "  (skipped as too small:$RAD_GPU_SKIPPED)"
  fi
fi

command -v git >/dev/null 2>&1 || die "git is required (the libr4d build clones it)"

free_gib=$(df -BG --output=avail "$(dirname "$MODELS")" 2>/dev/null | tail -1 | tr -dc '0-9')
if [ -n "$free_gib" ] && [ "$free_gib" -lt 60 ]; then
  echo "  WARNING: ${free_gib} GiB free on $(dirname "$MODELS"); a full setup wants about 60 GiB"
  echo "  (19 source + 19 built + 2 drafter + ~10 image). Delete the source download when done."
else
  ok "${free_gib:-?} GiB free"
fi

mkdir -p "$MODELS" "$HF_CACHE"

if [ "$ASSUME_YES" = 0 ] && { [ ! -d "$SNAP" ] || { [ "$WANT_DRAFTER" = 1 ] && [ ! -d "$DRAFTER" ]; }; }; then
  echo
  echo "This will download roughly 40 GiB into $HF_CACHE and $MODELS."
  read -r -p "Continue? [y/N] " reply
  case "$reply" in y|Y|yes|YES) ;; *) echo "aborted"; exit 1 ;; esac
fi

# ------------------------------------------------------------------ 2. image
step "2/6  container image"
if "$RUNTIME" image exists "$IMAGE" >/dev/null 2>&1 || "$RUNTIME" image inspect "$IMAGE" >/dev/null 2>&1; then
  ok "$IMAGE already present"
else
  echo "  pulling $IMAGE (a few GiB)"
  "$RUNTIME" pull "$IMAGE"
fi
if ! pins_image_is_pinned "$IMAGE"; then
  echo "  note: $IMAGE is a mutable tag. Pin its digest once with ./pin-deployment.sh"
fi

# Download inside the image rather than on the host: it already has huggingface_hub, so the host
# needs no Python environment of its own for any of this. The container gets the runtime's default
# (bridged, NAT'd) network -- outbound HTTPS is all a download needs, not the host namespace --
# and it is the only container that ever sees HF_TOKEN.
hf_get() { # repo local-dir-or-empty revision-or-empty -> prints the commit it downloaded
  local repo="$1" dest="${2:-}" rev="${3:-}"
  "$RUNTIME" run --rm \
    -e HF_HOME=/root/.cache/huggingface \
    -e HF_TOKEN="${HF_TOKEN:-}" \
    -e HF_HUB_DISABLE_TELEMETRY=1 \
    -v "$HF_CACHE":/root/.cache/huggingface \
    -v "$MODELS":/models \
    --entrypoint python3 "$IMAGE" -c '
import re, sys
from huggingface_hub import HfApi, snapshot_download
repo, dest, rev = sys.argv[1], (sys.argv[2] or None), (sys.argv[3] or None)
# Resolve a branch/tag (or the default head) to one immutable commit, then download exactly it.
sha = rev if rev and re.fullmatch(r"[0-9a-f]{40}", rev) else HfApi().model_info(repo, revision=rev).sha
snapshot_download(repo_id=repo, local_dir=dest, revision=sha)
print(sha)
' "$repo" "${dest:-}" "${rev:-}" | tail -1
}

# Record a downloaded revision in deploy-pins.env the first time; afterwards the pin wins.
record_revision() { # PIN_KEY commit
  local key=$1 sha=$2 cur
  cur=${!key}
  if [ -z "$cur" ]; then
    pins_set "$key" "$sha" && ok "pinned $key=$sha in $(basename "$PINS_FILE")"
  elif [ "$cur" != "$sha" ]; then
    echo "  WARNING: downloaded $sha but $key=$cur -- $PINS_FILE left unchanged" >&2
  fi
}

# ------------------------------------------------------------------ 3. source checkpoint
step "3/6  AMD's MXFP4 release ($SRC_REPO)"
if [ -d "$SNAP" ] && [ -f "$SNAP/config.json" ]; then
  ok "skipped -- the built checkpoint already exists at $SNAP"
  SRC=""
else
  echo "  downloading ~19 GiB into $HF_CACHE (resumes if interrupted)${SRC_REVISION:+ at pinned revision $SRC_REVISION}"
  SRC_SHA=$(hf_get "$SRC_REPO" "" "$SRC_REVISION")
  [[ "$SRC_SHA" =~ ^[0-9a-f]{40}$ ]] || die "download of $SRC_REPO did not report a commit (got: '$SRC_SHA')"
  record_revision PIN_SRC_REVISION "$SRC_SHA"
  # the snapshot of exactly the commit just downloaded, not whichever one ls happens to list first
  SRC="$HF_CACHE/hub/models--${SRC_REPO//\//--}/snapshots/$SRC_SHA/"
  [ -d "$SRC" ] || die "download finished but $SRC does not exist"
  ok "source snapshot: $SRC"
fi

# ------------------------------------------------------------------ 4. build the loadable checkpoint
step "4/6  build $SNAP"
if [ -f "$SNAP/config.json" ]; then
  ok "already built"
else
  echo "  requantizing the MTP head to fp8 (~15 minutes, one file rewritten)."
  echo "  This is not optional for AMD's release: its exclude list names the bf16 mtp.* layers"
  echo "  as tensor names (mtp.fc.weight) among module names, so quark's module match never"
  echo "  fires, the mxfp4 scheme lands on a bf16 head, and vLLM asserts on a half-width"
  echo "  parameter at load. A checkpoint that declares mtp.* in layer_quant_config skips this:"
  echo "  set SNAP=<that checkpoint> and serve it directly."
  case "$SNAP" in
    "$MODELS"/*) CSNAP="/models/${SNAP#"$MODELS"/}" ;;
    *) die "SNAP ($SNAP) must live under MODELS ($MODELS)" ;;
  esac
  CSRC="/root/.cache/huggingface/${SRC#"$HF_CACHE"/}"
  if python3 -c "import torch" >/dev/null 2>&1; then
    python3 "$SCRIPT_DIR/fp8_mtp.py" "$SRC" "$SNAP"
  else
    # A pure file transform: no network at all, source weights and repo code read-only.
    "$RUNTIME" run --rm --network=none \
      -v "$HF_CACHE":/root/.cache/huggingface:ro \
      -v "$MODELS":/models \
      -v "$SCRIPT_DIR":/repo:ro,z \
      --entrypoint python3 "$IMAGE" /repo/fp8_mtp.py "$CSRC" "$CSNAP"
  fi
  [ -f "$SNAP/config.json" ] || die "fp8_mtp.py did not produce $SNAP/config.json"
  ok "built"
fi

# ------------------------------------------------------------------ 5. drafter
step "5/6  speculative drafter"
if [ "$WANT_DRAFTER" = 0 ]; then
  echo "  skipped (--no-drafter). Serve with: SPEC_METHOD=mtp ./serve-mxfp4.sh"
elif [ -f "$DRAFTER/config.json" ]; then
  ok "already present at $DRAFTER"
else
  echo "  downloading $DRAFT_REPO (2 GiB)"
  case "$DRAFTER" in
    "$MODELS"/*) CDRAFTER="/models/${DRAFTER#"$MODELS"/}" ;;
    *) die "DRAFTER ($DRAFTER) must live under MODELS ($MODELS)" ;;
  esac
  DRAFT_SHA=$(hf_get "$DRAFT_REPO" "$CDRAFTER" "$DRAFT_REVISION")
  [[ "$DRAFT_SHA" =~ ^[0-9a-f]{40}$ ]] || die "download of $DRAFT_REPO did not report a commit (got: '$DRAFT_SHA')"
  record_revision PIN_DRAFT_REVISION "$DRAFT_SHA"
  [ -f "$DRAFTER/config.json" ] || die "drafter download did not produce $DRAFTER/config.json"
  ok "downloaded"
fi

# ------------------------------------------------------------------ 6. kernels
step "6/6  libr4d kernels"
echo "  building the pinned libr4d inside the image (once, a few minutes; cached afterwards)."
echo "  The kernel shipped in the image predates the gated-delta-net overflow fix and NaNs this"
echo "  model's output, so this build is load-bearing, not an optimization."
MODELS="$MODELS" IMAGE="$IMAGE" RUNTIME="$RUNTIME" PREPARE_ONLY=1 "$SCRIPT_DIR/serve-mxfp4.sh"

cat <<EOF

=== setup complete ===

Start the server:

    ./serve-mxfp4.sh

It listens on http://localhost:8080/v1 as "Qwen3.8". The first start compiles Triton and inductor
kernels and takes several extra minutes; later starts reuse that cache. Then:

    curl http://localhost:8080/v1/chat/completions \\
      -H 'Content-Type: application/json' \\
      -d '{"model":"Qwen3.8","messages":[{"role":"user","content":"Hello!"}]}'

Every knob:  ./serve-mxfp4.sh --help
EOF
if [ -n "${SRC:-}" ]; then
  echo
  echo "You can reclaim ~19 GiB now -- the source download is no longer needed:"
  echo "    rm -rf $HF_CACHE/hub/models--${SRC_REPO//\//--}"
fi
