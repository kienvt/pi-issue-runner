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

## GitLab (dùng `glab`)

Runner hỗ trợ GitLab qua lớp `forge.sh`. Chỉ cần:

1. Cài `glab` và đăng nhập: `glab auth login` (self-hosted: `glab auth login --hostname gitlab.example.com`).
2. Trong `repos.json` để `"forge": "auto"` (tự nhận theo remote) hoặc ép `"forge": "gitlab"`.
3. `GITLAB_TOKEN` được installer ghi vào `env`; self-hosted đặt thêm `GITLAB_HOST=gitlab.example.com` trong `env`.

Ánh xạ khái niệm:

| GitHub | GitLab |
|---|---|
| Issue + label | Issue + label |
| Pull Request (PR) | Merge Request (MR) |
| `gh` | `glab api` (REST v4) |
| Review inline | MR discussion notes |

Chi tiết:
- Repo local phải là clone GitLab (remote `git@gitlab.com:group/proj.git` hoặc https).
- `fullname` là `group/project` (hỗ trợ subgroup, tự URL-encode `%2F`).
- Trigger giống GitHub: label `ai`/`agent`, comment `!ai`/`@agent`..., sửa body issue, comment trên MR.
- Mọi thao tác ghi dùng GitLab API v4 qua `glab api`.

> Lưu ý: phần GitLab viết theo GitLab API v4 + glab 1.x, đã kiểm tra cú pháp CLI nhưng **chưa test end-to-end trên GitLab thật** (máy build chưa có token GitLab). Cần thử với 1 repo nhỏ trước.

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

## Auto-review Pull Request

Sau khi agent đẩy/ cập nhật PR, runner tự chạy một agent **review độc lập** trên chính
PR đó và đăng comment review lên PR.

- **Căn cứ review**: `review-rules.md` + `review-system-prompt.md`, rule & kiến trúc
  của repo (`AGENTS.md` / `CLAUDE.md` / `CONTRIBUTING.md` / `README` / `docs/`), và diff của PR.
- **Bối cảnh**: issue gốc + toàn bộ comment của issue (bỏ comment do runner đăng).
- **Không sửa file**, không commit/push; chỉ đọc và nhận xét.
- **Chỉ-đọc (defense-in-depth)**: review agent bị giới hạn tool — `pi`: `--exclude-tools edit,write`;
  `omp`: allowlist `read,grep,find,ls,bash`; `claude`: bỏ `Edit`/`Write`; `codex`: `--sandbox read-only`.
  Ngoài ra review chạy **sau** bước commit/push nên runner không bao giờ commit/push phần review;
  worktree bị xoá ngay sau đó → mọi thay đổi (nếu có) đều bị bỏ.
- **Kết quả**: comment `## 🔍 AI Review` với `Verdict` (APPROVE / COMMENT / REQUEST_CHANGES)
  và findings theo mức `BLOCKER` / `MAJOR` / `MINOR` / `NIT`.

Cấu hình trong `repos.json`:

```json
"review": { "enabled": true, "agent": "pi", "model": "" }
```
Để trống `agent`/`model` thì dùng mặc định chung. Đặt `"enabled": false` để tắt.

> Review chạy sau cả khi tạo PR mới và khi cập nhật PR theo feedback, nên mỗi lần
> code đổi đều có review tương ứng. Comment review có marker `<!-- pi-runner -->`
> nên không tự kích hoạt vòng lặp.

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
