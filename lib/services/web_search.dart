// web_search.dart - TÌM WEB NHIỀU TẦNG cho công cụ `search` của app (điện thoại + máy tính). Port gọn từ yui_web.py của Adaptive-MoE:
// một tầng hỏng thì tự sang tầng sau, cuối cùng luôn trả về một câu (không bao giờ "câm"). Dart thuần, chạy thử bằng `dart tools/web_search_check.dart`.
//
//  Tầng 1  API có key của người dùng: tavily, exa, linkup, firecrawl, braveapi (Brave Search API), gcse (Google Programmable Search, key dạng "KHOÁ:CX").
//          Mỗi dịch vụ nhận NHIỀU key, xoay vòng; key bị giới hạn (429/432/433/402) nghỉ 1-30 phút tăng dần, key sai (401/403) nghỉ 6 giờ, lỗi nghỉ ngắn.
//  Tầng 2  DuckDuckGo (bản HTML, miễn phí, không cần key) bằng chính IP của người dùng; bị chặn (202/403/429) thì nghỉ rồi nhường tầng sau.
//  Tầng 3  SearXNG công cộng: các địa chỉ https do NGƯỜI DÙNG liệt kê (liệt kê = đồng ý), xáo trộn, instance lỗi/khoá JSON nghỉ riêng.
//  Tầng 4  Wikipedia tiếng Việt rồi tiếng Anh; sau cùng là kho tri thức cá nhân nếu có (móc `kb`, chưa có trong app cho tới P3).
//  KHÔNG port: các tầng đào HTML Brave/Bing/Google của yui_web.py (bản parse chưa thử với trang thật, và điều khoản các trang này cấm truy vấn tự động).
//
// An toàn: chỉ https; chỉ nói chuyện với các tên miền đã biết (dịch vụ ở trên) + host SearXNG người dùng liệt kê; chuyển hướng (≤ 3) cũng bị kiểm lại;
// host SearXNG do người dùng nhập phải phân giải ra địa chỉ CÔNG CỘNG (chặn localhost, 10.x, 192.168.x, 172.16-31.x, 169.254.x, 100.64/10, IPv6 nội bộ);
// giới hạn dung lượng phản hồi; key không bao giờ xuất hiện trong kết quả trả về hay thông báo lỗi. Chưa chống DNS-rebinding bằng cách ghim IP như yui_agent.py
// (chỉ ảnh hưởng host SearXNG người dùng tự thêm). Bản parse từng dịch vụ viết theo tài liệu công khai, đã thử bằng máy chủ giả, CHƯA thử với key thật.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const List<String> kWebProviders = ['tavily', 'exa', 'linkup', 'firecrawl', 'braveapi', 'gcse'];
const List<String> kWebDefaultOrder = ['tavily', 'exa', 'linkup', 'firecrawl', 'braveapi', 'gcse', 'ddg', 'searxng', 'wikipedia', 'kb'];
const Map<String, String> kWebBases = {
  'tavily': 'https://api.tavily.com',
  'exa': 'https://api.exa.ai',
  'linkup': 'https://api.linkup.so',
  'firecrawl': 'https://api.firecrawl.dev',
  'braveapi': 'https://api.search.brave.com',
  'gcse': 'https://www.googleapis.com',
  'ddg': 'https://html.duckduckgo.com',
  'wikipedia': 'https://vi.wikipedia.org',
  'wikipedia_en': 'https://en.wikipedia.org',
};
const String kBrowserUa = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36';
const int kWebMaxRedirects = 3;

class WebResult {
  final String title, url, snippet;
  const WebResult(this.title, this.url, this.snippet);
}

class TierError implements Exception {
  final String kind; // quota | auth | error | blocked | empty
  final String msg;
  const TierError(this.kind, [this.msg = '']);
  @override
  String toString() => msg.isEmpty ? kind : msg;
}

class WebResponse {
  final int status;
  final String contentType;
  final Uint8List bytes;
  final String? location; // có khi là chuyển hướng
  const WebResponse(this.status, this.contentType, this.bytes, [this.location]);
}

typedef WebHttp = Future<WebResponse> Function(String method, Uri uri, {String? body, Map<String, String>? headers, int maxKb, int timeoutS});

/// Một lần gọi HTTP, KHÔNG tự chuyển hướng (WebSearch tự đi theo và kiểm lại từng bước). Ném lỗi mạng của dart:io khi hỏng.
Future<WebResponse> defaultWebHttp(String method, Uri uri, {String? body, Map<String, String>? headers, int maxKb = 256, int timeoutS = 8}) async {
  final c = HttpClient()
    ..connectionTimeout = Duration(seconds: timeoutS)
    ..userAgent = 'YuiApp/1.0'
    ..autoUncompress = true;
  try {
    final req = await c.openUrl(method, uri).timeout(Duration(seconds: timeoutS));
    req.followRedirects = false;
    headers?.forEach((k, v) => req.headers.set(k, v));
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(body));
    }
    final res = await req.close().timeout(Duration(seconds: timeoutS + 4));
    final b = BytesBuilder(copy: false);
    final cap = maxKb * 1024;
    await for (final chunk in res.timeout(Duration(seconds: timeoutS + 4))) {
      b.add(chunk);
      if (b.length > cap) break; // đủ rồi: cắt, không tải nốt
    }
    final all = b.takeBytes();
    return WebResponse(res.statusCode, res.headers.contentType?.mimeType ?? res.headers.value('content-type') ?? '',
        all.length > cap ? Uint8List.sublistView(all, 0, cap) : all, res.headers.value('location'));
  } finally {
    c.close(force: true);
  }
}

// ---------------------------------------------------------------- địa chỉ công cộng (chặn SSRF)
/// true nếu là địa chỉ internet công cộng (không loopback/riêng tư/link-local/CGNAT/multicast/chưa định).
bool isPublicAddress(InternetAddress a) {
  final b = a.rawAddress;
  if (b.length == 4) {
    final x = b[0], y = b[1];
    if (x == 0 || x == 10 || x == 127 || x >= 224) return false;
    if (x == 100 && y >= 64 && y <= 127) return false; // CGNAT 100.64/10
    if (x == 169 && y == 254) return false;
    if (x == 172 && y >= 16 && y <= 31) return false;
    if (x == 192 && y == 168) return false;
    if (x == 192 && y == 0 && b[2] == 0) return false; // 192.0.0.0/24
    if (x == 198 && (y == 18 || y == 19)) return false; // 198.18/15 đo kiểm
    return true;
  }
  if (b.length == 16) {
    final allZero = b.every((v) => v == 0);
    if (allZero) return false; // ::
    if (b.sublist(0, 15).every((v) => v == 0) && b[15] == 1) return false; // ::1
    if ((b[0] & 0xfe) == 0xfc) return false; // fc00::/7
    if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return false; // fe80::/10
    if (b[0] == 0xff) return false; // multicast
    if (b.sublist(0, 10).every((v) => v == 0) && b[10] == 0xff && b[11] == 0xff) {
      return isPublicAddress(InternetAddress.fromRawAddress(Uint8List.fromList(b.sublist(12)))); // ::ffff:a.b.c.d
    }
    if (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8) return false; // 2001:db8::/32
    return true;
  }
  return false;
}

Future<List<InternetAddress>> defaultResolve(String host) => InternetAddress.lookup(host);

// ---------------------------------------------------------------- định dạng
final RegExp _tagRe = RegExp(r'<[^>]+>', dotAll: true);
final RegExp _wsRe = RegExp(r'\s+');
const Map<String, String> _ents = {'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' ', 'ndash': '–', 'mdash': '—', 'hellip': '…', 'laquo': '«', 'raquo': '»'};

String htmlUnescape(String s) => s.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);'), (m) {
      final e = m[1]!;
      if (e.startsWith('#x')) {
        final v = int.tryParse(e.substring(2), radix: 16);
        return (v != null && v > 0 && v <= 0x10ffff) ? String.fromCharCode(v) : m[0]!;
      }
      if (e.startsWith('#')) {
        final v = int.tryParse(e.substring(1));
        return (v != null && v > 0 && v <= 0x10ffff) ? String.fromCharCode(v) : m[0]!;
      }
      return _ents[e] ?? m[0]!;
    });

String cleanText(Object? s) => htmlUnescape('${s ?? ''}'.replaceAll(_tagRe, ' ')).replaceAll(_wsRe, ' ').trim();

String domainOf(String url) {
  final h = Uri.tryParse(url)?.host ?? '';
  return h.startsWith('www.') ? h.substring(4) : h;
}

String _cut(String s, int n) {
  final r = s.runes.toList();
  return r.length <= n ? s : String.fromCharCodes(r.take(n));
}

int _len(String s) => s.runes.length;

/// [{title,url,snippet}] -> "đoạn trích (nguồn) | đoạn trích 2 (nguồn)" vừa [chars] ký tự.
String fmtResults(List<WebResult> rs, int chars) {
  final out = <String>[];
  var left = chars;
  for (final r in rs) {
    final sn = cleanText(r.snippet.isNotEmpty ? r.snippet : r.title);
    if (sn.isEmpty) continue;
    final tail = r.url.isNotEmpty ? ' (${domainOf(r.url)})' : '';
    final room = out.isEmpty ? left : left - 3;
    if (room < 60) break;
    final piece = _len(sn) + _len(tail) <= room ? sn : '${_cut(sn, (room - _len(tail) - 1) < 20 ? 20 : room - _len(tail) - 1).trimRight()}…';
    out.add('$piece$tail');
    left -= _len(piece) + _len(tail) + 3;
  }
  return out.join(' | ');
}

// ---------------------------------------------------------------- phân tích từng dịch vụ
Map _obj(String body) {
  try {
    final j = jsonDecode(body);
    if (j is Map) return j;
  } catch (_) {}
  throw const TierError('error', 'phản hồi không phải JSON');
}

String _s(Object? v) => v is String ? v : (v == null ? '' : '$v');
List _list(Object? v) => v is List ? v : const [];

List<WebResult> parseTavily(Map d) => [for (final r in _list(d['results'])) if (r is Map) WebResult(_s(r['title']), _s(r['url']), _s(r['content']))];

List<WebResult> parseExa(Map d) => [
      for (final r in _list(d['results']))
        if (r is Map)
          WebResult(_s(r['title']), _s(r['url']), _s(r['text']).isNotEmpty ? _s(r['text']) : (_s(r['summary']).isNotEmpty ? _s(r['summary']) : (_list(r['highlights']).isNotEmpty ? _s(_list(r['highlights']).first) : '')))
    ];

List<WebResult> parseLinkup(Map d) => [
      for (final r in _list(d['results']))
        if (r is Map) WebResult(_s(r['name'] ?? r['title']), _s(r['url']), _s(r['content'] ?? r['snippet']))
    ];

List<WebResult> parseFirecrawl(Map d) {
  var data = d['data'];
  if (data is Map) data = data['web'];
  return [
    for (final r in _list(data))
      if (r is Map) WebResult(_s(r['title']), _s(r['url']), _s(r['description']).isNotEmpty ? _s(r['description']) : _cut(_s(r['markdown']), 600))
  ];
}

List<WebResult> parseSearxng(Map d) => [for (final r in _list(d['results'])) if (r is Map) WebResult(_s(r['title']), _s(r['url']), _s(r['content']))];

List<WebResult> parseBraveApi(Map d) {
  final w = d['web'];
  return [for (final r in _list(w is Map ? w['results'] : null)) if (r is Map) WebResult(_s(r['title']), _s(r['url']), _s(r['description']))];
}

List<WebResult> parseGcse(Map d) => [for (final r in _list(d['items'])) if (r is Map) WebResult(_s(r['title']), _s(r['link']), _s(r['snippet']))];

final RegExp _aRe = RegExp(r'<a\b([^>]*)>(.*?)</a>', dotAll: true, caseSensitive: false);
final RegExp _clsRe = RegExp(r'class="([^"]*)"');
final RegExp _hrefRe = RegExp(r'href="([^"]+)"');

/// Trang html.duckduckgo.com/html: thẻ <a class=result__a> (tiêu đề + link bọc uddg) và <a class=result__snippet>.
List<WebResult> parseDdg(String page) {
  if (RegExp(r'anomaly|captcha|unusual traffic', caseSensitive: false).hasMatch(page) && !page.contains('result__a')) {
    throw const TierError('blocked', 'DuckDuckGo yêu cầu xác minh');
  }
  final titles = <String>[], urls = <String>[], snips = <String>[];
  for (final m in _aRe.allMatches(page)) {
    final attrs = m[1]!, inner = m[2]!;
    final cls = _clsRe.firstMatch(attrs)?[1] ?? '';
    if (cls.contains('result__a')) {
      var href = htmlUnescape(_hrefRe.firstMatch(attrs)?[1] ?? '');
      if (href.contains('uddg=')) {
        try {
          href = Uri.parse(href).queryParameters['uddg'] ?? href;
        } catch (_) {}
      } else if (href.startsWith('//')) {
        href = 'https:$href';
      }
      titles.add(cleanText(inner));
      urls.add(href);
      snips.add('');
    } else if (cls.contains('result__snippet') && snips.isNotEmpty && snips.last.isEmpty) {
      snips[snips.length - 1] = cleanText(inner);
    }
  }
  return [for (var i = 0; i < titles.length; i++) WebResult(titles[i], urls[i], snips[i])];
}

// ---------------------------------------------------------------- cấu hình người dùng
/// Cấu hình tìm web do người dùng nhập (mỗi dòng "tên=giá trị"; dòng bắt đầu bằng # là ghi chú).
///   tavily=key1,key2   exa=...   linkup=...   firecrawl=...   braveapi=...   gcse=KHOÁ:CX,KHOÁ2:CX2
///   searxng=https://a.example,https://b.example
class WebConfig {
  final Map<String, List<String>> keys;
  final List<String> searxng;
  final List<String> problems; // dòng không hiểu / link không hợp lệ (để báo cho người dùng)
  const WebConfig(this.keys, this.searxng, this.problems);
  static const WebConfig empty = WebConfig({}, [], []);

  static WebConfig parse(String text) {
    final keys = <String, List<String>>{};
    final sx = <String>[];
    final bad = <String>[];
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final i = line.indexOf('=');
      if (i <= 0) {
        bad.add('dòng thiếu dấu "=": ${_cut(line, 30)}…');
        continue;
      }
      final name = line.substring(0, i).trim().toLowerCase();
      final vals = line.substring(i + 1).split(RegExp(r'[,;\s]+')).where((x) => x.isNotEmpty).toList();
      if (name == 'searxng') {
        for (final u in vals) {
          final p = Uri.tryParse(u);
          if (p == null || p.scheme != 'https' || p.host.isEmpty || p.userInfo.isNotEmpty) {
            bad.add('searxng: chỉ nhận link https, bỏ "${_cut(u, 40)}"');
          } else {
            sx.add(u.replaceAll(RegExp(r'/+$'), ''));
          }
        }
      } else if (kWebProviders.contains(name)) {
        keys.putIfAbsent(name, () => []).addAll(vals);
      } else {
        bad.add('không biết nguồn "$name" (có: ${kWebProviders.join(', ')}, searxng)');
      }
    }
    return WebConfig({for (final e in keys.entries) e.key: e.value.toSet().toList()}, sx.toSet().toList(), bad);
  }
}

// ---------------------------------------------------------------- bộ tìm
class _Cool {
  int until = 0, fails = 0;
}

class WebSearch {
  final Map<String, List<String>> keys;
  final List<String> order;
  final Map<String, String> bases;
  final WebHttp http;
  final int Function() nowMs;
  final Future<List<InternetAddress>> Function(String) resolve;
  final bool Function(InternetAddress) isPublic;
  final Future<String?> Function(String q, int chars)? kb; // kho tri thức cá nhân (P3), tuỳ chọn
  final Duration cacheTtl;
  final Duration budget;
  final bool allowInsecure; // CHỈ cho test với máy chủ cục bộ

  final Map<String, _Cool> _state = {};
  final Map<String, int> _rr = {};
  final Map<String, (int, String)> _cache = {};
  late final Set<String> _fixedHosts;
  late final Set<String> _searxHosts;
  late final List<String> _searxUrls;

  WebSearch({
    Map<String, List<String>> keys = const {},
    List<String> searxng = const [],
    List<String>? order,
    Map<String, String>? bases,
    WebHttp? http,
    int Function()? nowMs,
    Future<List<InternetAddress>> Function(String)? resolve,
    bool Function(InternetAddress)? isPublic,
    this.kb,
    this.cacheTtl = const Duration(minutes: 10),
    this.budget = const Duration(seconds: 25),
    this.allowInsecure = false,
  })  : keys = {for (final e in keys.entries) e.key: e.value.map((k) => k.trim()).where((k) => k.isNotEmpty).toSet().toList()},
        order = order ?? kWebDefaultOrder,
        bases = {...kWebBases, ...?bases},
        http = http ?? defaultWebHttp,
        nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
        resolve = resolve ?? defaultResolve,
        isPublic = isPublic ?? isPublicAddress {
    _searxUrls = searxng.map((u) => u.trim().replaceAll(RegExp(r'/+$'), '')).where((u) => allowInsecure ? u.startsWith('http') : u.startsWith('https://')).toSet().toList();
    _searxHosts = {for (final u in _searxUrls) if (Uri.tryParse(u)?.host.isNotEmpty ?? false) Uri.parse(u).host.toLowerCase()};
    _fixedHosts = {for (final b in this.bases.values) if (Uri.tryParse(b)?.host.isNotEmpty ?? false) Uri.parse(b).host.toLowerCase()};
  }

  String base(String name) => bases[name]!.replaceAll(RegExp(r'/+$'), '');

  /// Có khoá hay SearXNG nào được cấu hình không (để giao diện hiển thị).
  bool get hasExtraSources => keys.values.any((v) => v.isNotEmpty) || _searxUrls.isNotEmpty;

  /// Trạng thái nghỉ của từng key (đã che key, chỉ 4 ký tự đầu): "tavily:tvly…" -> giây còn nghỉ.
  Map<String, int> coolStatus() {
    final t = nowMs();
    return {
      for (final e in _state.entries)
        if (e.value.until > t) _mask(e.key): ((e.value.until - t) / 1000).ceil()
    };
  }

  static String _mask(String k) {
    final i = k.indexOf('|');
    if (i < 0) return k;
    final tier = k.substring(0, i), key = k.substring(i + 1);
    if (key == '-') return '$tier:-';
    if (key.startsWith('http')) return '$tier:${domainOf(key)}';
    return '$tier:${_cut(key, 4)}…';
  }

  // ---- nghỉ / xoay vòng ----
  void _cool(String tier, String key, String kind) {
    final s = _state.putIfAbsent('$tier|$key', () => _Cool());
    s.fails++;
    final (base, cap) = switch (kind) {
      'quota' => (60, 1800),
      'auth' => (21600, 21600),
      'blocked' => (120, 900),
      _ => (20, 300),
    };
    final exp = (s.fails - 1) > 5 ? 5 : s.fails - 1;
    final sec = (base * (1 << exp)) > cap ? cap : base * (1 << exp);
    s.until = nowMs() + sec * 1000;
  }

  void _good(String tier, String key) => _state.remove('$tier|$key');
  bool _ready(String tier, String key) => (_state['$tier|$key']?.until ?? 0) <= nowMs();

  List<String> _rotate(String tier, List<String> ks) {
    final i = _rr[tier] ?? 0;
    _rr[tier] = i + 1;
    final n = ks.length;
    return [for (var j = 0; j < n; j++) if (_ready(tier, ks[(i + j) % n])) ks[(i + j) % n]];
  }

  // ---- gọi mạng có kiểm soát ----
  Future<bool> _allowed(Uri u) async {
    if (u.host.isEmpty || u.userInfo.isNotEmpty) return false;
    if (u.scheme != 'https' && !(allowInsecure && u.scheme == 'http')) return false;
    final h = u.host.toLowerCase();
    if (_fixedHosts.contains(h)) return true;
    if (!_searxHosts.contains(h)) return false;
    // host do người dùng liệt kê: vẫn phải phân giải ra địa chỉ CÔNG CỘNG
    final lit = InternetAddress.tryParse(h);
    try {
      final addrs = lit != null ? [lit] : await resolve(h);
      return addrs.isNotEmpty && addrs.every(isPublic);
    } catch (_) {
      return false;
    }
  }

  Future<WebResponse> _fetch(String method, Uri uri, {String? body, Map<String, String>? headers, int maxKb = 128, int timeoutS = 8}) async {
    var cur = uri;
    var m = method;
    var b = body;
    for (var hop = 0; hop <= kWebMaxRedirects; hop++) {
      if (!await _allowed(cur)) throw const TierError('empty', 'tên miền chưa được cho phép');
      final r = await http(m, cur, body: b, headers: headers, maxKb: maxKb, timeoutS: timeoutS);
      if ({301, 302, 303, 307, 308}.contains(r.status) && r.location != null) {
        cur = cur.resolve(r.location!);
        if (r.status == 301 || r.status == 302 || r.status == 303) {
          m = 'GET';
          b = null;
        }
        continue;
      }
      return r;
    }
    throw const TierError('error', 'quá nhiều lần chuyển hướng');
  }

  String _text(WebResponse r) => utf8.decode(r.bytes, allowMalformed: true);

  // ---- các tầng ----
  (String, Uri, String?, Map<String, String>, int, int) _req(String prov, String q, int n, String key) {
    final b = base(prov);
    const js = {'Content-Type': 'application/json'};
    switch (prov) {
      case 'tavily':
        return ('POST', Uri.parse('$b/search'), jsonEncode({'query': q, 'max_results': n, 'search_depth': 'basic'}), {...js, 'Authorization': 'Bearer $key'}, 128, 10);
      case 'exa':
        return ('POST', Uri.parse('$b/search'), jsonEncode({'query': q, 'numResults': n, 'contents': {'text': {'maxCharacters': 600}}}), {...js, 'x-api-key': key}, 128, 10);
      case 'linkup':
        return ('POST', Uri.parse('$b/v1/search'), jsonEncode({'q': q, 'depth': 'standard', 'outputType': 'searchResults'}), {...js, 'Authorization': 'Bearer $key'}, 128, 12);
      case 'braveapi':
        return ('GET', Uri.parse('$b/res/v1/web/search').replace(queryParameters: {'q': q, 'count': '$n'}), null, {'Accept': 'application/json', 'X-Subscription-Token': key}, 128, 10);
      case 'gcse':
        final i = key.indexOf(':');
        final k = i < 0 ? key : key.substring(0, i), cx = i < 0 ? '' : key.substring(i + 1);
        return ('GET', Uri.parse('$b/customsearch/v1').replace(queryParameters: {'key': k, 'cx': cx, 'q': q, 'num': '${n > 10 ? 10 : n}'}), null, {'Accept': 'application/json'}, 128, 10);
      default: // firecrawl
        return ('POST', Uri.parse('$b/v1/search'), jsonEncode({'query': q, 'limit': n}), {...js, 'Authorization': 'Bearer $key'}, 128, 12);
    }
  }

  Future<List<WebResult>> _keyed(String prov, String q, int n) async {
    final ks = keys[prov] ?? const [];
    if (ks.isEmpty) throw const TierError('empty', 'không có key');
    TierError? last;
    for (final key in _rotate(prov, ks)) {
      final (m, uri, body, headers, maxKb, to) = _req(prov, q, n, key);
      WebResponse r;
      try {
        r = await _fetch(m, uri, body: body, headers: headers, maxKb: maxKb, timeoutS: to);
      } on TierError catch (e) {
        if (e.kind == 'empty') rethrow; // tên miền không được phép: không phải lỗi của key
        _cool(prov, key, 'error');
        last = e;
        continue;
      } catch (_) {
        _cool(prov, key, 'error');
        last = const TierError('error', 'lỗi mạng');
        continue;
      }
      if (r.status == 200) {
        List<WebResult> res;
        try {
          final d = _obj(_text(r));
          res = switch (prov) {
            'tavily' => parseTavily(d),
            'exa' => parseExa(d),
            'linkup' => parseLinkup(d),
            'braveapi' => parseBraveApi(d),
            'gcse' => parseGcse(d),
            _ => parseFirecrawl(d),
          };
        } on TierError catch (e) {
          _cool(prov, key, 'error');
          last = e;
          continue;
        }
        _good(prov, key);
        if (res.isNotEmpty) return res;
        throw const TierError('empty', 'không có kết quả');
      }
      final kind = {429, 432, 433, 402}.contains(r.status) ? 'quota' : (r.status == 401 || r.status == 403) ? 'auth' : 'error';
      _cool(prov, key, kind);
      last = TierError(kind, 'HTTP ${r.status}');
    }
    throw last ?? const TierError('quota', 'mọi key đang nghỉ');
  }

  Future<List<WebResult>> _ddg(String q, int n) async {
    if (!_ready('ddg', '-')) throw const TierError('blocked', 'đang nghỉ');
    WebResponse r;
    try {
      r = await _fetch('GET', Uri.parse('${base('ddg')}/html/').replace(queryParameters: {'q': q}),
          headers: {'User-Agent': kBrowserUa, 'Accept': 'text/html', 'Accept-Language': 'vi,en;q=0.8'}, maxKb: 256, timeoutS: 8);
    } on TierError catch (e) {
      if (e.kind != 'empty') _cool('ddg', '-', 'error');
      rethrow;
    } catch (_) {
      _cool('ddg', '-', 'error');
      throw const TierError('error', 'lỗi mạng');
    }
    if (r.status == 202 || r.status == 403 || r.status == 429) {
      _cool('ddg', '-', 'blocked');
      throw TierError('blocked', 'HTTP ${r.status}');
    }
    if (r.status != 200) {
      _cool('ddg', '-', 'error');
      throw TierError('error', 'HTTP ${r.status}');
    }
    List<WebResult> res;
    try {
      res = parseDdg(_text(r));
    } on TierError {
      _cool('ddg', '-', 'blocked');
      rethrow;
    }
    if (res.isEmpty) throw const TierError('empty', 'không có kết quả');
    _good('ddg', '-');
    return res.take(n).toList();
  }

  Future<List<WebResult>> _searx(String q, int n) async {
    final urls = _searxUrls.where((u) => _ready('searxng', u)).toList();
    if (urls.isEmpty) throw const TierError('empty', 'chưa có/không còn instance SearXNG');
    urls.shuffle();
    for (final u in urls.take(4)) {
      WebResponse r;
      try {
        r = await _fetch('GET', Uri.parse('$u/search').replace(queryParameters: {'q': q, 'format': 'json', 'language': 'vi'}),
            headers: {'Accept': 'application/json'}, maxKb: 256, timeoutS: 8);
      } on TierError catch (e) {
        if (e.kind != 'empty') _cool('searxng', u, 'error');
        continue; // 'empty' = host bị chặn theo chính sách: bỏ qua instance này
      } catch (_) {
        _cool('searxng', u, 'error');
        continue;
      }
      if (r.status != 200 || !r.contentType.toLowerCase().contains('json')) {
        _cool('searxng', u, (r.status == 403 || r.status == 429) ? 'blocked' : 'error'); // nhiều instance công cộng khoá định dạng JSON
        continue;
      }
      try {
        final res = parseSearxng(_obj(_text(r)));
        _good('searxng', u);
        if (res.isNotEmpty) return res.take(n).toList();
      } on TierError {
        _cool('searxng', u, 'error');
      }
    }
    throw const TierError('error', 'SearXNG không trả được kết quả');
  }

  Future<List<WebResult>> _wiki(String q, int n, int chars) async {
    for (final which in ['wikipedia', 'wikipedia_en']) {
      // base tuỳ biến (máy chủ thử/nội bộ): không tự ý hỏi thêm Wikipedia tiếng Anh
      if (which == 'wikipedia_en' && base('wikipedia') != kWebBases['wikipedia']) continue;
      if (!_ready(which, '-')) continue;
      final b = base(which);
      final uri = Uri.parse('$b/w/api.php').replace(queryParameters: {
        'action': 'query',
        'format': 'json',
        'formatversion': '2',
        'generator': 'search',
        'gsrsearch': q,
        'gsrlimit': '1',
        'prop': 'extracts',
        'exintro': '1',
        'explaintext': '1',
        'exchars': '${chars * 2 < 200 ? 200 : chars * 2}',
      });
      WebResponse r;
      try {
        r = await _fetch('GET', uri, maxKb: 128, timeoutS: 8);
      } on TierError catch (e) {
        if (e.kind != 'empty') _cool(which, '-', 'error');
        continue;
      } catch (_) {
        _cool(which, '-', 'error');
        continue;
      }
      if (r.status != 200) {
        _cool(which, '-', 'error');
        continue;
      }
      List pages;
      try {
        final qd = _obj(_text(r))['query'];
        pages = _list(qd is Map ? qd['pages'] : null);
      } on TierError {
        _cool(which, '-', 'error');
        continue;
      }
      if (pages.isNotEmpty && pages.first is Map && _s((pages.first as Map)['extract']).isNotEmpty) {
        final p = pages.first as Map;
        _good(which, '-');
        final title = _s(p['title']);
        return [WebResult(title, '$b/wiki/${Uri.encodeComponent(title.replaceAll(' ', '_'))}', _s(p['extract']))];
      }
    }
    throw const TierError('empty', 'Wikipedia không có bài phù hợp');
  }

  // ---- điều phối ----
  /// Tìm [query]; trả về một chuỗi gọn vừa [chars] ký tự. Không ném lỗi: hết cách thì trả câu báo "không tra được".
  Future<String> search(String query, {int chars = 300, int n = 3}) async {
    final q = query.split(RegExp(r'\s+')).where((x) => x.isNotEmpty).join(' ');
    if (q.isEmpty) throw Exception('thiếu từ khoá');
    final qq = _len(q) > 200 ? _cut(q, 200) : q;
    final ck = '${qq.toLowerCase()}|$chars|${_sig()}';
    final hit = _cache[ck];
    if (hit != null && hit.$1 > nowMs()) return hit.$2;
    final t0 = nowMs();
    final why = <String, String>{};
    for (final tier in order) {
      if (nowMs() - t0 > budget.inMilliseconds) break;
      List<WebResult> res;
      try {
        if (kWebProviders.contains(tier)) {
          res = await _keyed(tier, qq, n);
        } else if (tier == 'ddg') {
          res = await _ddg(qq, n);
        } else if (tier == 'searxng') {
          res = await _searx(qq, n);
        } else if (tier == 'wikipedia') {
          res = await _wiki(qq, n, chars);
        } else if (tier == 'kb') {
          final k = kb;
          final txt = k == null ? null : await k(qq, chars);
          if (txt == null || txt.trim().isEmpty) continue;
          return '(offline) ${_cut(cleanText(txt), chars)}';
        } else {
          continue;
        }
      } on TierError catch (e) {
        if (e.kind != 'empty' || tier == 'wikipedia') why[tier] = e.kind;
        continue;
      } catch (_) {
        why[tier] = 'error';
        continue;
      }
      final txt = fmtResults(res, chars);
      if (txt.isNotEmpty) {
        if (cacheTtl > Duration.zero) {
          if (_cache.length > 200) _cache.clear();
          _cache[ck] = (nowMs() + cacheTtl.inMilliseconds, txt);
        }
        return txt;
      }
    }
    final hint = why.entries.map((e) => '${e.key}:${e.value}').join(', ');
    return 'không tra được trên web lúc này${hint.isEmpty ? '' : ' ($hint)'}, bạn thử lại sau hoặc hỏi mik theo kiến thức sẵn có nha';
  }

  /// Chữ ký cấu hình để đổi key/nguồn thì không dùng nhầm kết quả cũ trong bộ nhớ đệm.
  String _sig() => '${Object.hashAll(kWebProviders.expand((p) => [p, ...(keys[p] ?? const <String>[])]))}|${Object.hashAll(_searxUrls)}|${order.join(',')}|${base('wikipedia')}';
}
