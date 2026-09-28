#!/usr/bin/env bash
# =============================================================================
# Lớp forge: trừu tượng hoá GitHub (gh) và GitLab (glab).
#
# Quy ước: mọi hàm nhận fullname dạng `group/project` (không host). Backend
# được chọn qua biến global FORGE (github|gitlab); host GitLab qua FORGE_HOST.
#
# Dữ liệu trả về được CHUẨN HOÁ giống nhau để runner dùng chung jq:
#   issue: {number,title,body,url,labels:[names],author:{login},createdAt,updatedAt,comments:[]}
#   mr:    {number,title,body,url,headRefName,author:{login},createdAt,updatedAt,comments:[]}
#   comment: {author:{login}, body, url}
# =============================================================================

FORGE=""
FORGE_HOST=""
FORGE_FULLNAME=""

# ---------- detection ----------
# forge_detect <repo_path>: set FORGE/FORGE_HOST/FORGE_FULLNAME (không dùng trong subshell!)
forge_detect() {
  local url host path tmp
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  url="${url%.git}"
  case "$url" in
    git@*:*)     host="${url#git@}"; host="${host%%:*}"; path="${url#*:}" ;;
    ssh://git@*) tmp="${url#ssh://git@}"; host="${tmp%%/*}"; path="${tmp#*/}" ;;
    https://*)   tmp="${url#https://}"; host="${tmp%%/*}"; path="${tmp#*/}" ;;
    http://*)    tmp="${url#http://}"; host="${tmp%%/*}"; path="${tmp#*/}" ;;
    *)           return 1 ;;
  esac
  host="${host##*@}"
  case "$host" in
    *github*) FORGE="github" ;;
    *gitlab*) FORGE="gitlab" ;;
    *)        FORGE="${DEFAULT_FORGE:-github}" ;;
  esac
  FORGE_HOST="$host"
  FORGE_FULLNAME="$path"
}

# ---------- github helpers ----------
_gh() { gh "$@"; }

forge_github_issue_list() {
  local out; out=$(_gh issue list -R "$1" --state open --limit 100 \
      --json number,title,body,url,labels,author,createdAt,updatedAt 2>/dev/null) || { echo '[]'; return; }
  printf '%s' "$out" | jq '[ .[] | {number, title, body:(.body // ""), url,
      labels:[.labels[].name], author:{login:(.author.login // "")},
      createdAt, updatedAt, comments:[]} ]' 2>/dev/null || echo '[]'
}

forge_github_issue_comments() {
  _gh issue view "$2" -R "$1" --json comments --jq \
    '[ .comments[] | {author:{login:(.author.login // "")}, body:(.body // ""), url:(.url // "")} ]' 2>/dev/null || echo '[]'
}

forge_github_issue_context() {
  local tmp; tmp=$(_gh issue view "$2" -R "$1" --json title,body,comments 2>/dev/null) || { echo ""; return; }
  jq -r '"# " + .title + "\n\n" + (.body // "") + "\n\n## Comments\n" +
    ([.comments[] | select(((.body // "") | contains("<!-- pi-runner -->") | not))
      | "- @" + (.author.login // "") + ": " + (.body // "")] | join("\n"))' <<<"$tmp"
}

forge_github_issue_note() { _gh issue comment "$2" -R "$1" --body "$3"; }

forge_github_set_labels() {
  local a=(); [ -n "$3" ] && a+=(--add-label "$3"); [ -n "$4" ] && a+=(--remove-label "$4")
  [ ${#a[@]} -gt 0 ] && _gh issue edit "$2" -R "$1" "${a[@]}"
}

forge_github_mr_list() {
  local out; out=$(_gh pr list -R "$1" --state open --limit 100 \
      --json number,title,body,url,headRefName,author,createdAt,updatedAt 2>/dev/null) || { echo '[]'; return; }
  printf '%s' "$out" | jq '[ .[] | {number, title, body:(.body // ""), url, headRefName,
      author:{login:(.author.login // "")}, createdAt, updatedAt, comments:[]} ]' 2>/dev/null || echo '[]'
}

forge_github_mr_comments() {
  local conv inline
  conv=$(_gh pr view "$2" -R "$1" --json comments --jq \
      '[ .comments[] | {author:{login:(.author.login // "")}, body:(.body // ""), url:(.url // "")} ]' 2>/dev/null) || conv='[]'
  inline=$(_gh api --paginate "repos/$1/pulls/$2/comments" --jq \
      '[ .[] | {author:{login:(.user.login // "")}, body:(.body // ""), url:(.html_url // "")} ]' 2>/dev/null) || inline='[]'
  jq -cn --argjson a "$conv" --argjson b "$inline" '$a + $b'
}

forge_github_mr_target() {
  _gh pr view "$2" -R "$1" --json baseRefName --jq '.baseRefName' 2>/dev/null
}

forge_github_mr_find() {
  _gh pr list -R "$1" --head "$2" --state open --json url --jq '.[0].url // empty' 2>/dev/null
}

forge_github_mr_create() {
  _gh pr create -R "$1" --base "$2" --head "$3" --title "$4" --body "$5" 2>/dev/null
}

forge_github_mr_note() { _gh pr comment "$2" -R "$1" --body "$3"; }

forge_github_label_create() {
  _gh label create "$2" -R "$1" --color "$3" --description "$4" --force >/dev/null 2>&1
}

forge_github_current_user() { _gh api user --jq '.login' 2>/dev/null; }

# ---------- gitlab helpers ----------
_glab() {
  if [ -n "${FORGE_HOST:-}" ] && [ "$FORGE_HOST" != "gitlab.com" ]; then
    GITLAB_HOST="$FORGE_HOST" glab "$@"
  else
    glab "$@"
  fi
}
_glab_proj() { printf '%s' "$1" | sed 's|/|%2F|g'; }
_glab_review_marker() { printf '%s' '<!-- pi-runner -->'; }

forge_gitlab_issue_list() {
  local p; p=$(_glab_proj "$1")
  _glab api "projects/$p/issues?state=opened&per_page=100&order_by=created_at&sort=asc" 2>/dev/null \
    | jq '[ .[] | {number:.iid, title, body:(.description // ""), url:.web_url,
        labels:(.labels // []), author:{login:(.author.username // "")},
        createdAt:.created_at, updatedAt:.updated_at, comments:[]} ]' 2>/dev/null || echo '[]'
}

forge_gitlab_issue_comments() {
  local p; p=$(_glab_proj "$1")
  _glab api "projects/$p/issues/$2/notes?per_page=100&sort=asc" 2>/dev/null \
    | jq '[ .[] | select(.system==false) | {author:{login:(.author.username // "")},
        body:(.body // ""), url:("note:" + (.id|tostring))} ]' 2>/dev/null || echo '[]'
}

forge_gitlab_issue_context() {
  local p; p=$(_glab_proj "$1")
  local issue notes
  issue=$(_glab api "projects/$p/issues/$2" 2>/dev/null) || { echo ""; return; }
  notes=$(_glab api "projects/$p/issues/$2/notes?per_page=100&sort=asc" 2>/dev/null) || notes='[]'
  jq -rn --argjson i "$issue" --argjson n "$notes" '
    "# " + ($i.title // "") + "\n\n" + ($i.description // "") + "\n\n## Comments\n" +
    ([ $n[] | select(.system==false) | select(((.body // "") | contains("<!-- pi-runner -->") | not))
       | "- @" + (.author.username // "") + ": " + (.body // "") ] | join("\n"))'
}

forge_gitlab_issue_note() {
  local p; p=$(_glab_proj "$1")
  _glab api -X POST -f "body=$3" "projects/$p/issues/$2/notes" >/dev/null
}

forge_gitlab_set_labels() {
  local p; p=$(_glab_proj "$1"); local a=()
  [ -n "$3" ] && a+=(-f "add_labels=$3")
  [ -n "$4" ] && a+=(-f "remove_labels=$4")
  [ ${#a[@]} -gt 0 ] && _glab api -X PUT "${a[@]}" "projects/$p/issues/$2" >/dev/null
}

forge_gitlab_mr_list() {
  local p; p=$(_glab_proj "$1")
  _glab api "projects/$p/merge_requests?state=opened&per_page=100" 2>/dev/null \
    | jq '[ .[] | {number:.iid, title, body:(.description // ""), url:.web_url,
        headRefName:.source_branch, author:{login:(.author.username // "")},
        createdAt:.created_at, updatedAt:.updated_at, comments:[]} ]' 2>/dev/null || echo '[]'
}

forge_gitlab_mr_comments() {
  local p; p=$(_glab_proj "$1")
  # discussions bao gồm cả comment thường lẫn review inline
  _glab api "projects/$p/merge_requests/$2/discussions?per_page=100" 2>/dev/null \
    | jq '[ .[] | .notes[] | select(.system==false) | {author:{login:(.author.username // "")},
        body:(.body // ""), url:("disc:" + (.id|tostring))} ]' 2>/dev/null || echo '[]'
}

forge_gitlab_mr_target() {
  local p; p=$(_glab_proj "$1")
  _glab api "projects/$p/merge_requests/$2" 2>/dev/null | jq -r '.target_branch // "main"'
}

forge_gitlab_mr_find() {
  local p; p=$(_glab_proj "$1"); local b
  b=$(printf '%s' "$2" | jq -sRr @uri)
  _glab api "projects/$p/merge_requests?state=opened&source_branch=$b" 2>/dev/null \
    | jq -r '.[0].web_url // empty'
}

forge_gitlab_mr_create() {
  local p; p=$(_glab_proj "$1")
  _glab api -X POST -f "source_branch=$3" -f "target_branch=$2" -f "title=$4" -f "description=$5" \
      "projects/$p/merge_requests" 2>/dev/null | jq -r '.web_url // empty'
}

forge_gitlab_mr_note() {
  local p; p=$(_glab_proj "$1")
  _glab api -X POST -f "body=$3" "projects/$p/merge_requests/$2/notes" >/dev/null
}

forge_gitlab_label_create() {
  local p; p=$(_glab_proj "$1"); local enc
  _glab api -X POST -f "name=$2" -f "color=#$3" -f "description=$4" "projects/$p/labels" >/dev/null 2>&1 && return 0
  enc=$(printf '%s' "$2" | jq -sRr @uri)
  _glab api -X PUT -f "color=#$3" -f "description=$4" "projects/$p/labels/$enc" >/dev/null 2>&1
}

forge_gitlab_current_user() { _glab api user 2>/dev/null | jq -r '.username // empty'; }

# ---------- dispatcher ----------
forge_issue_list()      { if [ "$FORGE" = gitlab ]; then forge_gitlab_issue_list "$@"; else forge_github_issue_list "$@"; fi; }
forge_issue_comments()  { if [ "$FORGE" = gitlab ]; then forge_gitlab_issue_comments "$@"; else forge_github_issue_comments "$@"; fi; }
forge_issue_context()   { if [ "$FORGE" = gitlab ]; then forge_gitlab_issue_context "$@"; else forge_github_issue_context "$@"; fi; }
forge_issue_note()      { if [ "$FORGE" = gitlab ]; then forge_gitlab_issue_note "$@"; else forge_github_issue_note "$@"; fi; }
forge_set_labels()      { if [ "$FORGE" = gitlab ]; then forge_gitlab_set_labels "$@"; else forge_github_set_labels "$@"; fi; }
forge_mr_list()         { if [ "$FORGE" = gitlab ]; then forge_gitlab_mr_list "$@"; else forge_github_mr_list "$@"; fi; }
forge_mr_comments()     { if [ "$FORGE" = gitlab ]; then forge_gitlab_mr_comments "$@"; else forge_github_mr_comments "$@"; fi; }
forge_mr_target()       { if [ "$FORGE" = gitlab ]; then forge_gitlab_mr_target "$@"; else forge_github_mr_target "$@"; fi; }
forge_mr_find()         { if [ "$FORGE" = gitlab ]; then forge_gitlab_mr_find "$@"; else forge_github_mr_find "$@"; fi; }
forge_mr_create()       { if [ "$FORGE" = gitlab ]; then forge_gitlab_mr_create "$@"; else forge_github_mr_create "$@"; fi; }
forge_mr_note()         { if [ "$FORGE" = gitlab ]; then forge_gitlab_mr_note "$@"; else forge_github_mr_note "$@"; fi; }
forge_label_create()    { if [ "$FORGE" = gitlab ]; then forge_gitlab_label_create "$@"; else forge_github_label_create "$@"; fi; }
forge_current_user()    { if [ "$FORGE" = gitlab ]; then forge_gitlab_current_user "$@"; else forge_github_current_user "$@"; fi; }
