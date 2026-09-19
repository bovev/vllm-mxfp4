#!/bin/bash
# review-update.sh -- review what a repository update would change BEFORE serving it (HARDENING.md).
#
#   ./review-update.sh                  fetch, then compare the pinned commit with origin/main
#   ./review-update.sh <old> <new>      compare any two commits
#   NO_FETCH=1 ./review-update.sh       skip the fetch
#
# The runtime patch chain is executable code run as root inside the serving container, so every
# update is read, not pulled blind. This prints the commit log, the files that change, every
# ADDED line that touches the network, a shell, the host or the runtime socket, and changes to the
# pins that decide which bytes run (image, libr4d commit, model revisions). It changes nothing:
# no checkout, no merge, no pull. When satisfied: check out <new>, run ./pin-deployment.sh,
# benchmark in a separate container, then promote.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"
# shellcheck source=pins.sh
. "$SCRIPT_DIR/pins.sh"
pins_load

if [ "${NO_FETCH:-0}" != 1 ]; then git fetch --quiet; fi
OLD=${1:-${PIN_REPO_COMMIT:-HEAD}}
NEW=${2:-origin/main}
git rev-parse --verify -q "$OLD^{commit}" >/dev/null || { echo "unknown commit: $OLD" >&2; exit 2; }
git rev-parse --verify -q "$NEW^{commit}" >/dev/null || { echo "unknown commit: $NEW" >&2; exit 2; }

hr() { echo; echo "=== $* ==="; }

hr "commits $OLD..$NEW"
git log --oneline --decorate --graph "$OLD..$NEW"
[ -n "$(git rev-list "$OLD..$NEW")" ] || { echo "(nothing new)"; exit 0; }

hr "changed files"
git diff --stat "$OLD" "$NEW"

# Code that runs: the launchers, every patcher / radiance module, the kernels and the image recipe.
CODE=('*.py' '*.sh' '*.hip' '*.h' '*.patch' 'Dockerfile*' 'Makefile' '*.service' 'docker-compose*.yml')

hr "added lines worth a second look"
PATTERN='subprocess|os\.system|os\.popen|shell=True|\bexec\(|\beval\b|curl|wget|requests\.|urllib|http\.client|socket|paramiko|/etc/|/root/\.ssh|\.ssh/|docker\.sock|podman\.sock|systemctl|sudo|rm -rf|chmod|chown|setuid|--privileged|--network=host|--ipc=host|--cap-add|seccomp|base64|pickle\.load|torch\.load|trust_remote_code|HF_TOKEN|snapshot_download|git clone|pip install'
hits=$(git diff -U0 "$OLD" "$NEW" -- "${CODE[@]}" \
  | awk '/^\+\+\+ /{f=substr($0,7)} /^\+[^+]/{print f": "substr($0,2)}' \
  | grep -E "$PATTERN" || true)
if [ -n "$hits" ]; then echo "$hits"; else echo "(none)"; fi

hr "pins that decide which bytes run"
pin_hits=$(git diff -U0 "$OLD" "$NEW" -- "${CODE[@]}" deploy-pins.env \
  | awk '/^\+\+\+ /{f=substr($0,7)} /^[-+][^-+]/{print f": "$0}' \
  | grep -E 'vllm-radiance[:@][^ ]|R4D_PIN=|R4D_VERSION=|R4D_REPO=|libr4d\.git|revision=|PIN_[A-Z_]+=|: [-+](FROM|ARG) ' || true)
if [ -n "$pin_hits" ]; then echo "$pin_hits"; else echo "(none)"; fi

hr "next"
cat <<EOF
Read the full diff of anything above:  git diff $OLD $NEW -- <file>
Every patch_*.py / radiance_*.py change:  git diff $OLD $NEW -- 'patch_*.py' 'radiance_*.py' _patchlib.py
Then (HARDENING.md, "Updating"): check out $NEW, ./pin-deployment.sh, DRY_RUN=1 ./serve-mxfp4.sh,
serve on another NAME/PORT, benchmark C1/C2/C4/C8, verify output, ./verify-hardening.sh, promote.
EOF
