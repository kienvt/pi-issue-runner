# Pi Issue Runner — bản GitLab (`glab`)

Tự động theo dõi **GitLab Issues** của nhiều dự án; khi có task mới/ cập nhật thì
chạy [`pi`](https://pi.dev) để thực hiện, rồi mở **Merge Request (MR)** và tự động
review MR đó.

> Đây là nhánh **`glab`** — ưu tiên GitLab. Nhánh **`main`** dành cho GitHub (`gh`).
> Mã ở cả hai nhánh dùng chung lớp `forge.sh` nên vẫn hỗ trợ cả GitHub lẫn GitLab;
> chọn backend tự động theo remote (hoặc ép bằng `"forge"` trong `repos.json`).

```
GitLab Issues ──(glab api poll)──▶ runner.sh ──▶ pi (worktree riêng)
                                      │                │
                                      │◀──── state ────┘
                                      ▼
                    nhánh ai/issue-<n> → push → MR → comment lại issue
                                      │
                                      ▼
                    agent review độc lập → comment review lên MR
```

## Yêu cầu

- `bash`, `git`, `jq`, `flock`, `sha256sum`, `curl`
- **`glab`** (GitLab CLI) đã `glab auth login` — hoặc `gh` nếu dùng GitHub
- `pi` CLI (cài: `npm i -g @earendil-works/pi-coding-agent`, hoặc theo hướng dẫn pi.dev)
- (Tùy chọn) `systemd --user` để chạy nền tự động

## Cài đặt

```bash
git clone -b glab https://github.com/kienvt/pi-issue-runner.git
cd pi-issue-runner
./install.sh                 # cài vào ~/.pi-issue-runner
./install.sh --enable        # cài + bật systemd timer
./install.sh --setup-labels  # tạo label ai/agent/ai-* trên các repo
```

Installer tự:
- kiểm tra dependency (`glab`/`gh`, `pi`, `jq`...),
- tạo `~/.pi-issue-runner/env` chứa `GITLAB_TOKEN` và/hoặc `GH_TOKEN` (chmod 600),
- tạo `repos.json` với `trusted_authors` = tài khoản GitLab/GitHub của bạn,
- cài systemd user units (nếu có).

Sau khi cài:
1. Mở `~/.pi-issue-runner/repos.json`, thêm đường dẫn các repo local.
2. `~/.pi-issue-runner/setup-repo.sh` để tạo label.
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
  "review": { "enabled": true, "agent": "pi", "model": "" },
  "defaults": {
    "agent": "pi",
    "forge": "auto",
    "labels": ["ai", "agent"],
    "triggers": ["!ai", "!agent", "@ai", "@agent"],
    "trusted_authors": ["your-gitlab-user"],
    "model": "opencode-go/deepseek-v4.1-flash",
    "base_branch": "main"
  },
  "repos": [
    { "name": "MyGitLabProj", "path": "/home/me/proj", "enabled": true }
  ]
}
```

Mỗi repo override được: `forge`, `labels`, `triggers`, `trusted_authors`, `agent`, `model`, `base_branch`.
Repo local phải là clone GitLab (remote `git@gitlab.com:group/proj.git` hoặc https).

## Cách kích hoạt

| Hành động | Cách làm |
|---|---|
| Task mới | Mở issue, gắn label `ai` **hoặc** `agent` |
| Cập nhật / hỏi thêm | Comment chứa `!ai`, `!agent`, `@ai`, hoặc `@agent` |
| Sửa yêu cầu trong issue | Sửa trực tiếp nội dung issue → tự phát hiện |
| Feedback trên Merge Request | Comment trên MR (kể cả review inline) → sửa tiếp nhánh đó |
| Dừng | Gỡ label `ai`/`agent`, hoặc đóng issue |

Chỉ comment của tài khoản trong `trusted_authors` mới được xử lý. Comment do runner
đăng có marker `<!-- pi-runner -->` nên bị bỏ qua → không lặp dù dùng chung tài khoản.

## GitLab — chi tiết

- Ánh xạ: Pull Request → **Merge Request**, `gh` → **`glab api`** (GitLab REST v4).
- `fullname` là `group/project` (hỗ trợ subgroup, tự URL-encode `%2F`).
- Review inline = MR `discussions` notes.
- **Self-hosted**: đặt `"forge": "gitlab"` cho repo và thêm `GITLAB_HOST=gitlab.example.com`
  vào `~/.pi-issue-runner/env` (cùng `GITLAB_TOKEN`).
- Mọi thao tác ghi (comment, label, tạo MR) dùng GitLab API v4 qua `glab api`.

## Chọn agent (pi / omp / claude / codex / custom)

Mặc định `pi`. Đổi ở `defaults.agent` hoặc override theo repo (`"agent": "claude"`).

| agent | Cơ chế |
|---|---|
| `pi` | `--print --approve --session-id <key>` |
| `omp` | `--print --auto-approve --session-dir <dir>` + `--continue` |
| `claude` | `-p --output-format json --session-id <UUID>` |
| `codex` | `codex exec --full-auto`, lưu session id để `resume` |

Tùy biến CLI khác:
```json
"agent": {
  "type": "custom",
  "command": "my-agent",
  "args": ["run", "--model", "{model}", "--session", "{session}", "{prompt}"]
}
```
Placeholders: `{prompt}`, `{model}`, `{session}`, `{system_prompt}`.

## Auto-review Merge Request

Sau khi agent đẩy/ cập nhật MR, runner tự chạy một agent **review độc lập** rồi đăng
comment review lên MR.

- Căn cứ: `review-rules.md` + `review-system-prompt.md`, rule & kiến trúc của repo
  (`AGENTS.md` / `CLAUDE.md` / `CONTRIBUTING.md` / `README` / `docs/`), và diff của MR.
- Bối cảnh: issue gốc + toàn bộ comment của issue.
- **Chỉ-đọc**: review agent bị giới hạn tool (pi: `--exclude-tools edit,write`; claude:
  bỏ `Edit`/`Write`; codex: `--sandbox read-only`); ngoài ra review chạy **sau** bước
  commit/push nên runner không bao giờ commit/push phần review.
- Kết quả: comment `## 🔍 AI Review` với `Verdict` + findings `BLOCKER/MAJOR/MINOR/NIT`.

Tắt: `"review": { "enabled": false }`.

## Session & bộ nhớ

Mỗi issue = một session cố định (`<Repo>-issue-<n>`); feedback trên MR dùng cùng
session đó nên comment của bạn là follow-up trong đúng luồng chat cũ. Session lưu ở
`~/.pi/agent/sessions/`, không nằm trong worktree.

## Chạy tay & log

```bash
~/.pi-issue-runner/runner.sh --dry-run          # chỉ xem sẽ làm gì
~/.pi-issue-runner/runner.sh --once             # chạy thật 1 lượt
~/.pi-issue-runner/runner.sh --repo MyGitLabProj
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
- Agent chạy trong worktree riêng, chỉ tạo nhánh `ai/issue-<n>` + MR.
- Không bao giờ push thẳng `main`, không tự merge.
- Nội dung issue là input không đáng tin: system prompt cấm đọc secrets và cấm làm
  theo chỉ dẫn phá hoại nhúng trong issue.
- Token (`GITLAB_TOKEN`/`GH_TOKEN`) nằm trong `env` (chmod 600), không commit.
