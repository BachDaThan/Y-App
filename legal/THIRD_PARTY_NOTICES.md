# Thông báo bên thứ ba / Third-party notices

Yui (mã nguồn MIT, xem LICENSE) dùng các thành phần sau. Danh sách đầy đủ, chính xác theo đúng phiên bản bạn cài được app tự tổng hợp và hiển thị tại **Cài đặt → Giấy phép mã nguồn mở** (Flutter `showLicensePage`); bảng dưới chỉ để tham khảo, hãy đối chiếu lại trên pub.dev khi nâng phiên bản.

| Thành phần | Dùng để | Giấy phép (theo pub.dev / dự án, cần xác nhận khi nâng phiên bản) |
|---|---|---|
| Flutter SDK + Dart | khung giao diện | BSD-3-Clause |
| ffi, path_provider, shared_preferences, url_launcher | gọi engine C++, thư mục, cài đặt, mở link | BSD-3-Clause |
| file_picker | chọn file model | MIT |
| flutter_foreground_task | chạy nền + nút Dừng | MIT |
| flutter_local_notifications | thông báo | BSD-3-Clause |
| open_filex | mở trình cài đặt | xem trang gói trên pub.dev |
| Engine C++ `native/yui.cpp` | suy luận model (.yui) | MIT (cùng repo) |

## Python (Adaptive-MoE: yui_agent, sandbox, RAG...)
Chỉ dùng thư viện chuẩn của Python (PSF License). Tuỳ chọn, người dùng tự cài: `curl_cffi` (MIT) để giả dấu vân tay TLS khi đọc DuckDuckGo/Brave/Bing; `pypdf` (BSD-3-Clause) để đọc PDF.

## Nội dung và phông chữ
- Wikipedia: văn bản CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0/). Ứng dụng hiển thị tên miền nguồn.
- Phông Poppins (dùng để vẽ chữ "Yui" trong ảnh logo tạo bởi tools/make_brand.py): SIL Open Font License 1.1.
- Logo/icon Yui do tác giả tự thiết kế bằng mã (tools/make_brand.py), thuộc cùng giấy phép MIT của dự án.

## Model AI
Model bạn nạp vào có giấy phép riêng của nơi phát hành; Yui không đóng gói hay cấp phép lại các model đó.

## Dịch vụ bên ngoài (tuỳ chọn)
GitHub, Hugging Face, Wikipedia, Tavily, Exa, Linkup, Firecrawl, Brave, Google, Bing, DuckDuckGo, SearXNG: mỗi bên có điều khoản riêng. Tên và nhãn hiệu thuộc chủ sở hữu tương ứng; Yui không liên kết hay được bảo trợ bởi họ.
