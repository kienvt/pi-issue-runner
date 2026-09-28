# Pi GitHub Issue Runner

Tự động theo dõi GitHub Issues của **nhiều dự án**, khi có task mới/ cập nhật thì
chạy [`pi`](https://pi.dev) để thực hiện, rồi mở Pull Request.

```
GitHub Issues ──(gh poll)──▶ runner.sh ──▶ pi (worktree riêng)
                                  │              │
                                  │◀── state ────┘
                                  ▼
                    branch ai/issue-<n> → push → PR → comment lại issue
```

## Yêu cầu
- `bash`, `git`, `jq`, `gh` (đã `gh auth login`), `flock`, `sha256sum`
- `pi` CLI (cài: `npm i -g @earendil-works/pi-coding-agent`, hoặc theo hướng dẫn pi.dev)
- (Tùy chọn) `systemd --user` để chạy nền tự động; nếu không có thì chạy tay / cron.

## Cài đặt

```bash
tar xzf pi-issue-runner.tar.gz
cd pi-issue-runner
./install.sh                # cài vào ~/.pi-issue-runner
# hoặc
./install.sh --enable       # cài + bật systemd timer luôn
./install.sh --setup-labels # tạo label ai/agent/ai-* trên các repo
./install.sh --prefix /opt/pi-issue-runner   # đổi thư mục cài
```

Sau khi cài:
1. Mở `~/.pi-issue-runner/repos.json`, thêm đường dẫn các repo local của bạn.
2. (Lần đầu) `~/.pi-issue-runner/setup-repo.sh` để tạo label.
3. Kiểm tra: `~/.pi-issue-runner/runner.sh --dry-run`.

## Cấu hình `repos.json`

```json
{
  "runner": {
    "poll_interval_sec": 120,
    "max_tasks_per_tick": 2,
    "pi_timeout_sec": 1800,
    "dry_run": false,
    "status_labels": { "running": "ai-running", "done": "ai-done", "failed": "ai-failed" }
  },
  "defaults": {
    "labels": ["ai", "agent"],
    "triggers": ["!ai", "!agent", "@ai", "@agent"],
    "trusted_authors": ["your-github-user"],
    "model": "opencode-go/deepseek-v4.1-flash",
    "base_branch": "main"
  },
  "repos": [
    { "name": "Finance", "path": "/home/me/workspace/Finance", "enabled": true },
    { "name": "ocr-api", "path": "/home/me/workspace/ocr-api", "enabled": true, "base_branch": "develop" }
  ]
}
```

Mỗi repo có thể override: `labels`, `triggers`, `trusted_authors`, `model`, `base_branch`.

## Cách kích hoạt

| Hành động | Cách làm |
|---|---|
| Task mới | Mở issue, gắn label `ai` **hoặc** `agent` |
| Cập nhật / hỏi thêm | Comment chứa `!ai`, `!agent`, `@ai`, `@agent` |
| Sửa yêu cầu trong issue | Sửa trực tiếp nội dung issue → tự phát hiện |
| Feedback trên Pull Request | Comment trên PR (hoặc review inline) → sửa tiếp nhánh đó |
| Dừng | Gỡ label `ai`/`agent`, hoặc đóng issue |

Chỉ comment của tài khoản trong `trusted_authors` mới được xử lý. Comment do runner
đăng có marker `<!-- pi-runner -->` nên bị bỏ qua → không lặp dù dùng chung tài khoản.

## Chọn agent (pi / omp / claude / codex / custom)

Mặc định dùng `pi`. Đổi ở `defaults.agent`, hoặc override theo từng repo:

```json
"defaults": { "agent": "omp" },
"repos": [
  { "name": "Finance", "path": "/path/Finance", "agent": "pi" },
  { "name": "Other",   "path": "/path/Other",   "agent": "claude" }
]
```

Preset có sẵn:

| agent | Cơ chế | Ghi chú |
|---|---|---|
| `pi` | `--print --approve --session-id <key>` | mặc định, đã test |
| `omp` | `--print --auto-approve --session-dir <dir>` + `--continue` | đã test, session liên tục |
| `claude` | `-p --output-format json --session-id <UUID>` | UUID sinh cố định từ session key; cần `claude` đã đăng nhập |
| `codex` | `codex exec --full-auto`, lưu session id để `resume` | cần cài `codex` |

Tùy biến hoàn toàn cho CLI khác:

```json
"defaults": {
  "agent": {
    "type": "custom",
    "command": "my-agent",
    "args": ["run", "--model", "{model}", "--session", "{session}", "{prompt}"]
  }
}
```
Placeholders: `{prompt}`, `{model}`, `{session}`, `{system_prompt}`.

## Session & bộ nhớ

Mỗi issue = một session cố định (`--session-id <Repo>-issue-<n>`). PR feedback dùng
cùng session đó, nên comment của bạn là **follow-up trong đúng luồng chat cũ**.
Session lưu ở `~/.pi/agent/sessions/`, không nằm trong worktree.

## Chạy tay & xem log

```bash
~/.pi-issue-runner/runner.sh --dry-run          # chỉ xem sẽ làm gì
~/.pi-issue-runner/runner.sh --once             # chạy thật 1 lượt
~/.pi-issue-runner/runner.sh --repo Finance     # giới hạn 1 repo
tail -f ~/.pi-issue-runner/logs/runner.log
```

## systemd

```bash
systemctl --user enable --now pi-issue-runner.timer
systemctl --user list-timers pi-issue-runner.timer
journalctl --user -u pi-issue-runner -f
```

## Gỡ cài đặt

```bash
./uninstall.sh          # tắt timer, xoá units (giữ dữ liệu)
./uninstall.sh --purge  # xoá luôn thư mục cài đặt
```

## An toàn
- Chỉ nhận lệnh từ `trusted_authors`.
- Agent chạy trong worktree riêng, chỉ tạo nhánh `ai/issue-<n>` + PR.
- Không bao giờ push thẳng `main`, không tự merge.
- Nội dung issue là input không đáng tin: system prompt cấm đọc secrets và cấm làm
  theo chỉ dẫn phá hoại nhúng trong issue.

> ⚠️ Mã nguồn nghiên cứu, không phải lời khuyên đầu tư.
