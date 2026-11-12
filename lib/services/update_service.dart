// update_service.dart - CẬP NHẬT NGẦM: bấm "Tải ngầm" thì file cài (APK / trình cài Windows) tải ở nền với thanh tiến độ, tải tiếp được nếu đứt giữa chừng (HTTP Range),
// thoát app ra màn hình chính vẫn tải (BackgroundGuard), chỉ báo "Đã tải xong, bấm để cài" khi file đã tải trọn vẹn và kiểm tra hợp lệ. Có nút Huỷ.
// An toàn: chỉ tải từ https://github.com/... (release của kho Y-App), kiểm tra kích thước khớp + APK đúng định dạng zip ("PK"); Android tự từ chối cài nếu khoá ký khác bản đang cài.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import 'background_guard.dart';
import 'notifier.dart';

class UpdateAsset {
  final String name, url;
  final int size;
  const UpdateAsset(this.name, this.url, this.size);
}

enum UpdateState { idle, downloading, ready, failed, cancelled }

class UpdateService extends ChangeNotifier {
  UpdateState state = UpdateState.idle;
  double progress = 0; // 0..1
  String message = '';
  File? file;
  bool _cancel = false;

  bool get busy => state == UpdateState.downloading;

  /// Chọn file cài đúng nền tảng trong danh sách assets của GitHub Release.
  static UpdateAsset? pickAsset(List<dynamic> assets) {
    UpdateAsset? best;
    for (final a in assets) {
      if (a is! Map) continue;
      final name = '${a['name'] ?? ''}';
      final url = '${a['browser_download_url'] ?? ''}';
      final size = (a['size'] as num?)?.toInt() ?? 0;
      final low = name.toLowerCase();
      final ok = Platform.isAndroid ? low.endsWith('.apk') : Platform.isWindows ? low.endsWith('setup.exe') : false;
      if (ok && url.startsWith('https://github.com/')) best ??= UpdateAsset(name, url, size);
    }
    return best;
  }

  void cancel() {
    if (!busy) return;
    _cancel = true;
  }

  Future<void> start(String url, String name, int expectedSize) async {
    if (busy) return;
    if (!url.startsWith('https://github.com/')) {
      _fail('Địa chỉ tải không hợp lệ');
      return;
    }
    _cancel = false;
    state = UpdateState.downloading;
    progress = 0;
    message = 'Đang tải $name…';
    notifyListeners();
    BackgroundGuard.addStopHandler(cancel);
    await BackgroundGuard.begin('Yui đang tải bản cập nhật', 'Bắt đầu…');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    IOSink? sink;
    try {
      final dir = Directory('${(await getApplicationSupportDirectory()).path}/updates');
      await dir.create(recursive: true);
      final out = File('${dir.path}/$name');
      final part = File('${out.path}.part');
      var have = await part.exists() ? await part.length() : 0;
      if (expectedSize > 0 && have > expectedSize) {
        await part.delete();
        have = 0;
      }
      final req = await client.getUrl(Uri.parse(url));
      req.followRedirects = true;
      req.maxRedirects = 5;
      if (have > 0) req.headers.set('Range', 'bytes=$have-');
      final res = await req.close();
      if (res.statusCode != 200 && res.statusCode != 206) throw HttpException('HTTP ${res.statusCode}');
      if (res.statusCode == 200) have = 0; // máy chủ không hỗ trợ Range: tải lại từ đầu
      final total = expectedSize > 0 ? expectedSize : (res.contentLength > 0 ? res.contentLength + have : 0);
      sink = part.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
      var got = have, lastPct = -1;
      await for (final chunk in res) {
        if (_cancel) throw const _Cancelled();
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) {
          progress = got / total;
          final pct = (progress * 100).floor();
          if (pct != lastPct) {
            lastPct = pct;
            notifyListeners();
            if (pct % 2 == 0) BackgroundGuard.update('$pct% · ${(got / 1048576).toStringAsFixed(1)} / ${(total / 1048576).toStringAsFixed(1)} MB');
          }
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (expectedSize > 0 && got != expectedSize) throw HttpException('Tải thiếu ($got/$expectedSize byte), sẽ tiếp tục lần sau');
      if (name.toLowerCase().endsWith('.apk')) {
        final head = await part.openRead(0, 2).first;
        if (head.length < 2 || head[0] != 0x50 || head[1] != 0x4B) throw const HttpException('File tải về không phải APK hợp lệ');
      }
      if (await out.exists()) await out.delete();
      await part.rename(out.path);
      file = out;
      state = UpdateState.ready;
      progress = 1;
      message = 'Đã tải xong. Bấm để cài đặt.';
      notifyListeners();
      await Notifier.show(7002, 'Yui: đã tải xong bản cập nhật', 'Bấm vào Cài đặt trong app để cài đè, dữ liệu và model được giữ nguyên.');
    } on _Cancelled {
      state = UpdateState.cancelled;
      message = 'Đã dừng tải (phần đã tải được giữ để tải tiếp).';
      notifyListeners();
    } catch (e) {
      _fail('Tải lỗi: $e. Bạn có thể bấm tải lại, phần đã tải được giữ.');
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client.close(force: true);
      await BackgroundGuard.end();
    }
  }

  /// Ẩn thanh tiến độ sau khi lỗi/huỷ.
  void dismiss() {
    if (busy) return;
    state = UpdateState.idle;
    notifyListeners();
  }

  void _fail(String m) {
    state = UpdateState.failed;
    message = m;
    notifyListeners();
  }

  /// Mở trình cài đặt của hệ điều hành cho file đã tải.
  Future<void> install() async {
    final f = file;
    if (f == null || state != UpdateState.ready) return;
    final r = await OpenFilex.open(f.path, type: Platform.isAndroid ? 'application/vnd.android.package-archive' : null);
    if (r.type != ResultType.done) {
      message = 'Không mở được trình cài đặt: ${r.message}. Hãy cho phép "Cài app không rõ nguồn" cho Yui trong Cài đặt máy.';
      notifyListeners();
    }
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

final UpdateService updater = UpdateService();
