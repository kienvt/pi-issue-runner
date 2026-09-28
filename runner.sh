#!/usr/bin/env bash
# =============================================================================
# Pi GitHub Issue Runner (multi-repo)
#
# Polls GitHub issues, and when an issue is labeled (labels: ai|agent) or a
# trusted author posts a trigger comment (!ai | !agent | @ai | @agent), it
# spins up a git worktree, runs `pi` in print mode to do the work, then pushes
# a branch and opens/updates a Pull Request.
#
# Usage:
#   runner.sh                # one pass over all enabled repos
#   runner.sh --dry-run      # detect and log, do NOT run pi / push / comment
#   runner.sh --repo Finance # limit to one repo by name
# =============================================================================
set -uo pipefail

RUNNER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$RUNNER_DIR/repos.json"
STATE_DIR="$RUNNER_DIR/state"
LOG_DIR="$RUNNER_DIR/logs"
LOCK_FILE="$RUNNER_DIR/runner.lock"
LOG_FILE="$LOG_DIR/runner.log"

mkdir -p "$STATE_DIR" "$LOG_DIR"

# ---- environment ------------------------------------------------------------
# shellcheck disable=SC1091
[ -f "$RUNNER_DIR/env" ] && { set -a; . "$RUNNER_DIR/env"; set +a; }

# Ensure HOME is set (systemd --user may not export it).
: "${HOME:=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)}"
export HOME

# Ensure `pi` is on PATH; search common install locations if missing.
if ! command -v pi >/dev/null 2>&1; then
  for d in "$HOME/.local/bin" "$HOME/.bun/bin" $HOME/.local/share/pi-node/*/bin /usr/local/bin; do
    if [ -x "$d/pi" ]; then PATH="$d:$PATH"; break; fi
  done
  export PATH
fi

# ---- args -------------------------------------------------------------------
DRY_RUN=""
ONLY_REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --repo)    ONLY_REPO="${2:-}"; shift ;;
    --once)    : ;;
  esac
  shift
done

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2; }

# single-instance lock
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "Another runner instance is active; skipping this tick."
  exit 0
fi

# ---- config -----------------------------------------------------------------
[ -f "$CONFIG" ] || { log "FATAL: missing config $CONFIG"; exit 1; }

DEF_LABELS=$(jq -r '(.defaults.labels // ["ai","agent"]) | join(",")' "$CONFIG")
DEF_TRIGGERS=$(jq -r '(.defaults.triggers // ["!ai","!agent","@ai","@agent"]) | join(",")' "$CONFIG")
DEF_TRUSTED=$(jq -r '(.defaults.trusted_authors // []) | join(",")' "$CONFIG")
DEF_MODEL=$(jq -r '.defaults.model // "opencode-go/deepseek-v4.1-flash"' "$CONFIG")
DEF_BASE=$(jq -r '.defaults.base_branch // "main"' "$CONFIG")
BOT_MARKER=$(jq -r '.runner.bot_marker // "<!-- pi-runner -->"' "$CONFIG")
MAX_TASKS=$(jq -r '.runner.max_tasks_per_tick // 1' "$CONFIG")
PI_TIMEOUT=$(jq -r '.runner.pi_timeout_sec // 1800' "$CONFIG")
LBL_RUNNING=$(jq -r '.runner.status_labels.running // "ai-running"' "$CONFIG")
LBL_DONE=$(jq -r '.runner.status_labels.done // "ai-done"' "$CONFIG")
LBL_FAILED=$(jq -r '.runner.status_labels.failed // "ai-failed"' "$CONFIG")
WT_ROOT=$(jq -r '.runner.worktree_root // "'"$RUNNER_DIR"'/worktrees"' "$CONFIG")
if [ -z "$DRY_RUN" ]; then DRY_RUN=$(jq -r '.runner.dry_run // false' "$CONFIG"); fi
mkdir -p "$WT_ROOT"

TASKS_DONE=0

is_dry() { [ "$DRY_RUN" = "true" ] || [ "$DRY_RUN" = "1" ]; }

# ---- helpers ----------------------------------------------------------------
repo_fullname() {
  local url
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  url="${url%.git}"
  url="${url#git@github.com:}"
  url="${url#https://github.com/}"
  url="${url#http://github.com/}"
  printf '%s' "$url"
}

build_trigger_regex() {  # comma-separated triggers -> regex with word boundaries
  local csv="$1" out="" t e
  local IFS=','
  for t in $csv; do
    [ -z "$t" ] && continue
    e=$(printf '%s' "$t" | sed 's/[][\\.^$*+?(){}|/]/\\&/g')
    out="${out:+$out|}$e\\b"
  done
  printf '%s' "$out"
}

csv_to_json() { printf '%s' "$1" | jq -R 'split(",") | map(select(. != ""))'; }

truncate_tail() { tail -c "${2:-4000}" "$1" 2>/dev/null || true; }

# set_issue_status <num> <fullname> <add-label|-> <remove-label|->
set_issue_status() {
  local num="$1" full="$2" add="$3" remove="$4"
  is_dry && return 0
  local args=()
  [ "$add" != "-" ] && args+=(--add-label "$add")
  [ "$remove" != "-" ] && args+=(--remove-label "$remove")
  [ ${#args[@]} -eq 0 ] && return 0
  gh issue edit "$num" -R "$full" "${args[@]}" >/dev/null 2>>"$LOG_FILE" || true
}

# ---- one issue --------------------------------------------------------------
process_issue() {
  local name="$1" path="$2" fullname="$3" base="$4" model="$5"
  local triggers="$6" trusted="$7" state_file="$8" issue="$9"

  local num title body url key
  num=$(jq -r '.number' <<<"$issue")
  title=$(jq -r '.title' <<<"$issue")
  body=$(jq -r '.body // ""' <<<"$issue")
  url=$(jq -r '.url' <<<"$issue")
  key="$fullname#$num"

  local initial_done processed_urls stored_hash req_hash
  initial_done=$(jq -r --arg k "$key" '.[$k].initial_done // false' "$state_file")
  processed_urls=$(jq -c --arg k "$key" '.[$k].processed_comment_urls // []' "$state_file")
  stored_hash=$(jq -r --arg k "$key" '.[$k].req_hash // ""' "$state_file")
  req_hash=$(printf '%s\n---\n%s' "$title" "$body" | sha256sum | cut -d' ' -f1)

  local trig_re trusted_json new_triggers nt_count
  trig_re=$(build_trigger_regex "$triggers")
  trusted_json=$(csv_to_json "$trusted")
  new_triggers=$(jq -c \
      --arg re "$trig_re" --arg marker "$BOT_MARKER" \
      --argjson done "$processed_urls" --argjson trusted "$trusted_json" '
      [ (.comments // [])[]
        | select((.author.login // "") as $a | ($trusted | index($a)) != null)
        | select((.body // "") | test($re; "i"))
        | select((.body // "") | contains($marker) | not)
        | select((.url // "") as $u | ($done | index($u)) == null)
      ]' <<<"$issue")
  nt_count=$(jq 'length' <<<"$new_triggers")

  local do_run=false reason="" task_text=""
  local trigger_urls='[]'

  if [ "$initial_done" != "true" ]; then
    do_run=true; reason="label(initial)"; task_text="$body"
  elif [ -n "$stored_hash" ] && [ "$req_hash" != "$stored_hash" ]; then
    do_run=true; reason="issue-edited"; task_text="$body"
  fi
  if [ "$nt_count" -gt 0 ]; then
    do_run=true; reason="comment"
    task_text=$(jq -r '.[-1].body // ""' <<<"$new_triggers")
    trigger_urls=$(jq -c '[.[].url]' <<<"$new_triggers")
  fi

  [ "$do_run" = true ] || return 0

  log "TASK $key ('$title') -> trigger=$reason"

  if is_dry; then
    log "  [dry-run] would run pi in worktree for $key (triggers pending: $nt_count)"
    return 0
  fi

  if [ "$TASKS_DONE" -ge "$MAX_TASKS" ]; then
    log "  Reached max_tasks_per_tick=$MAX_TASKS; deferring $key to next tick."
    return 0
  fi
  TASKS_DONE=$((TASKS_DONE + 1))

  # --- mark as running ------------------------------------------------------
  set_issue_status "$num" "$fullname" "$LBL_RUNNING" "$LBL_DONE"
  set_issue_status "$num" "$fullname" "-" "$LBL_FAILED"

  # --- build prompt ---------------------------------------------------------
  local prompt_file run_base branch wt out_log err_log run_log
  prompt_file=$(mktemp)
  {
    echo "# Task từ GitHub Issue"
    echo
    echo "- Repo: \`$fullname\`"
    echo "- Issue: #$num — $title"
    echo "- URL: $url"
    echo "- Nhánh làm việc: \`ai/issue-$num\` (base: \`$base\`)"
    echo
    if [ "$reason" = "comment" ]; then
      echo "## Yêu cầu cập nhật mới nhất (từ comment)"
      echo
      echo "$task_text"
      echo
      echo "_(Đây là follow-up trong cùng session — bối cảnh task gốc bạn đã có.)_"
      echo
    else
      echo "## Nội dung issue"
      echo
      echo "$body"
      echo
      if [ "$reason" = "issue-edited" ]; then
        echo "> ⚠️ Nội dung issue vừa được CHỈNH SỬA — đây là yêu cầu mới nhất."
        echo "> Hãy ĐIỀU CHỈNH thay đổi hiện có cho khớp yêu cầu mới, KHÔNG làm lại từ đầu."
        echo
      fi
    fi
  } >"$prompt_file"

  # --- worktree -------------------------------------------------------------
  run_base="$base"
  branch="ai/issue-$num"
  wt="$WT_ROOT/${name}/issue-$num"
  rm -rf "$wt"
  mkdir -p "$(dirname -- "$wt")"
  if ! git -C "$path" fetch origin --quiet 2>>"$LOG_FILE"; then
    log "  git fetch failed for $name; skipping $key."
    rm -f "$prompt_file"; return 0
  fi
  # Nối tiếp nhánh/PR cũ nếu đã tồn tại (để cập nhật theo yêu cầu mới),
  # ngược lại tạo mới từ base branch.
  local wt_base="origin/$run_base"
  if git -C "$path" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    wt_base="origin/$branch"
    log "  Tiếp tục nhánh cũ $branch (cập nhật PR đang mở)."
  fi
  if ! git -C "$path" worktree add -f "$wt" -B "$branch" "$wt_base" >>"$LOG_FILE" 2>&1; then
    log "  git worktree add failed for $key; skipping."
    rm -f "$prompt_file"; return 0
  fi

  # --- run pi ---------------------------------------------------------------
  out_log=$(mktemp); err_log=$(mktemp)
  run_log="$LOG_DIR/${fullname//\//__}_issue-${num}_$(date +%Y%m%d-%H%M%S).log"
  log "  Running pi (model=$model, timeout=${PI_TIMEOUT}s)..."
  ( cd "$wt" && timeout "$PI_TIMEOUT" pi --print --approve \
      --session-id "${name}-issue-$num" \
      --model "$model" \
      --append-system-prompt "$RUNNER_DIR/system-prompt.md" \
      --append-system-prompt "$RUNNER_DIR/task-rules.md" \
      "$(cat "$prompt_file")" ) >"$out_log" 2>"$err_log"
  local rc=$?
  { echo "===== pi stdout ====="; cat "$out_log"; echo "===== pi stderr ====="; cat "$err_log"; } >"$run_log"
  log "  pi finished rc=$rc (log: $run_log)"
  rm -f "$prompt_file"

  local summary
  summary=$(truncate_tail "$out_log" 4000)
  [ -n "$summary" ] || summary=$(truncate_tail "$err_log" 2000)

  # --- commit / push / PR ---------------------------------------------------
  local changed ahead pr_url pre_head post_head made_changes
  changed="$(git -C "$wt" status --porcelain 2>/dev/null)"
  pre_head=$(git -C "$wt" rev-parse HEAD 2>/dev/null || echo "")

  if [ -n "$changed" ]; then
    git -C "$wt" add -A
    if ! git -C "$wt" commit -q -m "ai: resolve #$num — $title"; then
      log "  commit failed for $key"
    fi
  fi
  post_head=$(git -C "$wt" rev-parse HEAD 2>/dev/null || echo "")
  made_changes=false
  [ "$pre_head" != "$post_head" ] && made_changes=true
  ahead=$(git -C "$wt" rev-list --count "origin/$run_base..HEAD" 2>/dev/null || echo 0)

  pr_url=""
  if [ "$made_changes" = true ]; then
    git -C "$wt" fetch origin "$branch" --quiet 2>/dev/null || true
    if git -C "$wt" push -u origin "$branch" --force-with-lease >>"$LOG_FILE" 2>&1 \
       || git -C "$wt" push -u origin "$branch" --force >>"$LOG_FILE" 2>&1; then
      pr_url=$(gh pr list -R "$fullname" --head "$branch" --state open --json url --jq '.[0].url // empty' 2>/dev/null)
      if [ -z "$pr_url" ]; then
        local pr_body
        pr_body=$(printf 'Tự động xử lý issue #%s.\n\nCloses #%s\n\n---\n\n<details><summary>Tóm tắt từ agent</summary>\n\n```\n%s\n```\n\n</details>\n\n_Mở bởi pi-issue-runner._' \
          "$num" "$num" "$summary")
        pr_url=$(gh pr create -R "$fullname" --base "$run_base" --head "$branch" \
            --title "ai: #$num — $title" --body "$pr_body" 2>>"$LOG_FILE")
      fi
      log "  PR: ${pr_url:-<failed>}"
    else
      log "  push failed for $key"
    fi
  fi

  post_comment() {
    local txt="$1"
    gh issue comment "$num" -R "$fullname" --body "$BOT_MARKER
$txt" >/dev/null 2>>"$LOG_FILE" && log "  Comment posted on $key" || log "  Comment failed on $key"
  }

  if [ -n "$pr_url" ]; then
    post_comment "$(printf '🤖 Đã xử lý task.\n\n**Pull Request:** %s\n\n**Tóm tắt agent:**\n\n```\n%s\n```' "$pr_url" "$summary")"
  elif [ "$made_changes" = true ]; then
    post_comment "$(printf '🤖 Đã tạo thay đổi nhưng **push/PR thất bại**. Xem log: `%s`\n\n```\n%s\n```' "$run_log" "$summary")"
  else
    post_comment "$(printf '🤖 Đã chạy agent nhưng **không có thay đổi** nào được tạo.\n\n```\n%s\n```' "$summary")"
  fi

  # --- status label ---------------------------------------------------------
  local final_label
  if [ "$rc" -ne 0 ] || { [ "$made_changes" = true ] && [ -z "$pr_url" ]; }; then
    final_label="$LBL_FAILED"
  else
    final_label="$LBL_DONE"
  fi
  set_issue_status "$num" "$fullname" "$final_label" "$LBL_RUNNING"

  # --- cleanup & state ------------------------------------------------------
  git -C "$path" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
  git -C "$path" worktree prune >/dev/null 2>&1 || true

  local new_state
  new_state=$(jq \
      --arg k "$key" --argjson urls "$trigger_urls" --arg ts "$(date -Is)" \
      --arg st "$final_label" --arg rh "$req_hash" \
      --arg pr "${pr_url:-}" '
      .[$k] = ((.[$k] // {}) + {
          initial_done: true,
          last_run: $ts,
          last_status: $st,
          last_pr: $pr,
          req_hash: $rh
      })
      | .[$k].processed_comment_urls =
          (((.[$k].processed_comment_urls // []) + $urls) | unique)
      ' "$state_file")
  printf '%s' "$new_state" > "$state_file"
}

# ---- PR feedback ------------------------------------------------------------
process_pr_feedback() {
  local name="$1" path="$2" fullname="$3" model="$4" triggers="$5" trusted="$6"
  local state_file="$7" pr="$8"

  local prnum title branch url linked key
  prnum=$(jq -r '.number' <<<"$pr")
  title=$(jq -r '.title' <<<"$pr")
  url=$(jq -r '.url' <<<"$pr")
  branch=$(jq -r '.headRefName' <<<"$pr")
  linked=$(sed -n 's|^ai/issue-\([0-9][0-9]*\)$|\1|p' <<<"$branch")
  key="$fullname#pr-$prnum"
  local sess_id
  if [ -n "$linked" ]; then sess_id="${name}-issue-$linked"; else sess_id="${name}-pr-$prnum"; fi

  local processed_urls trig_re trusted_json
  processed_urls=$(jq -c --arg k "$key" '.[$k].processed_comment_urls // []' "$state_file")
  trig_re=$(build_trigger_regex "$triggers")
  trusted_json=$(csv_to_json "$trusted")

  local conv review allc new_triggers nt
  conv=$(jq -c '[ (.comments // [])[] | {author: {login: (.author.login // "")}, body: (.body // ""), url: (.url // "")} ]' <<<"$pr")
  review=$(gh api --paginate "repos/$fullname/pulls/$prnum/comments" 2>/dev/null \
            | jq -c '[ .[] | {author: {login: (.user.login // "")}, body: (.body // ""), url: (.html_url // "")} ]' 2>/dev/null)
  [ -n "$review" ] || review='[]'
  allc=$(jq -cn --argjson a "$conv" --argjson b "$review" '$a + $b')

  new_triggers=$(jq -c \
      --arg re "$trig_re" --arg marker "$BOT_MARKER" \
      --argjson done "$processed_urls" --argjson trusted "$trusted_json" '
      [ .[]
        | select(.author.login as $a | ($trusted | index($a)) != null)
        | select((.body) | test($re; "i"))
        | select((.body) | contains($marker) | not)
        | select((.url) as $u | ($done | index($u)) == null)
      ]' <<<"$allc")
  nt=$(jq 'length' <<<"$new_triggers")
  [ "$nt" -gt 0 ] || return 0

  local task_text trigger_urls
  task_text=$(jq -r '.[-1].body' <<<"$new_triggers")
  trigger_urls=$(jq -c '[.[].url]' <<<"$new_triggers")

  log "TASK $key ('$title') -> trigger=pr-feedback"

  if is_dry; then
    log "  [dry-run] would run pi for PR $key (pending: $nt)"
    return 0
  fi
  if [ "$TASKS_DONE" -ge "$MAX_TASKS" ]; then
    log "  Reached max_tasks_per_tick=$MAX_TASKS; deferring $key."
    return 0
  fi
  TASKS_DONE=$((TASKS_DONE + 1))

  [ -n "$linked" ] && set_issue_status "$linked" "$fullname" "$LBL_RUNNING" "$LBL_DONE"

  # worktree từ chính nhánh PR
  local wt="$WT_ROOT/${name}/issue-$linked"
  [ -z "$linked" ] && wt="$WT_ROOT/${name}/pr-$prnum"
  rm -rf "$wt"; mkdir -p "$(dirname -- "$wt")"
  if ! git -C "$path" fetch origin --quiet 2>>"$LOG_FILE"; then
    log "  git fetch failed for $name; skipping $key."
    [ -n "$linked" ] && set_issue_status "$linked" "$fullname" "$LBL_FAILED" "$LBL_RUNNING"
    return 0
  fi
  if ! git -C "$path" worktree add -f "$wt" -B "$branch" "origin/$branch" >>"$LOG_FILE" 2>&1; then
    log "  git worktree add failed for $key; skipping."
    [ -n "$linked" ] && set_issue_status "$linked" "$fullname" "$LBL_FAILED" "$LBL_RUNNING"
    return 0
  fi

  local prompt_file; prompt_file=$(mktemp)
  local linked_ctx=""
  [ -n "$linked" ] && linked_ctx=$(gh issue view "$linked" -R "$fullname" --json title,body --jq '"# " + .title + "\n\n" + (.body // "")' 2>/dev/null)
  {
    echo "# Phản hồi trên Pull Request"
    echo
    echo "- Repo: \`$fullname\`"
    echo "- PR: #$prnum — $title ($url)"
    [ -n "$linked" ] && echo "- Issue liên quan: #$linked"
    echo "- Nhánh: \`$branch\` (PR đang mở — hãy chỉnh tiếp trên nhánh này)"
    echo
    if [ -n "$linked_ctx" ]; then
      echo "## Bối cảnh task gốc (issue #$linked)"
      echo
      echo "$linked_ctx"
      echo
    fi
    echo "## Nội dung PR"
    echo
    jq -r '.body // ""' <<<"$pr"
    echo
    echo "## Phản hồi mới cần xử lý"
    echo
    echo "$task_text"
    echo
    echo "_(Đây là follow-up trong cùng session với task gốc. Nhánh hiện tại đã có thay đổi trước đó.)_"
    echo
  } >"$prompt_file"

  local out_log err_log run_log rc
  out_log=$(mktemp); err_log=$(mktemp)
  run_log="$LOG_DIR/${fullname//\//__}_pr-${prnum}_$(date +%Y%m%d-%H%M%S).log"
  log "  Running pi for PR $key (model=$model)..."
  ( cd "$wt" && timeout "$PI_TIMEOUT" pi --print --approve \
      --session-id "$sess_id" \
      --model "$model" \
      --append-system-prompt "$RUNNER_DIR/system-prompt.md" \
      --append-system-prompt "$RUNNER_DIR/task-rules.md" \
      "$(cat "$prompt_file")" ) >"$out_log" 2>"$err_log"
  rc=$?
  { echo "===== pi stdout ====="; cat "$out_log"; echo "===== pi stderr ====="; cat "$err_log"; } >"$run_log"
  rm -f "$prompt_file"
  log "  pi finished rc=$rc (log: $run_log)"

  local summary; summary=$(truncate_tail "$out_log" 4000); [ -n "$summary" ] || summary=$(truncate_tail "$err_log" 2000)

  local changed pre_head post_head made_changes
  changed="$(git -C "$wt" status --porcelain 2>/dev/null)"
  pre_head=$(git -C "$wt" rev-parse HEAD 2>/dev/null || echo "")
  if [ -n "$changed" ]; then
    git -C "$wt" add -A
    git -C "$wt" commit -q -m "ai: address PR #$prnum feedback" || log "  commit failed for $key"
  fi
  post_head=$(git -C "$wt" rev-parse HEAD 2>/dev/null || echo "")
  made_changes=false; [ "$pre_head" != "$post_head" ] && made_changes=true

  local pushed=false
  if [ "$made_changes" = true ]; then
    if git -C "$wt" push origin "$branch" >>"$LOG_FILE" 2>&1 \
       || git -C "$wt" push origin "$branch" --force-with-lease >>"$LOG_FILE" 2>&1; then
      pushed=true
    fi
  fi

  local final_label
  if [ "$rc" -ne 0 ] || { [ "$made_changes" = true ] && [ "$pushed" != true ]; }; then
    final_label="$LBL_FAILED"
  else
    final_label="$LBL_DONE"
  fi

  local msg
  if [ "$pushed" = true ]; then
    msg=$(printf '🤖 Đã cập nhật theo phản hồi.\n\n```\n%s\n```' "$summary")
  elif [ "$made_changes" = true ]; then
    msg=$(printf '🤖 Có thay đổi nhưng **push thất bại**. Xem log: `%s`\n\n```\n%s\n```' "$run_log" "$summary")
  else
    msg=$(printf '🤖 Đã chạy agent nhưng **không có thay đổi mới**.\n\n```\n%s\n```' "$summary")
  fi
  gh pr comment "$prnum" -R "$fullname" --body "$BOT_MARKER
$msg" >/dev/null 2>>"$LOG_FILE" || true

  [ -n "$linked" ] && set_issue_status "$linked" "$fullname" "$final_label" "$LBL_RUNNING"

  git -C "$path" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
  git -C "$path" worktree prune >/dev/null 2>&1 || true

  local new_state
  new_state=$(jq --arg k "$key" --argjson urls "$trigger_urls" --arg ts "$(date -Is)" \
      --arg st "$final_label" --arg br "$branch" '
      .[$k] = ((.[$k] // {}) + {last_run: $ts, last_status: $st, branch: $br})
      | .[$k].processed_comment_urls =
          (((.[$k].processed_comment_urls // []) + $urls) | unique)
      ' "$state_file")
  printf '%s' "$new_state" > "$state_file"
}

# ---- one repo ---------------------------------------------------------------
process_repo() {
  local repo_json="$1"
  local name path labels triggers trusted model base fullname state_file issues filtered count

  name=$(jq -r '.name' <<<"$repo_json")
  path=$(jq -r '.path' <<<"$repo_json")
  [ "$ONLY_REPO" != "" ] && [ "$ONLY_REPO" != "$name" ] && return 0

  labels=$(jq -r '(.labels // []) | join(",")' <<<"$repo_json"); [ -z "$labels" ] && labels="$DEF_LABELS"
  triggers=$(jq -r '(.triggers // []) | join(",")' <<<"$repo_json"); [ -z "$triggers" ] && triggers="$DEF_TRIGGERS"
  trusted=$(jq -r '(.trusted_authors // []) | join(",")' <<<"$repo_json"); [ -z "$trusted" ] && trusted="$DEF_TRUSTED"
  model=$(jq -r '.model // empty' <<<"$repo_json"); [ -z "$model" ] && model="$DEF_MODEL"
  base=$(jq -r '.base_branch // empty' <<<"$repo_json"); [ -z "$base" ] && base="$DEF_BASE"

  if [ ! -d "$path/.git" ] && [ ! -f "$path/.git" ]; then
    log "SKIP $name: '$path' is not a git repo."; return 0
  fi
  fullname=$(repo_fullname "$path") || { log "SKIP $name: cannot resolve origin."; return 0; }

  log "=== Repo $name ($fullname) ==="
  state_file="$STATE_DIR/${fullname//\//__}.json"
  [ -f "$state_file" ] || echo '{}' > "$state_file"

  issues=$(gh issue list -R "$fullname" --state open --limit 100 \
            --json number,title,body,url,labels,comments,author,updatedAt,createdAt 2>>"$LOG_FILE")
  [ -n "$issues" ] || { log "  (no issues or gh failed)"; issues='[]'; }

  local label_json
  label_json=$(csv_to_json "$labels")
  filtered=$(jq -c --argjson want "$label_json" '
      [ .[] | select(((.labels | map(.name)) as $l
                      | ($want | any(. as $w | $l | index($w))))) ]
      | sort_by(.createdAt)' <<<"$issues")
  count=$(jq 'length' <<<"$filtered")
  log "  Labeled issues: $count"

  local i=0
  while [ "$i" -lt "$count" ]; do
    [ "$TASKS_DONE" -ge "$MAX_TASKS" ] && ! is_dry && break
    process_issue "$name" "$path" "$fullname" "$base" "$model" \
                  "$triggers" "$trusted" "$state_file" "$(jq -c ".[$i]" <<<"$filtered")"
    i=$((i + 1))
  done

  # --- PR feedback -----------------------------------------------------------
  local prs pr_ai pr_count j
  prs=$(gh pr list -R "$fullname" --state open --limit 100 \
          --json number,title,body,url,headRefName,comments,author,updatedAt,createdAt 2>>"$LOG_FILE")
  [ -n "$prs" ] || prs='[]'
  pr_ai=$(jq -c '[ .[] | select(.headRefName | test("^ai/issue-[0-9]+$")) ]' <<<"$prs")
  pr_count=$(jq 'length' <<<"$pr_ai")
  log "  AI PRs: $pr_count"
  j=0
  while [ "$j" -lt "$pr_count" ]; do
    [ "$TASKS_DONE" -ge "$MAX_TASKS" ] && ! is_dry && break
    process_pr_feedback "$name" "$path" "$fullname" "$model" \
                        "$triggers" "$trusted" "$state_file" "$(jq -c ".[$j]" <<<"$pr_ai")"
    j=$((j + 1))
  done
}
export -f process_issue log is_dry truncate_tail csv_to_json build_trigger_regex 2>/dev/null || true

# ---- main -------------------------------------------------------------------
log "----- runner start (dry_run=${DRY_RUN:-false}) -----"
while IFS= read -r repo_json; do
  process_repo "$repo_json"
  [ "$TASKS_DONE" -ge "$MAX_TASKS" ] && ! is_dry && break
done < <(jq -c '.repos[] | select(.enabled != false)' "$CONFIG")
log "----- runner end (tasks_run=$TASKS_DONE) -----"
