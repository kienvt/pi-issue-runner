#!/usr/bin/env bash
# =============================================================================
# Tạo các label cần thiết trên mọi repo trong registry.
#   ./setup-repo.sh
# =============================================================================
set -uo pipefail

RUNNER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$RUNNER_DIR/repos.json"
# shellcheck disable=SC1091
[ -f "$RUNNER_DIR/env" ] && { set -a; . "$RUNNER_DIR/env"; set +a; }

[ -f "$CONFIG" ] || { echo "Không thấy $CONFIG"; exit 1; }

repo_fullname() {
  local url
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  url="${url%.git}"; url="${url#git@github.com:}"
  url="${url#https://github.com/}"; url="${url#http://github.com/}"
  printf '%s' "$url"
}

# label chung cho task
mapfile -t TASK_LABELS < <(jq -r '.defaults.labels[]? // empty' "$CONFIG")
# label trạng thái
mapfile -t RUN_LBL  < <(jq -r '.runner.status_labels.running // "ai-running"' "$CONFIG")
mapfile -t DONE_LBL < <(jq -r '.runner.status_labels.done // "ai-done"' "$CONFIG")
mapfile -t FAIL_LBL < <(jq -r '.runner.status_labels.failed // "ai-failed"' "$CONFIG")

create() { # name color desc repo
  gh label create "$1" -R "$4" --color "$2" --description "$3" --force >/dev/null 2>&1 \
    && echo "  [+] $4: $1" || echo "  [!] $4: $1 (lỗi)"
}

jq -c '.repos[] | select(.enabled != false)' "$CONFIG" | while read -r repo; do
  path=$(jq -r '.path' <<<"$repo")
  name=$(jq -r '.name' <<<"$repo")
  full=$(repo_fullname "$path") || { echo "  [!] $name: không resolve được origin"; continue; }
  echo "== $name ($full) =="
  # task labels (có thể override theo repo)
  mapfile -t rl < <(jq -r '(.labels // [])[]? // empty' <<<"$repo")
  if [ "${#rl[@]}" -eq 0 ]; then rl=("${TASK_LABELS[@]}"); fi
  for l in "${rl[@]}"; do [ -n "$l" ] && create "$l" "0E8A16" "Giao task cho agent tự động" "$full"; done
  create "${RUN_LBL[0]}"  "FBCA04" "Agent đang xử lý"        "$full"
  create "${DONE_LBL[0]}" "1D76DB" "Agent đã xử lý xong"     "$full"
  create "${FAIL_LBL[0]}" "B60205" "Agent xử lý thất bại"    "$full"
done

echo "Xong."
