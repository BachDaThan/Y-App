# Chính sách quyền riêng tư của Yui

Phiên bản 2026-10. Cập nhật lần cuối: 31/10/2026. BẢN MẪU: cần được luật sư/chuyên gia bảo vệ dữ liệu rà soát trước khi phát hành chính thức.

## 1. Tóm tắt
- Yui chạy AI trên thiết bị của bạn. Lịch sử chat, model, ghi chú, tài liệu, skill và file bạn tạo nằm trên máy bạn.
- Nhà phát triển KHÔNG vận hành máy chủ thu thập dữ liệu của bạn, KHÔNG có quảng cáo và (ở phiên bản này) KHÔNG có công cụ phân tích/thống kê người dùng.
- Ứng dụng chỉ kết nối mạng khi cần một tính năng cụ thể (liệt kê ở mục 3).

## 2. Dữ liệu lưu trên thiết bị của bạn
- Lịch sử chat, cài đặt, danh sách model, model đã tải.
- Nếu bạn dùng kho tri thức: thư mục bạn chọn gồm chat/, notes/, kb/, skills/, files/, chỉ mục tìm kiếm, tiến độ tạm và nhật ký lỗi.
- Nhật ký lỗi chỉ ghi nơi xảy ra lỗi và thông điệp ngắn, KHÔNG ghi nội dung chat của bạn.
- Thư mục tiến độ tạm của các tác vụ nhiều bước được xoá khi tác vụ hoàn tất; chỉ giữ lại khi tác vụ lỗi/bị dừng để bạn có thể tiếp tục.
- Mã hoá tuỳ chọn: nếu bạn đặt mật khẩu/khoá, dữ liệu trong kho được mã hoá khi lưu. Khoá do bạn giữ; mất khoá thì không thể khôi phục dữ liệu đã mã hoá.
- Dữ liệu ở lại trên thiết bị cho đến khi bạn xoá hoặc gỡ ứng dụng. Bạn tự sao lưu nếu muốn giữ.

## 3. Dữ liệu gửi ra ngoài thiết bị (chỉ khi tính năng đó chạy)
- Kiểm tra/tải cập nhật: gửi yêu cầu tới GitHub (api.github.com, github.com). GitHub nhìn thấy địa chỉ IP và thông tin thiết bị cơ bản theo chính sách của GitHub.
- Tải model: tới địa chỉ bạn nhập (ví dụ Hugging Face). Nếu bạn nhập token, token chỉ được gửi kèm yêu cầu tải đó tới địa chỉ ấy.
- Công cụ tra cứu `search`: từ khoá tìm kiếm do model/bạn tạo được gửi tới Wikipedia (vi.wikipedia.org). Kèm theo là địa chỉ IP của bạn.
- Tính năng mở rộng (chỉ khi bạn cấu hình): từ khoá tìm kiếm gửi tới nhà cung cấp mà bạn đã nhập khoá (Tavily, Exa, Linkup, Firecrawl, Brave, Google), tới DuckDuckGo/Bing/Brave/Google (đọc trang kết quả bằng IP của bạn), tới SearXNG công cộng bạn liệt kê, và dữ liệu bạn gửi tới máy chủ MCP bạn kết nối. Các bên này có chính sách riêng.
- Nhà phát triển không nhận bản sao của những dữ liệu trên.
- Một số máy chủ nêu trên đặt ở nước ngoài, nên dữ liệu có thể được xử lý ngoài lãnh thổ Việt Nam.

## 4. Cơ sở và mục đích xử lý
Dữ liệu được xử lý trên máy bạn để Ứng dụng trả lời, tìm lại lịch sử, chạy công cụ và cập nhật. Việc gửi dữ liệu ra ngoài ở mục 3 diễn ra theo hành động hoặc cấu hình của bạn và dựa trên sự đồng ý của bạn.

## 5. Quyền của bạn
Vì dữ liệu nằm trên thiết bị của bạn, bạn có thể xem, sửa, xuất (chép thư mục), xoá hoặc ngừng dùng bất cứ lúc nào. Bạn có quyền rút lại đồng ý. Theo Nghị định 13/2023/NĐ-CP về bảo vệ dữ liệu cá nhân (và quy định tương đương như GDPR nếu bạn ở EU/EEA) bạn còn có các quyền yêu cầu truy cập, chỉnh sửa, xoá, hạn chế xử lý và khiếu nại. Với dữ liệu nhà phát triển không nắm giữ, hãy liên hệ bên thứ ba liên quan ở mục 3.

## 6. Trẻ em
Ứng dụng dành cho người từ đủ 16 tuổi. Người dưới 16 tuổi cần cha mẹ hoặc người giám hộ đồng ý. Nhà phát triển không cố ý thu thập dữ liệu của trẻ em.

## 7. Bảo mật
Công cụ chạy trong giới hạn an toàn (sandbox mini, thư mục riêng, chặn đường dẫn ra ngoài), và dữ liệu có thể mã hoá khi lưu. Không có hệ thống nào an toàn tuyệt đối; hãy giữ thiết bị, khoá và khoá API của bạn cẩn thận.

## 8. Thay đổi chính sách
Khi có thay đổi quan trọng, Ứng dụng sẽ hiện lại để bạn xem và đồng ý.

## 9. Liên hệ
[BachDaThan] · [tuongtieuthan@gmail.com] · [Việt Nam]
