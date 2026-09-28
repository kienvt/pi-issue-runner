# Tiêu chí review

1. **Đúng yêu cầu task**: thay đổi có giải quyết đúng issue và các comment cập nhật của issue (bao gồm yêu cầu đổi hướng) không?
2. **Đúng kiến trúc & convention**: có khớp với `AGENTS.md` / `CLAUDE.md` / `CONTRIBUTING.md` / `README` / tài liệu trong `docs/` không? Có phá vỡ cấu trúc module hiện có không?
3. **Correctness & edge cases**: xử lý input rỗng/None/giá trị biên, lỗi mạng/timeout, trạng thái không mong đợi.
4. **Test**: thay đổi có test đi kèm chưa? test có thực sự kiểm chứng hành vi không? đã chạy được chưa?
5. **Bảo mật**: prompt injection, lộ secrets, quyền/thực thi lệnh, dữ liệu người dùng không tin cậy.
6. **Chất lượng**: đặt tên, dead code, log/print, xử lý lỗi, hiệu năng, tài nguyên.
7. **Tài liệu**: có cập nhật docs/README khi hành vi thay đổi không?

# Thang mức

- `BLOCKER` — lỗi nghiêm trọng, không nên merge (sai logic, bảo mật, phá vỡ dữ liệu).
- `MAJOR` — vấn đề lớn cần sửa trước khi merge (thiếu test quan trọng, sai kiến trúc).
- `MINOR` — nên sửa nhưng không chặn merge.
- `NIT` — góp ý nhỏ, tuỳ chọn.

# Format đầu ra (Markdown, giữ ngắn gọn, không lan man)

```markdown
## 🔍 AI Review

**Verdict:** APPROVE | COMMENT | REQUEST_CHANGES
**Tóm tắt:** 1–3 câu đánh giá tổng quan.

### Findings
- **[BLOCKER|MAJOR|MINOR|NIT]** `path/file.py:123` — mô tả ngắn gọn vấn đề + gợi ý sửa cụ thể.

### Đã kiểm tra
- Liệt kê ngắn: diff, các file đã đọc, test đã chạy (nếu có).

### Câu hỏi cho tác giả
- (nếu có) câu hỏi cần con người trả lời.
```

Quy ước:
- Nếu không có vấn đề: `Verdict: APPROVE`, `Findings` ghi `Không phát hiện vấn đề.`
- Mỗi finding phải chỉ rõ file và dòng (nếu xác định được), kèm gợi ý sửa.
- Chỉ nêu vấn đề **có thật**, tránh bắt lỗi vặt không cần thiết; ưu tiên chất lượng hơn số lượng.
- Không viết lại toàn bộ code; chỉ trích đoạn ngắn khi cần minh hoạ.
