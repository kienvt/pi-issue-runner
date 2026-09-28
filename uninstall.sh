#!/usr/bin/env bash
# =============================================================================
# Gỡ Pi Issue Runner
#   ./uninstall.sh            # tắt timer + xoá systemd units (giữ dữ liệu)
#   ./uninstall.sh --purge    # xoá luôn thư mục cài đặt
# =============================================================================
set -uo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/.pi-issue-runner}"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user disable --now pi-issue-runner.timer >/dev/null 2>&1 || true
  rm -f "$HOME/.config/systemd/user/pi-issue-runner.timer" \
        "$HOME/.config/systemd/user/pi-issue-runner.service"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  echo "[-] đã gỡ systemd units"
fi

if [ "$PURGE" = 1 ]; then
  rm -rf "$INSTALL_DIR"
  echo "[-] đã xoá $INSTALL_DIR"
else
  echo "[i] giữ lại $INSTALL_DIR (dùng --purge để xoá)"
fi
echo "Xong."
