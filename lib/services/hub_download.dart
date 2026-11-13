// hub_download.dart - tải một model từ Kho (P2-4): tiếp tục khi đứt mạng (HTTP Range), kiểm sha256 + dung lượng + cấu hình, trần dung lượng.
// Dart thuần (dart:io/convert/async + yui_header.dart), không phụ thuộc Flutter: chạy thử được bằng `dart tools/hub_download_check.dart`.
//
// Nguyên tắc an toàn:
//  - Chỉ https (kể cả sau chuyển hướng; xử lý chuyển hướng bằng tay tối đa 5 lần). Token (nếu có) chỉ gửi tới ĐÚNG máy chủ của link gốc, không gửi sang CDN.
//  - File tải dở nằm ở "hub_<16 ký tự đầu sha256>.part": gắn với đúng bản model trong manifest nên bản mới (sha khác) không bao giờ nối nhầm vào file dở cũ.
//  - Chỉ đổi tên thành .yui sau khi: đủ số byte đã khai báo, sha256 khớp, header đọc được, cấu hình trong file khớp arch_id/ctx của manifest.
//  - Hỏng vì mạng (đứt, 429, 5xx) -> GIỮ file dở để tải tiếp. Hỏng vì nội dung (sai sha256, nhiều byte hơn khai báo, sai cấu hình) -> XOÁ file dở.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../yui_header.dart';
import 'hub_service.dart';

const int kHubDlMaxAttempts = 4; // số lần thử (mỗi lần sau đều tiếp tục từ chỗ dở)
const int kHubMaxRedirects = 5;
const Duration kHubStallTimeout = Duration(seconds: 30); // không nhận thêm byte nào trong 30 giây thì coi là đứt

// ============================ SHA-256 (thuần Dart, tính dần theo từng khối) ============================
class Sha256 {
  static const List<int> _k = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
  ];
  final List<int> _h = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
  final Uint8List _buf = Uint8List(64);
  final Uint32List _w = Uint32List(64);
  int _bufLen = 0;
  int _total = 0;
  bool _closed = false;

  static int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;

  void _block(Uint8List d, int o) {
    final w = _w;
    for (var i = 0; i < 16; i++) {
      final j = o + i * 4;
      w[i] = (d[j] << 24) | (d[j + 1] << 16) | (d[j + 2] << 8) | d[j + 3];
    }
    for (var i = 16; i < 64; i++) {
      final a = w[i - 15], b = w[i - 2];
      final s0 = _rotr(a, 7) ^ _rotr(a, 18) ^ (a >> 3);
      final s1 = _rotr(b, 17) ^ _rotr(b, 19) ^ (b >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
    }
    var a = _h[0], b = _h[1], c = _h[2], d0 = _h[3], e = _h[4], f = _h[5], g = _h[6], h = _h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xffffffff) & g);
      final t1 = (h + s1 + ch + _k[i] + w[i]) & 0xffffffff;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xffffffff;
      h = g;
      g = f;
      f = e;
      e = (d0 + t1) & 0xffffffff;
      d0 = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xffffffff;
    }
    _h[0] = (_h[0] + a) & 0xffffffff;
    _h[1] = (_h[1] + b) & 0xffffffff;
    _h[2] = (_h[2] + c) & 0xffffffff;
    _h[3] = (_h[3] + d0) & 0xffffffff;
    _h[4] = (_h[4] + e) & 0xffffffff;
    _h[5] = (_h[5] + f) & 0xffffffff;
    _h[6] = (_h[6] + g) & 0xffffffff;
    _h[7] = (_h[7] + h) & 0xffffffff;
  }

  void add(List<int> data) {
    if (_closed) throw StateError('Sha256 đã đóng');
    final d = data is Uint8List ? data : Uint8List.fromList(data);
    _total += d.length;
    var i = 0;
    if (_bufLen > 0) {
      while (i < d.length && _bufLen < 64) {
        _buf[_bufLen++] = d[i++];
      }
      if (_bufLen < 64) return;
      _block(_buf, 0);
      _bufLen = 0;
    }
    while (i + 64 <= d.length) {
      _block(d, i);
      i += 64;
    }
    while (i < d.length) {
      _buf[_bufLen++] = d[i++];
    }
  }

  /// Kết thúc và trả về chuỗi hex 64 ký tự (chữ thường). Chỉ gọi một lần.
  String close() {
    if (_closed) throw StateError('Sha256 đã đóng');
    _closed = true;
    final bits = _total * 8;
    _buf[_bufLen++] = 0x80;
    if (_bufLen > 56) {
      while (_bufLen < 64) {
        _buf[_bufLen++] = 0;
      }
      _block(_buf, 0);
      _bufLen = 0;
    }
    while (_bufLen < 56) {
      _buf[_bufLen++] = 0;
    }
    for (var i = 7; i >= 0; i--) {
      _buf[_bufLen++] = (bits >> (i * 8)) & 0xff;
    }
    _block(_buf, 0);
    final sb = StringBuffer();
    for (final v in _h) {
      sb.write(v.toRadixString(16).padLeft(8, '0'));
    }
    return sb.toString();
  }
}

/// sha256 hex của một file (đọc dần, không nạp cả file vào RAM).
Future<String> sha256OfFile(File f) async {
  final h = Sha256();
  await for (final c in f.openRead()) {
    h.add(c);
  }
  return h.close();
}

// ============================ lỗi & huỷ ============================
class HubDownloadException implements Exception {
  final String message;
  const HubDownloadException(this.message);
  @override
  String toString() => message;
}

/// Người dùng bấm dừng. File dở được GIỮ để tải tiếp lần sau.
class HubCancelled implements Exception {
  const HubCancelled();
  @override
  String toString() => 'Đã dừng tải. Có thể tải tiếp sau (phần đã tải được giữ lại).';
}

class HubCancel {
  bool cancelled = false;
  void cancel() => cancelled = true;
}

// ============================ kiểm cấu hình ============================
final RegExp _reArch = RegExp(r'^amoe-d(\d+)-l(\d+)-h(\d+)-e(\d+)-s(\d+)-f(\d+)$');

/// Tách arch_id kiểu "amoe-d64-l2-h4-e4-s0-f128"; null nếu không đúng dạng.
({int d, int l, int h, int e})? parseArchId(String s) {
  final m = _reArch.firstMatch(s);
  if (m == null) return null;
  return (d: int.parse(m[1]!), l: int.parse(m[2]!), h: int.parse(m[3]!), e: int.parse(m[4]!));
}

/// null nếu cấu hình thật trong file khớp mục manifest; ngược lại là lý do (tiếng Việt).
String? checkHeaderAgainstManifest(HubModel m, YuiHeader h) {
  if (h.ver != m.yuiVer) return 'phiên bản .yui trong file (${h.ver}) khác manifest (${m.yuiVer})';
  if (h.ctx != m.ctx) return 'độ dài ngữ cảnh trong file (${h.ctx}) khác manifest (${m.ctx})';
  final a = parseArchId(m.archId);
  if (a == null) return 'arch_id "${m.archId}" của manifest không đúng dạng amoe-d…-l…-h…-e…-s…-f…';
  if (h.d != a.d || h.layers != a.l || h.heads != a.h || h.experts != a.e) {
    return 'cấu hình trong file (d${h.d} l${h.layers} h${h.heads} e${h.experts}) không khớp arch_id của manifest (${m.archId})';
  }
  final metaArch = h.meta?['arch_id'];
  if (h.hasMeta && metaArch != m.archId) return 'arch_id trong META của file ($metaArch) khác manifest (${m.archId})';
  return null;
}

/// Tên file .yui an toàn để lưu (lấy từ đường dẫn trong manifest). ModelStore tự thêm hậu tố _2, _3… nếu trùng.
String hubFileName(HubModel m) {
  var n = m.file.split('/').last.replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_').trim();
  if (n.isEmpty || n.startsWith('.')) n = 'model_${m.id}';
  if (!n.toLowerCase().endsWith('.yui')) n = '$n.yui';
  return n;
}

// ============================ tải ============================
class _Run {
  Sha256 h = Sha256();
  int done = 0;
  bool hashed = false; // đã băm xong phần có sẵn trong file dở chưa
}

class _Restart implements Exception {
  const _Restart();
}

class _Short implements Exception {
  const _Short();
}

bool _isRetryable(Object e) =>
    e is _Short ||
    (e is HubHttpException && e.retryable) ||
    e is TimeoutException ||
    e is SocketException ||
    e is HandshakeException ||
    e is HttpException;

/// Mở kết nối, tự đi theo chuyển hướng (chỉ https, ≤ 5 lần), gửi Range nếu start > 0.
Future<HttpClientResponse> _open(HttpClient client, Uri first, int start, String? token, bool allowInsecure) async {
  var cur = first;
  for (var hop = 0; hop <= kHubMaxRedirects; hop++) {
    if (!allowInsecure && cur.scheme != 'https') throw const HubDownloadException('Link tải không phải https, đã chặn');
    final req = await client.getUrl(cur).timeout(const Duration(seconds: 20));
    req.followRedirects = false;
    if (start > 0) req.headers.set('Range', 'bytes=$start-');
    if (token != null && token.trim().isNotEmpty && cur.host == first.host) {
      req.headers.set('Authorization', 'Bearer ${token.trim()}');
    }
    final res = await req.close().timeout(const Duration(seconds: 30));
    final st = res.statusCode;
    if (st == 301 || st == 302 || st == 303 || st == 307 || st == 308) {
      final loc = res.headers.value('location');
      await res.drain<void>();
      if (loc == null) throw const HubDownloadException('Máy chủ chuyển hướng nhưng không cho biết nơi đến');
      cur = cur.resolveUri(Uri.parse(loc));
      continue;
    }
    return res;
  }
  throw const HubDownloadException('Chuyển hướng quá nhiều lần');
}

/// Tải model [m] vào [dir] với tên [destName]. Trả về file .yui đã kiểm xong.
/// [maxBytes]: trần dung lượng cho một model (mặc định và tối đa [kHubMaxModelBytes]); vượt thì từ chối TRƯỚC khi tải.
/// Ném [HubDownloadException] (lỗi nội dung/điều kiện), [HubCancelled], hoặc lỗi mạng đã hết lần thử (file dở được giữ).
Future<File> hubDownload(
  HubModel m, {
  required Directory dir,
  required String destName,
  String? token,
  int? maxBytes,
  HubCancel? cancel,
  void Function(int done, int total)? onProgress,
  bool allowInsecure = false, // CHỈ cho test với máy chủ cục bộ
  Future<void> Function(Duration)? sleep,
}) async {
  final cap = (maxBytes != null && maxBytes < kHubMaxModelBytes) ? maxBytes : kHubMaxModelBytes;
  if (m.bytes <= 0 || m.bytes > cap) {
    throw HubDownloadException('Model ${m.sizeText} vượt trần dung lượng cho phép (${(cap / 1e6).toStringAsFixed(0)} MB)');
  }
  final uri = Uri.tryParse(m.url);
  if (uri == null || uri.host.isEmpty || (!allowInsecure && uri.scheme != 'https')) {
    throw const HubDownloadException('Link tải không hợp lệ (cần https)');
  }
  if (m.sha256.length != 64) throw const HubDownloadException('Manifest thiếu sha256 hợp lệ');
  await dir.create(recursive: true);
  final dest = File('${dir.path}${Platform.pathSeparator}$destName');
  if (await dest.exists()) throw HubDownloadException('Đã có file $destName');
  final part = File('${dir.path}${Platform.pathSeparator}hub_${m.sha256.substring(0, 16)}.part');
  final wait = sleep ?? ((d) => Future<void>.delayed(d));
  final run = _Run();
  final clock = Stopwatch()..start();
  var lastTick = -1000;
  void tick(bool force) {
    if (onProgress == null) return;
    if (force || clock.elapsedMilliseconds - lastTick >= 150) {
      lastTick = clock.elapsedMilliseconds;
      onProgress(run.done, m.bytes);
    }
  }

  Future<void> dropPart() async {
    try {
      if (await part.exists()) await part.delete();
    } catch (_) {}
  }

  var restarts = 0;
  for (var attempt = 1;; attempt++) {
    if (cancel?.cancelled == true) throw const HubCancelled();
    try {
      await _attempt(m, uri, part, run, token, allowInsecure, cancel, tick);
      break;
    } on _Restart {
      // máy chủ không cho tiếp tục đúng chỗ (416 / bỏ qua Range): bỏ phần dở và tải lại từ đầu, tối đa 2 lần
      if (++restarts > 2) throw const HubDownloadException('Máy chủ không cho tải tiếp và tải lại từ đầu cũng lỗi');
      await dropPart();
      run
        ..h = Sha256()
        ..done = 0
        ..hashed = true;
      attempt--; // lần khởi động lại không tính vào số lần thử mạng
    } on HubCancelled {
      rethrow;
    } on _IntegrityFailure catch (e) {
      await dropPart();
      throw HubDownloadException(e.message);
    } on FileSystemException {
      throw const HubDownloadException('Không ghi được file tải về (hết dung lượng bộ nhớ?). Phần đã tải được giữ lại');
    } catch (e) {
      if (e is HubDownloadException || !_isRetryable(e) || attempt >= kHubDlMaxAttempts) {
        if (e is HubHttpException) {
          throw HubDownloadException('${describeHubError(e)}. Phần đã tải được giữ lại, bấm tải lại để tiếp tục');
        }
        if (e is HubDownloadException) rethrow;
        throw HubDownloadException('${describeHubError(e)}. Phần đã tải được giữ lại, bấm tải lại để tiếp tục');
      }
      var d = Duration(seconds: 1 << (attempt - 1));
      if (e is HubHttpException && e.retryAfter != null) d = e.retryAfter!;
      await wait(d);
    }
  }
  tick(true);
  if (run.done != m.bytes) {
    await dropPart();
    throw const HubDownloadException('Số byte tải về không đúng khai báo');
  }
  final got = run.h.close();
  if (got != m.sha256) {
    await dropPart();
    throw const HubDownloadException('File tải về sai sha256 (hỏng hoặc bị thay đổi), đã xoá. Thử tải lại; nếu vẫn lỗi thì báo chủ nguồn');
  }
  YuiHeader head;
  try {
    head = YuiHeader.readSync(part.path);
  } on YuiFormatException catch (e) {
    await dropPart();
    throw HubDownloadException(e.message);
  }
  final why = checkHeaderAgainstManifest(m, head);
  if (why != null) {
    await dropPart();
    throw HubDownloadException('File không khớp manifest: $why. Đã xoá');
  }
  await part.rename(dest.path);
  return dest;
}

class _IntegrityFailure implements Exception {
  final String message;
  const _IntegrityFailure(this.message);
}

Future<void> _attempt(HubModel m, Uri uri, File part, _Run run, String? token, bool allowInsecure, HubCancel? cancel,
    void Function(bool) tick) async {
  // 1) chuẩn bị: nạp phần đã có của file dở vào bộ băm
  if (!run.hashed) {
    var len = await part.exists() ? await part.length() : 0;
    if (len > m.bytes) {
      await part.delete();
      len = 0;
    }
    run.h = Sha256();
    run.done = 0;
    if (len > 0) {
      await for (final c in part.openRead()) {
        run.h.add(c);
        run.done += c.length;
      }
    }
    run.hashed = true;
  } else if (await part.exists() ? await part.length() != run.done : run.done != 0) {
    run.hashed = false; // file trên đĩa lệch bộ nhớ (vd lần trước đóng file lỗi): băm lại từ file
    return _attempt(m, uri, part, run, token, allowInsecure, cancel, tick);
  }
  if (run.done == m.bytes) return;

  // 2) mở kết nối từ chỗ dở
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..userAgent = 'yui-app';
  try {
    final start = run.done;
    final res = await _open(client, uri, start, token, allowInsecure);
    final st = res.statusCode;
    var append = start > 0;
    if (st == 416) {
      await res.drain<void>();
      throw const _Restart();
    } else if (st == 206) {
      final cr = res.headers.value('content-range') ?? '';
      final mm = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(cr.trim());
      if (start == 0 || mm == null || int.parse(mm[1]!) != start || (mm[3] != '*' && int.parse(mm[3]!) != m.bytes)) {
        await res.drain<void>();
        throw const _Restart(); // trả sai khoảng: tải lại từ đầu thay vì nối bừa
      }
    } else if (st == 200) {
      if (res.contentLength >= 0 && res.contentLength != m.bytes) {
        // 200 phải là cả file: kích thước khác manifest nghĩa là sai file
        await res.drain<void>();
        throw const _IntegrityFailure('Kích thước máy chủ báo không khớp manifest');
      }
      if (start > 0) {
        // máy chủ bỏ qua Range và gửi lại cả file: ghi đè từ đầu
        run
          ..h = Sha256()
          ..done = 0;
        append = false;
      }
    } else {
      final ra = int.tryParse(res.headers.value('retry-after') ?? '');
      await res.drain<void>();
      throw HubHttpException(st, retryAfter: ra == null || ra < 0 ? null : Duration(seconds: ra > 30 ? 30 : ra));
    }
    if (st == 206 && res.contentLength >= 0 && start + res.contentLength != m.bytes) {
      await res.drain<void>();
      throw const _IntegrityFailure('Kích thước máy chủ báo không khớp manifest');
    }

    // 3) ghi dần, băm dần
    final sink = part.openWrite(mode: append ? FileMode.append : FileMode.write);
    Object? err;
    try {
      await for (final c in res.timeout(kHubStallTimeout)) {
        if (cancel?.cancelled == true) throw const HubCancelled();
        if (run.done + c.length > m.bytes) throw const _IntegrityFailure('Máy chủ gửi nhiều byte hơn khai báo trong manifest');
        sink.add(c);
        run.h.add(c);
        run.done += c.length;
        tick(false);
      }
    } catch (e) {
      err = e;
    }
    try {
      await sink.close();
    } catch (e) {
      run.hashed = false; // không chắc đã ghi đủ: lần sau băm lại từ file
      err ??= e;
    }
    if (err != null) throw err;
    if (run.done < m.bytes) throw const _Short(); // máy chủ đóng sớm: thử tiếp từ chỗ dở
  } finally {
    client.close(force: true);
  }
}
