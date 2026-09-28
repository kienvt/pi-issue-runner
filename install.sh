#!/usr/bin/env bash
# =============================================================================
# Installer for Pi GitHub/GitLab Issue Runner
#
#   ./install.sh                 # cài vào ~/.pi-issue-runner
#   ./install.sh --enable        # cài + bật systemd timer luôn
#   ./install.sh --setup-labels  # tạo label trên các repo trong registry
#   ./install.sh --prefix /opt/pi-issue-runner
#   ./install.sh --no-systemd    # không đụng systemd
#
# Hỗ trợ GitHub (gh) và GitLab (glab). Cần ít nhất một trong hai đã đăng nhập.
# =============================================================================
set -euo pipefail

PKG_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.pi-issue-runner}"
ENABLE_TIMER=0
SETUP_LABELS=0
NO_SYSTEMD=0

usage() {
  cat <<'EOF'
Cách dùng: install.sh [tùy chọn]
  --enable         cài xong bật luôn systemd timer
  --setup-labels   tạo label ai/agent/ai-* trên mọi repo trong registry
  --prefix DIR     đổi thư mục cài (mặc định ~/.pi-issue-runner)
  --no-systemd     không cài systemd user units
  -h, --help       hiện trợ giúp
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix|--dir) INSTALL_DIR="${2:-}"; shift ;;
    --enable)       ENABLE_TIMER=1 ;;
    --setup-labels) SETUP_LABELS=1 ;;
    --no-systemd)   NO_SYSTEMD=1 ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "Tùy chọn lạ: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

echo "== Cài Pi Issue Runner =="
echo "   Nguồn : $PKG_DIR"
echo "   Đích  : $INSTALL_DIR"
echo

# ---- dependencies -----------------------------------------------------------
missing=0
for c in bash git jq flock sha256sum curl; do
  command -v "$c" >/dev/null 2>&1 || { echo "  [!] thiếu: $c"; missing=1; }
done
# pi có thể nằm ngoài PATH
if ! command -v pi >/dev/null 2>&1; then
  found_pi=""
  for d in "$HOME/.local/bin" "$HOME/.bun/bin" $HOME/.local/share/pi-node/*/bin /usr/local/bin; do
    [ -x "$d/pi" ] && { found_pi="$d/pi"; break; }
  done
  if [ -n "$found_pi" ]; then echo "  [i] tìm thấy pi tại: $found_pi"
  else echo "  [!] thiếu: pi (cài theo hướng dẫn pi.dev)"; missing=1; fi
fi

# ---- forge CLI (gh hoặc glab) ----------------------------------------------
HAS_GH=0; HAS_GLAB=0
command -v gh   >/dev/null 2>&1 && HAS_GH=1
command -v glab >/dev/null 2>&1 && HAS_GLAB=1
if [ "$HAS_GH" = 0 ] && [ "$HAS_GLAB" = 0 ]; then
  echo "  [!] cần cài ít nhất một trong: gh (GitHub CLI) hoặc glab (GitLab CLI)"; missing=1
fi
if [ "$missing" = 1 ]; then
  echo; echo "Cài đủ dependency rồi chạy lại install.sh."; exit 1
fi

# ---- auth -------------------------------------------------------------------
GH_USER=""; GLAB_USER=""; GH_OK=0; GLAB_OK=0
if [ "$HAS_GH" = 1 ] && gh auth status >/dev/null 2>&1; then
  GH_OK=1; GH_USER="$(gh api user --jq .login 2>/dev/null || true)"
  echo "  [i] GitHub user: ${GH_USER:-<không rõ>}"
fi
if [ "$HAS_GLAB" = 1 ] && glab auth status >/dev/null 2>&1; then
  GLAB_OK=1; GLAB_USER="$(glab api user 2>/dev/null | jq -r '.username // empty' 2>/dev/null || true)"
  echo "  [i] GitLab user: ${GLAB_USER:-<không rõ>}"
fi
if [ "$GH_OK" = 0 ] && [ "$GLAB_OK" = 0 ]; then
  echo "  [!] chưa đăng nhập CLI nào. Chạy: gh auth login  HOẶC  glab auth login"; exit 1
fi

# ---- copy files -------------------------------------------------------------
mkdir -p "$INSTALL_DIR"/state "$INSTALL_DIR"/logs "$INSTALL_DIR"/worktrees
for f in runner.sh forge.sh setup-repo.sh system-prompt.md task-rules.md \
         review-system-prompt.md review-rules.md README.md; do
  cp -f "$PKG_DIR/$f" "$INSTALL_DIR/$f"
done
chmod 755 "$INSTALL_DIR/runner.sh" "$INSTALL_DIR/setup-repo.sh"

# ---- env (token) ------------------------------------------------------------
if [ ! -f "$INSTALL_DIR/env" ]; then
  umask 077
  : > "$INSTALL_DIR/env"
  if [ "$GH_OK" = 1 ]; then
    printf 'GH_TOKEN=%q\n' "$(gh auth token)" >> "$INSTALL_DIR/env"
  fi
  if [ "$GLAB_OK" = 1 ]; then
    GTOK="$(glab auth status --show-token 2>/dev/null | sed -n 's/.*Token: *//p' | head -1)"
    [ -n "$GTOK" ] && printf 'GITLAB_TOKEN=%q\n' "$GTOK" >> "$INSTALL_DIR/env"
  fi
  chmod 600 "$INSTALL_DIR/env"
  echo "  [+] đã tạo $INSTALL_DIR/env (chmod 600)"
else
  echo "  [i] giữ nguyên env hiện có"
fi

# ---- repos.json -------------------------------------------------------------
if [ ! -f "$INSTALL_DIR/repos.json" ]; then
  cp -f "$PKG_DIR/repos.json.example" "$INSTALL_DIR/repos.json"
  users_json="$(jq -n --arg a "$GH_USER" --arg b "$GLAB_USER" \
      '[ $a, $b ] | map(select(. != ""))')"
  if [ "$(jq 'length' <<<"$users_json")" -gt 0 ]; then
    tmp="$(mktemp)"
    jq --argjson u "$users_json" '.defaults.trusted_authors = $u' "$INSTALL_DIR/repos.json" > "$tmp" \
      && mv "$tmp" "$INSTALL_DIR/repos.json"
  fi
  echo "  [+] đã tạo $INSTALL_DIR/repos.json — sửa đường dẫn repo vào đây"
else
  echo "  [i] giữ nguyên repos.json hiện có"
fi

# ---- systemd units ----------------------------------------------------------
if [ "$NO_SYSTEMD" = 0 ] && command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  UNIT_DIR="$HOME/.config/systemd/user"
  mkdir -p "$UNIT_DIR"
  sed -e "s|@HOME@|$HOME|g" -e "s|@INSTALL_DIR@|$INSTALL_DIR|g" \
      "$PKG_DIR/systemd/pi-issue-runner.service.in" > "$UNIT_DIR/pi-issue-runner.service"
  sed -e "s|@HOME@|$HOME|g" -e "s|@INSTALL_DIR@|$INSTALL_DIR|g" \
      "$PKG_DIR/systemd/pi-issue-runner.timer.in" > "$UNIT_DIR/pi-issue-runner.timer"
  systemctl --user daemon-reload
  echo "  [+] đã cài systemd user units vào $UNIT_DIR"
  if [ "$ENABLE_TIMER" = 1 ]; then
    systemctl --user enable --now pi-issue-runner.timer
    echo "  [+] timer đã BẬT"
  else
    echo "  [i] timer chưa bật. Bật: systemctl --user enable --now pi-issue-runner.timer"
  fi
else
  echo "  [i] bỏ qua systemd; chạy tay: $INSTALL_DIR/runner.sh --once"
fi

# ---- labels -----------------------------------------------------------------
if [ "$SETUP_LABELS" = 1 ]; then
  echo; "$INSTALL_DIR/setup-repo.sh" || true
fi

echo
echo "== Xong =="
echo "Sửa danh sách dự án: $INSTALL_DIR/repos.json"
echo "Kiểm tra:            $INSTALL_DIR/runner.sh --dry-run"
echo "Tạo label repo:      $INSTALL_DIR/setup-repo.sh"
echo "Gỡ cài đặt:          $PKG_DIR/uninstall.sh"
