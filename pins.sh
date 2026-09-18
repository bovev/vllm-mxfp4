# pins.sh -- load and update deploy-pins.env, the record of what this host serves.
#
# Sourced (not run) by serve-mxfp4.sh, setup-mxfp4.sh, docker-quickstart.sh and pin-deployment.sh.
# deploy-pins.env holds the repository commit, the image DIGEST and the Hugging Face revisions a
# deployment was built from (HARDENING.md). A tag like vllm-radiance:0.9.3 and a model repo id are
# both mutable; the pins are what make a restart next month serve the same bytes as today.
#
# The file is shell and is sourced, so pins_set only ever writes KEY=VALUE lines whose value has
# been validated against a strict pattern -- nothing free-form reaches it.

PINS_FILE=${PINS_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deploy-pins.env}

pins_load() {
  if [ -f "$PINS_FILE" ]; then
    # shellcheck source=deploy-pins.env
    . "$PINS_FILE"
  fi
  PIN_REPO_COMMIT=${PIN_REPO_COMMIT:-}
  PIN_IMAGE=${PIN_IMAGE:-}
  PIN_SRC_REVISION=${PIN_SRC_REVISION:-}
  PIN_DRAFT_REVISION=${PIN_DRAFT_REVISION:-}
}

# pins_valid KEY VALUE -> 0 if VALUE is an acceptable value for KEY
pins_valid() {
  case "$1" in
    PIN_REPO_COMMIT|PIN_SRC_REVISION|PIN_DRAFT_REVISION)
      [[ "$2" =~ ^[0-9a-f]{40}$ ]] ;;
    PIN_IMAGE)
      [[ "$2" =~ ^[A-Za-z0-9._/:-]+@sha256:[0-9a-f]{64}$ ]] ;;
    *) return 1 ;;
  esac
}

# pins_set KEY VALUE -- replace (or append) KEY=VALUE in the pins file
pins_set() {
  local key=$1 val=$2 tmp
  pins_valid "$key" "$val" || { echo "pins: refusing to write $key='$val' (not a valid pin)" >&2; return 1; }
  [ -f "$PINS_FILE" ] || printf '# deployment pins -- see HARDENING.md\n' >"$PINS_FILE"
  tmp=$(mktemp "$PINS_FILE.XXXXXX")
  awk -v k="$key" -v v="$val" '
    BEGIN { done = 0 }
    $0 ~ "^" k "=" { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$PINS_FILE" >"$tmp" && mv "$tmp" "$PINS_FILE"
  eval "$key=\$val"
}

# pins_image_is_pinned REF -> 0 if the image reference names a digest
pins_image_is_pinned() { [[ "$1" == *@sha256:* ]]; }
