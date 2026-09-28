#!/usr/bin/env bash
# =============================================================================
# Tạo các label cần thiết trên mọi repo trong registry (GitHub hoặc GitLab).
#   ./setup-repo.sh
# =============================================================================
set -uo pipefail

RUNNER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$RUNNER_DIR/repos.json"
# shellcheck disable=SC1091
[ -f "$RUNNER_DIR/env" ] && { set -a; . "$RUNNER_DIR/env"; set +a; }
# shellcheck disable=SC1091
. "$RUNNER_DIR/forge.sh"

[ -f "$CONFIG" ] || { echo "Không thấy $CONFIG"; exit 1; }

DEFAULT_FORGE="$(jq -r '.defaults.forge // "auto"' "$CONFIG")"
export DEFAULT_FORGE

mapfile -t TASK_LABELS < <(jq -r '.defaults.labels[]? // empty' "$CONFIG")
RUN_LBL="$(jq -r '.runner.status_labels.running // "ai-running"' "$CONFIG")"
DONE_LBL="$(jq -r '.runner.status_labels.done // "ai-done"' "$CONFIG")"
FAIL_LBL="$(jq -r '.runner.status_labels.failed // "ai-failed"' "$CONFIG")"

create() { # name color desc full
  if forge_label_create "$4" "$1" "$2" "$3"; then
    echo "  [+] $4: $1"
  else
    echo "  [!] $4: $1 (lỗi)"
  fi
}

jq -c '.repos[] | select(.enabled != false)' "$CONFIG" | while read -r repo; do
  path=$(jq -r '.path' <<<"$repo")
  name=$(jq -r '.name' <<<"$repo")
  forge_detect "$path" || { echo "  [!] $name: không resolve được origin"; continue; }
  full="$FORGE_FULLNAME"
  repo_forge=$(jq -r '.forge // empty' <<<"$repo"); [ -n "$repo_forge" ] && FORGE="$repo_forge"
  echo "== $name ($FORGE:$full) =="
  mapfile -t rl < <(jq -r '(.labels // [])[]? // empty' <<<"$repo")
  if [ "${#rl[@]}" -eq 0 ]; then rl=("${TASK_LABELS[@]}"); fi
  for l in "${rl[@]}"; do [ -n "$l" ] && create "$l" "0E8A16" "Giao task cho agent tự động" "$full"; done
  create "$RUN_LBL"  "FBCA04" "Agent đang xử lý"     "$full"
  create "$DONE_LBL" "1D76DB" "Agent đã xử lý xong"  "$full"
  create "$FAIL_LBL" "B60205" "Agent xử lý thất bại" "$full"
done

echo "Xong."
