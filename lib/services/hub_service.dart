// hub_service.dart - Kho model: lấy manifest.json từ một hoặc nhiều nguồn, kiểm từng mục, gộp theo thứ tự ưu tiên, lưu cache 24 giờ.
// Chỉ dùng thư viện chuẩn của Dart (dart:io, dart:convert, dart:async), không cần Flutter: có thể chạy thử bằng `dart run tools/hub_service_check.dart`.
//
// Nguyên tắc:
//  - KHÔNG tự nối mạng: chỉ gọi mạng khi code gọi HubService.load(). Chỗ gọi phải kiểm công tắc "Kho model" (mặc định TẮT) của người dùng.
//  - manifest chỉ là DỮ LIỆU để hiển thị và tải: mục nào sai kiểu/sai định dạng bị bỏ qua (đếm lại), không bao giờ làm hỏng cả danh sách.
//  - Mỗi nguồn độc lập: nguồn lỗi không làm hỏng nguồn kia; mất mạng thì dùng bản cache (kể cả đã quá 24 giờ, có đánh dấu).
//  - Gặp 429 (quá hạn mức Hugging Face) hoặc lỗi 5xx/mạng thì thử lại tối đa 3 lần, lùi dần 1s, 2s (hoặc theo Retry-After, tối đa 30s).
//  - Chỉ chấp nhận link https (kể cả sau chuyển hướng). Định dạng manifest do Adaptive-MoE/make_manifest.py sinh (manifest_version 1).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const int kHubManifestVersion = 1;
const int kHubMaxManifestBytes = 1 << 20; // 1 MB cho cả manifest
const int kHubMaxModels = 500; // trần số mục trong một manifest
const int kHubMaxModelBytes = 2 * 1024 * 1024 * 1024; // mục khai báo to hơn 2 GB bị bỏ qua
const Duration kHubCacheTtl = Duration(hours: 24);
const int kHubMaxAttempts = 3;

const String kHubOfficialUrl = 'https://huggingface.co/BachDaThan/Yui-Models/resolve/main/manifest.json';

class HubSource {
  final String name;
  final String url;
  const HubSource(this.name, this.url);

  /// Link manifest phải là https, có tên máy, không kèm tài khoản/mật khẩu.
  String? get problem {
    final u = Uri.tryParse(url.trim());
    if (u == null || u.scheme != 'https' || u.host.isEmpty) return 'link nguồn phải bắt đầu bằng https://';
    if (u.userInfo.isNotEmpty) return 'link nguồn không được chứa tài khoản/mật khẩu';
    return null;
  }
}

/// Nguồn mặc định (kho model của chủ app). Người dùng thêm nguồn khác ở phần cài đặt (làm ở P2-6).
const List<HubSource> kDefaultHubSources = [HubSource('Yui-Models', kHubOfficialUrl)];

class HubFormatException implements Exception {
  final String message;
  const HubFormatException(this.message);
  @override
  String toString() => message;
}

class HubHttpException implements Exception {
  final int status;
  final Duration? retryAfter;
  const HubHttpException(this.status, {this.retryAfter});
  bool get retryable => status == 429 || status >= 500;
  @override
  String toString() => 'HTTP $status';
}

final RegExp _ctl = RegExp('[\\u0000-\\u001f\\u007f-\\u009f\\u2028\\u2029]');
final RegExp _reSha = RegExp(r'^[0-9a-f]{64}$');
final RegExp _reId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');
final RegExp _reDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');

String _clean(String s) => s.replaceAll(_ctl, ' ').trim();

/// Một model trong Kho.
class HubModel {
  final String id;
  final String name;
  final String file; // đường dẫn tương đối trong repo nguồn
  final String url; // link tải .yui (https)
  final int bytes;
  final String sha256;
  final int yuiVer;
  final String quant;
  final int params;
  final String archId;
  final String tokenizerSha256;
  final List<String> domains;
  final List<String> lang;
  final String license;
  final int ctx;
  final String description;
  final String created;
  final String base;
  final String sourceName; // nguồn đã cung cấp mục này
  const HubModel({
    required this.id,
    required this.name,
    required this.file,
    required this.url,
    required this.bytes,
    required this.sha256,
    required this.yuiVer,
    required this.quant,
    required this.params,
    required this.archId,
    required this.tokenizerSha256,
    required this.domains,
    required this.lang,
    required this.license,
    required this.ctx,
    required this.description,
    required this.created,
    required this.base,
    required this.sourceName,
  });

  String get sizeText => bytes >= 1e9 ? '${(bytes / 1e9).toStringAsFixed(2)} GB' : '${(bytes / 1e6).toStringAsFixed(1)} MB';

  /// Đọc một mục manifest; trả null nếu mục sai (không ném lỗi: mục sai chỉ bị bỏ qua).
  static HubModel? tryParse(Object? raw, String sourceName) {
    if (raw is! Map) return null;
    String? str(String k, int max, {bool required = true, bool truncate = false}) {
      final v = raw[k];
      if (v == null) return required ? null : '';
      if (v is! String) return null;
      var s = _clean(v);
      if (s.length > max) {
        if (!truncate) return null;
        s = '${s.substring(0, max - 1)}…';
      }
      if (required && s.isEmpty) return null;
      return s;
    }

    int? num_(String k) {
      final v = raw[k];
      return v is int ? v : null;
    }

    List<String>? strList(String k) {
      final v = raw[k];
      if (v is! List || v.length > 16) return null;
      final out = <String>[];
      for (final x in v) {
        if (x is! String) return null;
        final s = _clean(x);
        if (s.isEmpty || s.length > 32) return null;
        out.add(s);
      }
      return out;
    }

    final id = str('id', 128), name = str('name', 128), file = str('file', 256), url = str('url', 1024);
    final sha = str('sha256', 64), quant = str('quant', 16), arch = str('arch_id', 128), tok = str('tokenizer_sha256', 64);
    final license = str('license', 128);
    final bytes = num_('bytes'), params = num_('params'), ver = num_('yui_ver'), ctx = num_('ctx');
    final domains = strList('domains'), lang = strList('lang');
    if ([id, name, file, url, sha, quant, arch, tok, license, bytes, params, ver, ctx, domains, lang].contains(null)) return null;
    if (!_reId.hasMatch(id!)) return null;
    if (!_reSha.hasMatch(sha!) || !_reSha.hasMatch(tok!)) return null;
    if (bytes! <= 0 || bytes > kHubMaxModelBytes || params! <= 0 || ctx! <= 0) return null;
    if (ver! < 1 || ver > 3) return null;
    if (file!.startsWith('/') || file.contains('\\') || file.split('/').contains('..') || !file.toLowerCase().endsWith('.yui')) return null;
    final u = Uri.tryParse(url!);
    if (u == null || u.scheme != 'https' || u.host.isEmpty || u.userInfo.isNotEmpty || !u.path.toLowerCase().endsWith('.yui')) return null;
    final desc = str('description', 300, required: false, truncate: true);
    final created = str('created', 10, required: false);
    final base = str('base', 128, required: false, truncate: true);
    if (desc == null || created == null || base == null) return null;
    if (created.isNotEmpty && !_reDate.hasMatch(created)) return null;
    return HubModel(
      id: id,
      name: name!,
      file: file,
      url: url,
      bytes: bytes,
      sha256: sha,
      yuiVer: ver,
      quant: quant!,
      params: params,
      archId: arch!,
      tokenizerSha256: tok,
      domains: domains!,
      lang: lang!,
      license: license!,
      ctx: ctx,
      description: desc,
      created: created,
      base: base,
      sourceName: sourceName,
    );
  }
}

class HubManifest {
  final String generated;
  final List<HubModel> models;
  final int skipped; // số mục sai bị bỏ qua
  const HubManifest(this.generated, this.models, this.skipped);

  /// Đọc manifest từ chuỗi JSON. Sai CẤU TRÚC (không phải JSON, sai phiên bản, models không phải mảng, quá nhiều mục) -> HubFormatException.
  static HubManifest parse(String body, String sourceName) {
    Object? j;
    try {
      j = jsonDecode(body);
    } on FormatException {
      throw const HubFormatException('manifest không phải JSON hợp lệ');
    }
    if (j is! Map) throw const HubFormatException('manifest phải là một đối tượng JSON');
    if (j['manifest_version'] != kHubManifestVersion) {
      throw HubFormatException('manifest phiên bản ${j['manifest_version']} chưa hỗ trợ (app biết $kHubManifestVersion), hãy cập nhật app');
    }
    final ms = j['models'];
    if (ms is! List) throw const HubFormatException('manifest thiếu mảng models');
    if (ms.length > kHubMaxModels) throw const HubFormatException('manifest có quá nhiều mục (tối đa $kHubMaxModels)');
    final out = <HubModel>[];
    final ids = <String>{};
    var skipped = 0;
    for (final e in ms) {
      final m = HubModel.tryParse(e, sourceName);
      if (m == null || !ids.add(m.id)) {
        skipped++;
        continue;
      }
      out.add(m);
    }
    final g = j['generated'];
    return HubManifest(g is String ? _clean(g) : '', out, skipped);
  }
}

/// Tình trạng của từng nguồn sau một lần load.
class HubSourceStatus {
  final HubSource source;
  final bool ok; // có danh sách để dùng (mới hoặc từ cache)
  final bool fromCache; // danh sách lấy từ cache
  final bool stale; // cache đã quá hạn 24 giờ mà không làm mới được
  final String? error; // lý do (tiếng Việt) nếu không làm mới được / không có gì để dùng
  final int fetchedMs; // thời điểm danh sách này được tải (0 nếu không có)
  final int count; // số model hợp lệ
  final int skipped; // số mục sai bị bỏ qua
  const HubSourceStatus(this.source, {required this.ok, this.fromCache = false, this.stale = false, this.error, this.fetchedMs = 0, this.count = 0, this.skipped = 0});
}

class HubResult {
  final List<HubModel> models; // đã gộp theo thứ tự nguồn (trùng id: nguồn đứng trước thắng)
  final List<HubSourceStatus> statuses;
  final List<String> notes; // vd "model 'x' của nguồn B bị bỏ vì trùng id với nguồn A"
  const HubResult(this.models, this.statuses, this.notes);
  bool get anyOk => statuses.any((s) => s.ok);
  bool get allFailed => statuses.isNotEmpty && !anyOk;
}

typedef HubFetch = Future<String> Function(Uri uri);

/// Một lần tải manifest (không thử lại). Ném HubHttpException (mã khác 200), HubFormatException (quá lớn / chuyển hướng sang http / sai UTF-8), hoặc lỗi mạng của dart:io.
Future<String> defaultHubFetch(Uri uri) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..userAgent = 'yui-app';
  try {
    final req = await client.getUrl(uri).timeout(const Duration(seconds: 15));
    req.headers.set('Accept', 'application/json');
    final res = await req.close().timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      final ra = int.tryParse(res.headers.value('retry-after') ?? '');
      await res.drain<void>();
      throw HubHttpException(res.statusCode, retryAfter: ra == null || ra < 0 ? null : Duration(seconds: ra > 30 ? 30 : ra));
    }
    for (final r in res.redirects) {
      if (r.location.scheme != 'https') throw const HubFormatException('nguồn chuyển hướng sang địa chỉ không phải https, đã chặn');
    }
    if (res.contentLength > kHubMaxManifestBytes) throw const HubFormatException('manifest quá lớn (> 1 MB)');
    final b = BytesBuilder(copy: false);
    await for (final c in res.timeout(const Duration(seconds: 20))) {
      b.add(c);
      if (b.length > kHubMaxManifestBytes) throw const HubFormatException('manifest quá lớn (> 1 MB)');
    }
    try {
      return utf8.decode(b.takeBytes());
    } on FormatException {
      throw const HubFormatException('manifest không phải UTF-8 hợp lệ');
    }
  } finally {
    client.close(force: true);
  }
}

class _Cached {
  final int fetchedMs;
  final String body;
  const _Cached(this.fetchedMs, this.body);
}

String _fnv(String s) {
  var h = 0x811c9dc5;
  for (final b in utf8.encode(s)) {
    h ^= b;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

String describeHubError(Object e) {
  if (e is HubHttpException) {
    if (e.status == 429) return 'quá nhiều yêu cầu tới máy chủ (HTTP 429), hãy thử lại sau ít phút';
    if (e.status == 404) return 'không thấy manifest.json ở nguồn này (HTTP 404)';
    if (e.status == 401 || e.status == 403) return 'nguồn không cho truy cập (HTTP ${e.status})';
    return 'máy chủ trả lỗi HTTP ${e.status}';
  }
  if (e is HubFormatException) return e.message;
  if (e is TimeoutException) return 'quá thời gian chờ, kiểm tra mạng';
  if (e is SocketException || e is HandshakeException || e is HttpException) return 'không kết nối được, kiểm tra mạng';
  return 'lỗi không rõ: $e';
}

class HubService {
  final Directory cacheDir;
  final HubFetch fetch;
  final int Function() now;
  final Future<void> Function(Duration) sleep;
  final Duration ttl;

  HubService(this.cacheDir, {HubFetch? fetch, int Function()? now, Future<void> Function(Duration)? sleep, this.ttl = kHubCacheTtl})
      : fetch = fetch ?? defaultHubFetch,
        now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
        sleep = sleep ?? ((d) => Future<void>.delayed(d));

  File _cacheFile(HubSource s) => File('${cacheDir.path}${Platform.pathSeparator}hub_${_fnv(s.url.trim())}.json');

  Future<_Cached?> _readCache(HubSource s) async {
    try {
      final f = _cacheFile(s);
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map || j['url'] != s.url.trim() || j['body'] is! String || j['fetched_ms'] is! int) return null;
      return _Cached(j['fetched_ms'] as int, j['body'] as String);
    } catch (_) {
      return null; // cache hỏng thì coi như không có
    }
  }

  Future<void> _writeCache(HubSource s, String body, int ms) async {
    try {
      await cacheDir.create(recursive: true);
      final f = _cacheFile(s);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode({'v': 1, 'url': s.url.trim(), 'fetched_ms': ms, 'body': body}), flush: true);
      await tmp.rename(f.path);
    } catch (_) {
      // không ghi được cache không phải lỗi của người dùng
    }
  }

  Future<String> _fetchWithRetry(Uri uri) async {
    for (var attempt = 1;; attempt++) {
      try {
        return await fetch(uri);
      } catch (e) {
        final retryable = e is HubHttpException
            ? e.retryable
            : (e is TimeoutException || e is SocketException || e is HandshakeException || e is HttpException);
        if (!retryable || attempt >= kHubMaxAttempts) rethrow;
        var wait = Duration(seconds: 1 << (attempt - 1));
        if (e is HubHttpException && e.retryAfter != null) wait = e.retryAfter!;
        await sleep(wait);
      }
    }
  }

  Future<(HubManifest?, HubSourceStatus)> _loadOne(HubSource s, bool force) async {
    final bad = s.problem;
    if (bad != null) return (null, HubSourceStatus(s, ok: false, error: bad));
    final cached = await _readCache(s);
    final t = now();
    if (!force && cached != null && t >= cached.fetchedMs && t - cached.fetchedMs < ttl.inMilliseconds) {
      try {
        final m = HubManifest.parse(cached.body, s.name);
        return (m, HubSourceStatus(s, ok: true, fromCache: true, fetchedMs: cached.fetchedMs, count: m.models.length, skipped: m.skipped));
      } on HubFormatException {
        // cache cũ không còn hợp lệ: tải mới bên dưới
      }
    }
    String? why;
    try {
      final body = await _fetchWithRetry(Uri.parse(s.url.trim()));
      final m = HubManifest.parse(body, s.name);
      await _writeCache(s, body, t);
      return (m, HubSourceStatus(s, ok: true, fetchedMs: t, count: m.models.length, skipped: m.skipped));
    } catch (e) {
      why = describeHubError(e);
    }
    if (cached != null) {
      try {
        final m = HubManifest.parse(cached.body, s.name);
        return (m, HubSourceStatus(s, ok: true, fromCache: true, stale: true, error: why, fetchedMs: cached.fetchedMs, count: m.models.length, skipped: m.skipped));
      } on HubFormatException {
        // cache hỏng: rơi xuống báo lỗi
      }
    }
    return (null, HubSourceStatus(s, ok: false, error: why));
  }

  /// Tải (hoặc lấy từ cache còn hạn) manifest của mọi nguồn rồi gộp. force=true bỏ qua cache còn hạn (nút "Làm mới").
  /// Không ném lỗi vì một nguồn hỏng: xem HubResult.statuses.
  Future<HubResult> load(List<HubSource> sources, {bool force = false}) async {
    final parts = await Future.wait(sources.map((s) => _loadOne(s, force)));
    final models = <HubModel>[];
    final statuses = <HubSourceStatus>[];
    final notes = <String>[];
    final owner = <String, String>{};
    for (final (m, st) in parts) {
      statuses.add(st);
      if (m == null) continue;
      for (final e in m.models) {
        final first = owner[e.id];
        if (first != null) {
          notes.add("model '${e.id}' của nguồn ${st.source.name} bị bỏ vì trùng id với nguồn $first");
          continue;
        }
        owner[e.id] = st.source.name;
        models.add(e);
      }
    }
    return HubResult(models, statuses, notes);
  }
}
