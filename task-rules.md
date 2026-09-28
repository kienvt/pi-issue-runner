## Quy tắc thực thi task này

- Bạn đang ở trong worktree của repo, trên nhánh `ai/issue-<n>`. Không đổi sang nhánh khác.
- Đọc `AGENTS.md` / `README.md` để biết cách build và test.
- Chỉ sửa file trong thư mục hiện tại. Không đọc secrets, không ra ngoài repo.
- KHÔNG tự chạy `git push`, `gh pr create`, `git checkout main`.
- Để nguyên thay đổi (chưa commit cũng được) — runner sẽ tự commit/push/tạo PR.
- KHÔNG viết các token kích hoạt (`!ai`, `@ai`, `!agent`, `@agent`) vào file hay commit.
- Nếu thiếu thông tin / cần con người quyết định: không đoán bừa, hãy nêu rõ câu hỏi.
- Kết thúc bằng tóm tắt: đã làm gì, file đổi, test đã chạy, cảnh báo (nếu có).
