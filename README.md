# Yui App (Android .apk + Windows .exe)

App chat offline chạy bằng **engine C++ riêng** (`native/yui.cpp`, gọi qua Dart FFI). Có: chat streaming, tab **Lịch sử** (tìm, đổi tên, xoá), tab **Model** (nhập file `.yui`, tải từ link, đổi, xoá), **Cài đặt** (giao diện sáng/tối, tham số sinh chữ), kiểm tra cập nhật.

## Cách build (GitHub Actions, giống app Kính)
1. Tạo repo mới (vd `BachDaThan/Yui-App`), đẩy toàn bộ thư mục này lên nhánh `main`.
2. Mở `lib/state.dart`, sửa `kRepo` thành repo của bạn.
3. **Tạo khoá ký Android (làm MỘT lần, giữ file `.jks` thật kỹ, mất là không cài đè được nữa):**
   ```
   keytool -genkeypair -v -keystore yui-release.jks -alias yui -keyalg RSA -keysize 2048 -validity 36500
   base64 -w0 yui-release.jks      # (macOS: base64 -i yui-release.jks)
   ```
   Vào repo → Settings → Secrets and variables → Actions, tạo 4 secret:
   `ANDROID_KEYSTORE_BASE64` (chuỗi base64 ở trên), `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` (= `yui`), `ANDROID_KEY_PASSWORD` (đặt trùng mật khẩu keystore cho đơn giản).
4. Push lên `main` → Actions tự build, rồi đăng lên **Releases → tag `latest`**: `Yui-android-arm64.apk`, `Yui-windows-setup.exe`, `Yui-windows-portable.zip`.

## Cài đè (update)
- **Android:** cùng khoá ký + `versionCode` tăng dần (workflow dùng số lần chạy) → bản mới cài đè lên bản cũ, giữ nguyên model và lịch sử. Không có khoá riêng thì mỗi lần build ký bằng khoá debug ngẫu nhiên và KHÔNG cài đè được.
- **Windows:** `Yui-Setup.exe` có `AppId` cố định nên cài đè bản cũ. Windows SmartScreen sẽ cảnh báo vì chưa có chứng chỉ ký mã (trả phí): bấm "More info → Run anyway".
- App tự hỏi GitHub Releases mỗi 12 giờ; nếu có bản mới sẽ hiện thông báo kèm nút mở trang tải. Không tự cài ngầm (hệ điều hành cũng không cho).

## Dùng model
Xuất model bằng `export_yui.py` (xem repo Adaptive-MoE) ra file `.yui`, rồi trong app: tab **Model → Nhập file .yui** (hoặc đám mây để tải từ link Hugging Face, repo private thì dán token). Model lưu trong thư mục dữ liệu riêng của app.

## Cấu trúc
- `native/yui.cpp` engine C++ (cùng file với bản dòng lệnh; biên dịch thành `libyui.so` / `yui.dll` với `-DYUI_LIB`)
- `lib/engine.dart` FFI + isolate nền · `lib/state.dart` trạng thái, model, lịch sử, cập nhật · `lib/screens/*` giao diện
- `.github/workflows/build-app.yml`, `installer/yui.iss`

## Hiệu năng (engine v1.1)
- Kernel int8×int8 SIMD chọn lúc chạy (AVX2+FMA trên PC, NEON hoặc NEON+dotprod trên điện thoại ARM64), kích hoạt lượng tử theo khối 32 như llama.cpp. File `.yui` cũ dùng được luôn, KHÔNG cần xuất lại.
- Nhóm luồng riêng (không cần OpenMP): lớp head và các expert chạy song song. Cài đặt → **Số luồng CPU** (0 = tự chọn; điện thoại mặc định tối đa 4 luồng vì lõi nhỏ thường làm chậm).
- Model nạp bằng `mmap` trên Android: mở gần như tức thì và không nhân đôi RAM. Windows mặc định đọc vào RAM (để còn đổi tên/xoá file model được).
- Không có `-march=native`/`/arch:AVX2` trong workflow nữa nên một bản cài chạy được trên mọi máy cùng kiến trúc.

- Hỗ trợ file `.yui` v2 (4-bit, `export_yui.py --quant q4`): nhỏ hơn, nhanh hơn trên điện thoại; tab Model nhập như file thường.

## Lưu ý
Code Dart và workflow CHƯA được build thử (người viết không có Flutter SDK); engine C++ đã kiểm tra riêng. Nếu Actions báo lỗi, dán log để sửa.
