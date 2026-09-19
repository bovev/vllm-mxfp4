#!/bin/bash
# pin-deployment.sh -- record exactly what this host serves, in deploy-pins.env (HARDENING.md).
#
#   ./pin-deployment.sh                 pin the repo commit and the image digest; pick up the
#                                       Hugging Face revisions of checkpoints already downloaded
#   ./pin-deployment.sh --show          print the pins and whether this host matches them
#   ./pin-deployment.sh --repin-image   re-resolve IMAGE_TAG to a new digest (a deliberate
#                                       update -- see HARDENING.md, "Updating")
#
# serve-mxfp4.sh, setup-mxfp4.sh and docker-quickstart.sh read deploy-pins.env, so after this the
# image is used by digest and a re-run of setup fetches the same model commits. Nothing here
# edits a checkpoint or restarts a container. Commit deploy-pins.env afterwards.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=pins.sh
. "$SCRIPT_DIR/pins.sh"
pins_load

IMAGE_TAG=${IMAGE_TAG:-stilldeadcode/vllm-radiance:0.9.3}
MODELS=${MODELS:-$HOME/models}
HF_CACHE=${HF_CACHE:-$HOME/.cache/huggingface}
SRC_REPO=${SRC_REPO:-amd/Qwen3.8-27B-Quark-AWQ-MXFP4}
DRAFTER=${DRAFTER:-$MODELS/Qwen3.8-27B-DFlash2-FP8}

MODE=pin
case "${1:-}" in
  "") ;;
  --show) MODE=show ;;
  --repin-image) MODE=repin ;;
  -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
esac

say()  { echo "$*"; }
ok()   { echo "  ok    $*"; }
warn() { echo "  WARN  $*"; }
die()  { echo "ERROR: $1" >&2; shift; for l in "$@"; do echo "  $l" >&2; done; exit 1; }

RUNTIME=${RUNTIME:-}
if [ -z "$RUNTIME" ]; then
  if   command -v podman >/dev/null 2>&1; then RUNTIME=podman
  elif command -v docker >/dev/null 2>&1; then RUNTIME=docker
  fi
fi

image_present() { "$RUNTIME" image inspect "$1" >/dev/null 2>&1; }

# The RepoDigests entry for the tag's repository (docker prints repo@sha256:..., podman prefixes
# the registry: docker.io/repo@sha256:... -- either is a valid pull reference).
digest_of() { # tag
  local repo=${1%:*}
  "$RUNTIME" image inspect "$1" --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null \
    | grep -E "(^|/)${repo//./\\.}@sha256:[0-9a-f]{64}$" | head -1
}

# The commit a downloaded checkpoint came from, when it can be read off the disk.
src_revision_on_disk() {
  local d="$HF_CACHE/hub/models--${SRC_REPO//\//--}/snapshots"
  [ -d "$d" ] || return 0
  local n; n=$(find "$d" -mindepth 1 -maxdepth 1 -type d | wc -l)
  [ "$n" = 1 ] && basename "$(find "$d" -mindepth 1 -maxdepth 1 -type d)"
  return 0
}
draft_revision_on_disk() {
  # huggingface_hub's local_dir downloads keep per-file metadata whose first line is the commit
  local m="$DRAFTER/.cache/huggingface/download/config.json.metadata"
  [ -f "$m" ] && head -1 "$m" | tr -d '[:space:]'
  return 0
}

# HEAD is the pinned commit, or differs from it only in deploy-pins.env -- committing the pins
# file itself moves HEAD past the pin, and that alone is not drift.
repo_matches_pin() {
  [ -n "$PIN_REPO_COMMIT" ] || return 1
  git -C "$SCRIPT_DIR" cat-file -e "$PIN_REPO_COMMIT^{commit}" 2>/dev/null || return 1
  [ -z "$(git -C "$SCRIPT_DIR" diff --name-only "$PIN_REPO_COMMIT" HEAD -- . ':!deploy-pins.env')" ]
}

show() {
  say "pins file: $PINS_FILE"
  say "  PIN_REPO_COMMIT    ${PIN_REPO_COMMIT:-<unset>}"
  say "  PIN_IMAGE          ${PIN_IMAGE:-<unset>}"
  say "  PIN_SRC_REVISION   ${PIN_SRC_REVISION:-<unset>}"
  say "  PIN_DRAFT_REVISION ${PIN_DRAFT_REVISION:-<unset>}"
  say "this host:"
  local head; head=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || echo "?")
  if [ -z "$PIN_REPO_COMMIT" ]; then warn "repo at $head, no commit pinned"
  elif [ "$head" = "$PIN_REPO_COMMIT" ]; then ok "repo at the pinned commit"
  elif repo_matches_pin; then ok "repo matches the pinned commit (only deploy-pins.env changed since)"
  else warn "repo at $head, pinned $PIN_REPO_COMMIT -- review with ./review-update.sh"
  fi
  if [ -n "$(git -C "$SCRIPT_DIR" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    warn "working tree has uncommitted changes to tracked files"
  fi
  if [ -z "$RUNTIME" ]; then warn "no container runtime found; image not checked"
  elif [ -n "$PIN_IMAGE" ] && image_present "$PIN_IMAGE"; then ok "pinned image present locally"
  elif [ -n "$PIN_IMAGE" ]; then warn "pinned image not pulled yet: $RUNTIME pull $PIN_IMAGE"
  fi
}

if [ "$MODE" = show ]; then show; exit 0; fi

# ---------------------------------------------------------------- repository commit
head=$(git -C "$SCRIPT_DIR" rev-parse HEAD) || die "not a git checkout: $SCRIPT_DIR"
if [ -n "$(git -C "$SCRIPT_DIR" status --porcelain --untracked-files=no)" ]; then
  warn "uncommitted changes to tracked files -- the pin names HEAD, not what is on disk"
fi
if repo_matches_pin; then
  ok "PIN_REPO_COMMIT=$PIN_REPO_COMMIT (HEAD matches it)"
else
  [ -z "$PIN_REPO_COMMIT" ] || say "  repo pin moves $PIN_REPO_COMMIT -> $head (was it reviewed? ./review-update.sh)"
  pins_set PIN_REPO_COMMIT "$head"
  ok "PIN_REPO_COMMIT=$head"
fi

# ---------------------------------------------------------------- image digest
[ -n "$RUNTIME" ] || die "no container runtime found" "install podman or docker, or set RUNTIME="
if [ -n "$PIN_IMAGE" ] && [ "$MODE" != repin ]; then
  if ! image_present "$PIN_IMAGE"; then
    say "  pulling the pinned image $PIN_IMAGE"
    "$RUNTIME" pull "$PIN_IMAGE"
  fi
  ok "PIN_IMAGE=$PIN_IMAGE (kept; --repin-image to move it)"
else
  # Pull the tag deliberately, once, and pin whatever bytes it named at this moment.
  if [ "$MODE" = repin ] || ! image_present "$IMAGE_TAG"; then
    say "  pulling $IMAGE_TAG"
    "$RUNTIME" pull "$IMAGE_TAG"
  fi
  d=$(digest_of "$IMAGE_TAG")
  [ -n "$d" ] || die "no registry digest for $IMAGE_TAG" \
      "a locally built image has none -- push it to a registry, or pull the published tag"
  [ -z "$PIN_IMAGE" ] || say "  image pin moves $PIN_IMAGE -> $d"
  pins_set PIN_IMAGE "$d"
  ok "PIN_IMAGE=$d"
fi

# ---------------------------------------------------------------- Hugging Face revisions
# setup-mxfp4.sh records these when it downloads. Checkpoints fetched before it did are pinned
# here from what is on disk, when the commit can be read off it unambiguously.
if [ -z "$PIN_SRC_REVISION" ]; then
  r=$(src_revision_on_disk)
  if [ -n "$r" ] && pins_valid PIN_SRC_REVISION "$r"; then pins_set PIN_SRC_REVISION "$r"; ok "PIN_SRC_REVISION=$r (from the HF cache)"
  else warn "PIN_SRC_REVISION unset (source download not on disk or ambiguous; setup-mxfp4.sh records it)"
  fi
else ok "PIN_SRC_REVISION=$PIN_SRC_REVISION"
fi
if [ -z "$PIN_DRAFT_REVISION" ]; then
  r=$(draft_revision_on_disk)
  if [ -n "$r" ] && pins_valid PIN_DRAFT_REVISION "$r"; then pins_set PIN_DRAFT_REVISION "$r"; ok "PIN_DRAFT_REVISION=$r (from $DRAFTER)"
  else warn "PIN_DRAFT_REVISION unset (drafter metadata not found; setup-mxfp4.sh records it)"
  fi
else ok "PIN_DRAFT_REVISION=$PIN_DRAFT_REVISION"
fi

echo
say "Recorded in $PINS_FILE. Commit it with the server configuration:"
say "  git add deploy-pins.env && git commit -m 'pin deployment'"
