# Danh sách việc pháp lý cần làm trước khi phát hành Yui

Tôi (người soạn) KHÔNG phải luật sư; các văn bản trong `assets/legal/` là BẢN MẪU viết theo đúng cách app hoạt động. Hãy để luật sư/chuyên gia bảo vệ dữ liệu rà soát.

## Phải điền
- [ ] Thay mọi `[TÊN CHỦ SỞ HỮU]`, `[EMAIL LIÊN HỆ]`, `[ĐỊA CHỈ]` trong assets/legal/*.md.
- [ ] Đăng chính sách quyền riêng tư ở một **URL công khai** (GitHub Pages cũng được) — Google Play/App Store yêu cầu.
- [ ] Mỗi khi đổi nội dung quan trọng: tăng `kLegalVersion` trong lib/widgets/legal_gate.dart để app hỏi đồng ý lại.
- [ ] Nếu thêm analytics/báo lỗi/quảng cáo/đăng nhập: sửa Chính sách (mục 1 và 3) TRƯỚC khi phát hành, vì hiện văn bản khẳng định không có.

## Nếu phát hành trên Google Play
- [ ] **Tự cập nhật bằng APK (quyền REQUEST_INSTALL_PACKAGES, tải .apk từ GitHub) bị Google Play cấm** cho app phát hành trên Play. Bản Play phải TẮT tính năng "Tải ngầm" (bỏ quyền và nút) và để Play cập nhật. Chỉ giữ cho bản phát hành trực tiếp qua GitHub.
- [ ] Dịch vụ nền loại `dataSync` phải khai báo trong Play Console (mục đích, mô tả; có thể cần video minh hoạ).
- [ ] Điền mẫu **Data safety**: không thu thập dữ liệu về máy chủ của nhà phát triển; có dữ liệu gửi tới bên thứ ba khi người dùng chủ động bật (Wikipedia, GitHub, nhà cung cấp tìm kiếm); dữ liệu có thể mã hoá khi lưu; người dùng tự xoá bằng cách xoá thư mục/gỡ app.
- [ ] Xếp hạng độ tuổi: nội dung do AI sinh ra là nội dung người dùng tạo — xem chính sách "AI-generated content" của Google Play (cần cách báo cáo nội dung xấu; nếu app chỉ chạy model cục bộ do người dùng tự nạp, cần giải thích rõ trong hồ sơ).

## Việt Nam (nếu bạn là người/tổ chức ở Việt Nam hoặc phục vụ người dùng Việt Nam)
- [ ] Nghị định 13/2023/NĐ-CP về bảo vệ dữ liệu cá nhân: xem có phải lập hồ sơ đánh giá tác động xử lý dữ liệu cá nhân hay thông báo cơ quan chức năng không. Phần lớn xử lý của Yui diễn ra trên thiết bị người dùng nên rủi ro thấp, nhưng cần luật sư xác nhận.
- [ ] Quy định về trẻ em: văn bản đặt ngưỡng 16 tuổi + đồng ý của cha mẹ; xác nhận với luật sư.

## EU / nơi khác
- [ ] Nếu có người dùng ở EU: GDPR (Yui không thu thập về máy chủ nên nhẹ, nhưng vẫn cần chính sách rõ ràng và đại diện/DPO nếu luật yêu cầu). Quy định AI của EU (AI Act): đánh giá xem ứng dụng thuộc nhóm nghĩa vụ nào, nhất là minh bạch với nội dung AI.

## Tên, logo, nội dung
- [ ] Tra cứu nhãn hiệu cho tên "Yui" (tên thông dụng, có thể đã có người đăng ký trong nhóm phần mềm) trước khi dùng thương mại; cân nhắc đăng ký nhãn hiệu.
- [ ] Logo/icon: do bạn tự thiết kế (tools/make_brand.py); nếu thuê/nhờ người khác chỉnh thì lấy văn bản chuyển giao bản quyền.
- [ ] Wikipedia: giữ ghi công nguồn (CC BY-SA 4.0).
- [ ] Model AI: kiểm tra giấy phép từng model trước khi phân phối chung với app; Yui không đóng gói model.

## Tính năng cần cân nhắc rủi ro điều khoản của bên thứ ba
- [ ] Đọc HTML Google/Bing/Brave/DuckDuckGo không key: trái điều khoản của họ (đã để Google TẮT mặc định, có giữ nhịp). Khi phát hành rộng rãi nên mặc định chỉ dùng API chính thức/SearXNG/Wikipedia và để các tầng này là tuỳ chọn người dùng tự bật.
