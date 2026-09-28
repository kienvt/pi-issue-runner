#!/usr/bin/env bash
# =============================================================================
# Installer for Pi GitHub Issue Runner
#
#   ./install.sh                 # cài vào ~/.pi-issue-runner
#   ./install.sh --enable        # cài + bật systemd timer luôn
#   ./install.sh --setup-labels  # tạo label trên các repo trong registry
#   ./install.sh --prefix /opt/pi-issue-runner
#   ./install.sh --no-systemd    # không đụng systemd
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
for c in bash git jq gh flock sha256sum curl; do
  if ! command -v "$c" >/dev/null 2>&1; then
    echo "  [!] thiếu: $c"; missing=1
  fi
done
# pi có thể nằm ngoài PATH
if ! command -v pi >/dev/null 2>&1; then
  found_pi=""
  for d in "$HOME/.local/bin" "$HOME/.bun/bin" $HOME/.local/share/pi-node/*/bin /usr/local/bin; do
    [ -x "$d/pi" ] && { found_pi="$d/pi"; break; }
  done
  if [ -n "$found_pi" ]; then
    echo "  [i] tìm thấy pi tại: $found_pi"
  else
    echo "  [!] thiếu: pi (cài từ https://pi.dev hoặc npm i -g @earendil-works/pi-coding-agent)"; missing=1
  fi
fi
if [ "$missing" = 1 ]; then
  echo; echo "Cài đủ dependency rồi chạy lại install.sh."; exit 1
fi

# ---- gh auth ----------------------------------------------------------------
if ! gh auth status >/dev/null 2>&1; then
  echo "  [!] chưa đăng nhập GitHub CLI. Chạy: gh auth login"; exit 1
fi
GH_USER="$(gh api user --jq .login 2>/dev/null || true)"
echo "  [i] GitHub user: ${GH_USER:-<không rõ>}"

# ---- copy files -------------------------------------------------------------
mkdir -p "$INSTALL_DIR"/state "$INSTALL_DIR"/logs "$INSTALL_DIR"/worktrees
cp -f "$PKG_DIR/runner.sh"        "$INSTALL_DIR/runner.sh"
cp -f "$PKG_DIR/setup-repo.sh"    "$INSTALL_DIR/setup-repo.sh"
cp -f "$PKG_DIR/system-prompt.md" "$INSTALL_DIR/system-prompt.md"
cp -f "$PKG_DIR/task-rules.md"    "$INSTALL_DIR/task-rules.md"
cp -f "$PKG_DIR/review-system-prompt.md" "$INSTALL_DIR/review-system-prompt.md"
cp -f "$PKG_DIR/review-rules.md"  "$INSTALL_DIR/review-rules.md"
cp -f "$PKG_DIR/README.md"        "$INSTALL_DIR/README.md"
chmod 755 "$INSTALL_DIR/runner.sh" "$INSTALL_DIR/setup-repo.sh"

# ---- env (GH_TOKEN) ---------------------------------------------------------
if [ ! -f "$INSTALL_DIR/env" ]; then
  umask 077
  printf 'GH_TOKEN=%q\n' "$(gh auth token)" > "$INSTALL_DIR/env"
  chmod 600 "$INSTALL_DIR/env"
  echo "  [+] đã tạo $INSTALL_DIR/env (chmod 600)"
else
  echo "  [i] giữ nguyên env hiện có"
fi

# ---- repos.json -------------------------------------------------------------
if [ ! -f "$INSTALL_DIR/repos.json" ]; then
  cp -f "$PKG_DIR/repos.json.example" "$INSTALL_DIR/repos.json"
  if [ -n "$GH_USER" ]; then
    tmp="$(mktemp)"
    jq --arg u "$GH_USER" '.defaults.trusted_authors = [$u]' "$INSTALL_DIR/repos.json" > "$tmp" \
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
