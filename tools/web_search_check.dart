// web_search_check.dart - kiểm web_search.dart bằng Dart thuần với MÁY CHỦ GIẢ cục bộ (không cần Flutter, không cần mạng thật, không cần key thật).
//   dart tools/web_search_check.dart
// Mã thoát 0 = tất cả đạt, 1 = có mục hỏng.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../lib/agent.dart';
import '../lib/services/web_search.dart';

int _fail = 0, _pass = 0;
void check(bool ok, String what) {
  if (ok) {
    _pass++;
  } else {
    _fail++;
    stderr.writeln('HỎNG: $what');
  }
}

class Req {
  final String method, path, query, body;
  final Map<String, String> h;
  Req(this.method, this.path, this.query, this.body, this.h);
  Map<String, dynamic> get json => jsonDecode(body) as Map<String, dynamic>;
  Map<String, String> get qp => Uri.splitQueryString(query);
}

typedef Reply = (int status, String type, String body, Map<String, String> headers);
Reply ok(Object j) => (200, 'application/json', j is String ? j : jsonEncode(j), const {});
Reply st(int s) => (s, 'text/plain', '', const {});

class Fake {
  late HttpServer srv;
  final List<Req> reqs = [];
  final Map<String, Reply Function(Req)> routes = {};
  String get base => 'http://127.0.0.1:${srv.port}';
  Future<void> start() async {
    srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    srv.listen((r) async {
      final body = await utf8.decoder.bind(r).join();
      final h = <String, String>{};
      r.headers.forEach((k, v) => h[k.toLowerCase()] = v.join(','));
      final q = Req(r.method, r.uri.path, r.uri.query, body, h);
      reqs.add(q);
      final fn = routes[r.uri.path];
      final (s, t, b, hh) = fn == null ? st(404) : fn(q);
      r.response.statusCode = s;
      r.response.headers.set('content-type', t);
      hh.forEach((k, v) => r.response.headers.set(k, v));
      r.response.add(utf8.encode(b));
      await r.response.close();
    });
  }

  Future<void> stop() => srv.close(force: true);
  List<Req> to(String path) => reqs.where((x) => x.path == path).toList();
}

const ddgHtml = '''
<html><body>
<div class="result"><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fvi.example.org%2Fhanoi&amp;rut=abc">Hà Nội &amp; vùng phụ cận</a>
<a class="result__snippet" href="x">Hà Nội là <b>thủ đô</b> của Việt Nam.</a></div>
<div class="result"><a class="result__a" href="https://other.example.com/page">Trang khác</a>
<a class="result__snippet" href="x">Đoạn trích thứ hai.</a></div>
</body></html>''';

Future<void> main() async {
  var clock = 1000000000000;
  int now() => clock;
  final f = Fake();
  await f.start();
  Map<String, String> allBases() => {for (final k in kWebBases.keys) k: f.base};
  WebSearch mk({Map<String, List<String>> keys = const {}, List<String> searx = const [], List<String>? order, Duration ttl = const Duration(minutes: 10), WebHttp? http, int? budgetS, Future<String?> Function(String, int)? kb}) =>
      WebSearch(
        keys: keys,
        searxng: searx,
        order: order,
        bases: allBases(),
        nowMs: now,
        allowInsecure: true,
        isPublic: (_) => true, // chỉ cho test chức năng; phần chặn SSRF thử riêng bằng isPublicAddress thật
        cacheTtl: ttl,
        http: http ?? defaultWebHttp,
        budget: Duration(seconds: budgetS ?? 25),
        kb: kb,
      );
  void reset() {
    f.reqs.clear();
    f.routes.clear();
  }

  // ===== phân tích từng dịch vụ (parser) =====
  {
    final t = parseTavily({'results': [{'title': 'T', 'url': 'https://a.org/x', 'content': 'nội dung'}, 'rác', {'title': 'chỉ tiêu đề'}, 5]});
    check(t.length == 2 && t[0].snippet == 'nội dung' && t[1].url == '', 'parseTavily bỏ mục không phải map');
    check(parseExa({'results': [{'title': 'a', 'url': 'u', 'text': 'T'}, {'title': 'b', 'summary': 'S'}, {'title': 'c', 'highlights': ['H1', 'H2']}, {'title': 'd'}]}).map((e) => e.snippet).join(',') == 'T,S,H1,', 'parseExa text>summary>highlights');
    check(parseLinkup({'results': [{'name': 'N', 'url': 'u', 'content': 'C'}, {'title': 'T2', 'snippet': 'S2'}]}).map((e) => '${e.title}/${e.snippet}').join(',') == 'N/C,T2/S2', 'parseLinkup name|title, content|snippet');
    check(parseFirecrawl({'data': {'web': [{'title': 'a', 'description': 'D'}, {'title': 'b', 'markdown': 'M' * 900}]}}).map((e) => e.snippet.length).join(',') == '1,600', 'parseFirecrawl (data.web, cắt markdown 600)');
    check(parseFirecrawl({'data': [{'title': 'a', 'description': 'D'}]}).length == 1, 'parseFirecrawl (data là mảng)');
    check(parseSearxng({'results': [{'title': 'a', 'url': 'u', 'content': 'c'}]}).first.snippet == 'c', 'parseSearxng');
    check(parseBraveApi({'web': {'results': [{'title': 'a', 'url': 'u', 'description': 'd'}]}}).first.snippet == 'd' && parseBraveApi({}).isEmpty, 'parseBraveApi');
    check(parseGcse({'items': [{'title': 'a', 'link': 'L', 'snippet': 's'}]}).first.url == 'L' && parseGcse({'x': 1}).isEmpty, 'parseGcse (link -> url)');
    final d = parseDdg(ddgHtml);
    check(d.length == 2 && d[0].url == 'https://vi.example.org/hanoi' && d[0].title == 'Hà Nội & vùng phụ cận' && d[0].snippet == 'Hà Nội là thủ đô của Việt Nam.', 'parseDdg giải link uddg, bỏ thẻ, giải mã &amp;');
    check(d[1].url == 'https://other.example.com/page' && d[1].snippet == 'Đoạn trích thứ hai.', 'parseDdg link thường');
    var blocked = false;
    try {
      parseDdg('<html>Unusual traffic from your network. captcha</html>');
    } on TierError catch (e) {
      blocked = e.kind == 'blocked';
    }
    check(blocked, 'parseDdg nhận ra trang xác minh');
    check(parseDdg('<html>không có gì</html>').isEmpty, 'parseDdg trang trống');
  }
  // ===== định dạng =====
  {
    check(cleanText('<p>A &amp; B&nbsp;&#8211; &#x4e2d; &bogus; &#99999999;</p>') == 'A & B – 中 &bogus; &#99999999;', 'cleanText bỏ thẻ, giải mã thực thể, giữ nguyên thực thể lạ/sai');
    final r = fmtResults([WebResult('t', 'https://www.a.org/x', 'Đoạn một ' * 5), WebResult('t2', 'https://b.org', 'Đoạn hai')], 120);
    check(r.runes.length <= 120 && r.contains('(a.org)') && r.contains(' | '), 'fmtResults vừa ngân sách, có nguồn, bỏ www (${r.runes.length})');
    check(fmtResults([WebResult('t', '', 'x' * 500)], 100).runes.length <= 100 && fmtResults([WebResult('', '', '')], 100) == '', 'fmtResults cắt dài, bỏ mục rỗng');
    check(fmtResults([WebResult('tiêu đề', '', '')], 100) == 'tiêu đề', 'fmtResults dùng tiêu đề khi không có đoạn trích');
  }
  // ===== địa chỉ công cộng (SSRF) =====
  {
    final pub = ['8.8.8.8', '1.1.1.1', '93.184.216.34', '172.32.0.1', '172.15.255.255', '100.128.0.1', '100.63.255.255', '2606:4700::1111', '::ffff:8.8.8.8'];
    final priv = [
      '127.0.0.1', '127.255.255.254', '10.0.0.1', '172.16.0.1', '172.31.255.255', '192.168.1.1', '169.254.169.254', '100.64.0.1', '100.127.255.255',
      '0.0.0.0', '224.0.0.1', '255.255.255.255', '192.0.0.5', '198.18.0.1', '::1', '::', 'fe80::1', 'fc00::1', 'fd12:3456::1', 'ff02::1', '::ffff:127.0.0.1', '::ffff:10.0.0.1', '2001:db8::1'
    ];
    for (final a in pub) {
      check(isPublicAddress(InternetAddress(a)), 'isPublicAddress: $a là công cộng');
    }
    for (final a in priv) {
      check(!isPublicAddress(InternetAddress(a)), 'isPublicAddress: $a bị chặn');
    }
  }
  // ===== cấu hình người dùng =====
  {
    final c = WebConfig.parse('''
# ghi chú
Tavily = k1, k2;k1
exa=e1
gcse=AIza:cx1
searxng=https://a.example/, http://b.example, https://u:p@c.example, https://d.example
foo=bar
khong co dau bang
''');
    check(c.keys['tavily']!.join(',') == 'k1,k2' && c.keys['exa']!.first == 'e1' && c.keys['gcse']!.first == 'AIza:cx1', 'WebConfig: key (không phân biệt hoa/thường, tách dấu phẩy/;/khoảng trắng, bỏ trùng)');
    check(c.searxng.join(',') == 'https://a.example,https://d.example', 'WebConfig: searxng chỉ nhận https, không userinfo, bỏ "/" cuối (${c.searxng})');
    check(c.problems.length == 4 && c.problems.any((p) => p.contains('foo')) && c.problems.any((p) => p.contains('http://b.example')), 'WebConfig báo dòng sai (${c.problems.length})');
    check(WebConfig.parse('').keys.isEmpty && WebConfig.empty.searxng.isEmpty, 'WebConfig rỗng');
  }

  // ===== các tầng có key: hình dạng yêu cầu + kết quả =====
  {
    reset();
    f.routes['/search'] = (r) => ok({'results': [{'title': 'Hà Nội', 'url': 'https://vi.example.org/hn', 'content': 'Hà Nội là thủ đô của Việt Nam.'}]});
    final w = mk(keys: {'tavily': ['tvly-KEY1']}, order: ['tavily']);
    final out = await w.search('thủ đô Việt Nam', chars: 120);
    final q = f.to('/search').single;
    check(out == 'Hà Nội là thủ đô của Việt Nam. (vi.example.org)', 'tavily: kết quả đã định dạng ($out)');
    check(q.method == 'POST' && q.h['authorization'] == 'Bearer tvly-KEY1' && q.json['query'] == 'thủ đô Việt Nam' && q.json['max_results'] == 3 && q.json['search_depth'] == 'basic', 'tavily: POST + Bearer + thân JSON đúng');
    check(q.h['content-type']!.startsWith('application/json'), 'tavily: Content-Type JSON');
  }
  {
    reset();
    f.routes['/search'] = (r) => ok({'results': [{'title': 'E', 'url': 'https://e.example/x', 'text': 'Nội dung exa'}]});
    final out = await mk(keys: {'exa': ['EXA1']}, order: ['exa']).search('xin chào');
    final q = f.to('/search').single;
    check(out.startsWith('Nội dung exa') && q.h['x-api-key'] == 'EXA1' && q.json['numResults'] == 3 && (q.json['contents'] as Map)['text']['maxCharacters'] == 600 && !q.h.containsKey('authorization'), 'exa: x-api-key + numResults + contents.text');
  }
  {
    reset();
    f.routes['/v1/search'] = (r) => r.json.containsKey('q') ? ok({'results': [{'name': 'L', 'url': 'https://l.example', 'content': 'Linkup nói vậy'}]}) : ok({'data': {'web': [{'title': 'F', 'url': 'https://f.example', 'description': 'Firecrawl nói vậy'}]}});
    final a = await mk(keys: {'linkup': ['LK']}, order: ['linkup']).search('câu hỏi một');
    final b = await mk(keys: {'firecrawl': ['FC']}, order: ['firecrawl']).search('câu hỏi hai');
    final rs = f.to('/v1/search');
    check(a.startsWith('Linkup nói vậy') && rs[0].json['depth'] == 'standard' && rs[0].json['outputType'] == 'searchResults' && rs[0].h['authorization'] == 'Bearer LK', 'linkup: thân + Bearer');
    check(b.startsWith('Firecrawl nói vậy') && rs[1].json['limit'] == 3 && rs[1].json['query'] == 'câu hỏi hai' && rs[1].h['authorization'] == 'Bearer FC', 'firecrawl: thân + Bearer');
  }
  {
    reset();
    f.routes['/res/v1/web/search'] = (r) => ok({'web': {'results': [{'title': 'B', 'url': 'https://b.example', 'description': 'Brave nói vậy'}]}});
    f.routes['/customsearch/v1'] = (r) => ok({'items': [{'title': 'G', 'link': 'https://g.example', 'snippet': 'Google nói vậy'}]});
    final a = await mk(keys: {'braveapi': ['BR']}, order: ['braveapi']).search('một hai');
    final b = await mk(keys: {'gcse': ['AIza123:cx456']}, order: ['gcse']).search('ba bốn');
    final q1 = f.to('/res/v1/web/search').single, q2 = f.to('/customsearch/v1').single;
    check(a.startsWith('Brave nói vậy') && q1.method == 'GET' && q1.h['x-subscription-token'] == 'BR' && q1.qp['q'] == 'một hai' && q1.qp['count'] == '3', 'braveapi: GET + X-Subscription-Token + q/count');
    check(b.startsWith('Google nói vậy') && q2.qp['key'] == 'AIza123' && q2.qp['cx'] == 'cx456' && q2.qp['q'] == 'ba bốn' && q2.qp['num'] == '3', 'gcse: tách KHOÁ:CX thành key và cx');
  }
  // ===== xoay vòng + nghỉ key =====
  {
    reset();
    f.routes['/search'] = (r) => ok({'results': [{'title': 't', 'url': 'https://x.example', 'content': 'kq ${r.h['authorization']}'}]});
    final w = mk(keys: {'tavily': ['K1', 'K2', 'K3']}, order: ['tavily']);
    for (final q in ['một', 'hai', 'ba', 'bốn']) {
      await w.search(q);
    }
    check(f.to('/search').map((r) => r.h['authorization']!.substring(7)).join(',') == 'K1,K2,K3,K1', 'xoay vòng key: K1,K2,K3,K1');
  }
  {
    reset();
    var n = 0;
    f.routes['/search'] = (r) {
      n++;
      return r.h['authorization'] == 'Bearer BAD' ? st(429) : ok({'results': [{'title': 't', 'url': 'https://x.example', 'content': 'tốt'}]});
    };
    final w = mk(keys: {'tavily': ['BAD', 'GOOD']}, order: ['tavily']);
    check((await w.search('a1')).startsWith('tốt') && n == 2, 'key bị 429 thì thử key kế trong cùng lần tìm');
    check(w.coolStatus().length == 1 && w.coolStatus().keys.first == 'tavily:BAD…' && w.coolStatus().values.first >= 59, 'key 429 nghỉ ≥ 60 giây, trạng thái che key (${w.coolStatus()})');
    f.reqs.clear();
    await w.search('a2');
    await w.search('a3');
    check(f.to('/search').every((r) => r.h['authorization'] == 'Bearer GOOD'), 'đang nghỉ thì không gọi lại key lỗi');
    clock += 61 * 1000;
    f.reqs.clear();
    await w.search('a4');
    await w.search('a5');
    check(f.to('/search').any((r) => r.h['authorization'] == 'Bearer BAD'), 'hết giờ nghỉ thì thử lại key lỗi');
  }
  {
    reset();
    f.routes['/search'] = (r) => st(401);
    final w = mk(keys: {'tavily': ['AUTHBAD']}, order: ['tavily']);
    await w.search('b1');
    f.reqs.clear();
    clock += 5 * 3600 * 1000;
    await w.search('b2');
    check(f.reqs.isEmpty, 'key sai (401) nghỉ 6 giờ: sau 5 giờ vẫn chưa gọi lại');
    clock += 2 * 3600 * 1000;
    await w.search('b3');
    check(f.reqs.length == 1, 'sau 6 giờ mới thử lại');
  }
  // ===== rơi xuống tầng sau =====
  {
    reset();
    f.routes['/search'] = (r) => r.method == 'POST' && r.h.containsKey('x-api-key') ? ok({'results': [{'title': 'E', 'url': 'https://e.example', 'text': 'exa cứu'}]}) : st(500);
    final out = await mk(keys: {'tavily': ['T'], 'exa': ['E']}, order: ['tavily', 'exa', 'wikipedia']).search('rơi tầng');
    check(out.startsWith('exa cứu') && f.to('/search').length == 2, 'tavily lỗi 5xx -> sang exa');
  }
  // ===== DuckDuckGo =====
  {
    reset();
    f.routes['/html/'] = (r) => (200, 'text/html', ddgHtml, const {});
    final w = mk(order: ['ddg']);
    final out = await w.search('thủ đô', chars: 200);
    final q = f.to('/html/').single;
    check(out.contains('Hà Nội là thủ đô của Việt Nam. (vi.example.org)') && out.contains('Đoạn trích thứ hai. (other.example.com)'), 'ddg: đọc 2 kết quả, ghi nguồn ($out)');
    check(q.qp['q'] == 'thủ đô' && q.h['user-agent']!.contains('Mozilla') && q.h['accept']!.contains('text/html'), 'ddg: gửi q + User-Agent trình duyệt');
  }
  {
    reset();
    f.routes['/html/'] = (r) => st(202);
    f.routes['/w/api.php'] = (r) => ok({'query': {'pages': [{'title': 'Việt Nam', 'extract': 'Việt Nam là một quốc gia.'}]}});
    final w = mk(order: ['ddg', 'wikipedia']);
    final out = await w.search('việt nam', chars: 150);
    check(out.startsWith('Việt Nam là một quốc gia.') && out.contains('/wiki/') == false && f.to('/html/').length == 1, 'ddg bị chặn 202 -> sang Wikipedia');
    await w.search('việt nam 2', chars: 150);
    check(f.to('/html/').length == 1, 'ddg nghỉ sau khi bị chặn: không gọi lại ngay');
    clock += 121 * 1000;
    await w.search('việt nam 3', chars: 150);
    check(f.to('/html/').length == 2, 'ddg được thử lại sau 120 giây');
  }
  {
    reset();
    f.routes['/html/'] = (r) => (200, 'text/html', '<html>Unusual traffic. captcha</html>', const {});
    final w = mk(order: ['ddg']);
    final out = await w.search('xác minh');
    check(out.contains('không tra được') && out.contains('ddg:blocked') && w.coolStatus().containsKey('ddg:-'), 'ddg trang xác minh -> blocked + nghỉ');
  }
  // ===== SearXNG =====
  {
    reset();
    f.routes['/a/search'] = (r) => (403, 'text/html', 'cấm', const {});
    f.routes['/b/search'] = (r) => (200, 'text/html', '<html>không phải json</html>', const {});
    f.routes['/c/search'] = (r) => ok({'results': [{'title': 'S', 'url': 'https://s.example/p', 'content': 'SearXNG trả lời'}]});
    f.routes['/d/search'] = (r) => (200, 'text/html', jsonEncode({'results': [{'title': 'X', 'url': 'https://x.example', 'content': 'JSON gắn nhãn HTML'}]}), const {});
    final w = mk(searx: ['${f.base}/a', '${f.base}/b', '${f.base}/d', '${f.base}/c'], order: ['searxng']);
    final out = await w.search('thử searx');
    final qc = f.to('/c/search').single;
    check(out.startsWith('SearXNG trả lời') && !out.contains('gắn nhãn HTML'), 'searxng: bỏ instance lỗi và instance trả nhãn không phải JSON, dùng instance JSON ($out)');
    check(qc.qp['format'] == 'json' && qc.qp['language'] == 'vi' && qc.qp['q'] == 'thử searx', 'searxng: gửi format=json, language=vi');
    // instance được thử theo thứ tự xáo trộn nên chỉ những instance ĐÃ bị gọi (và lỗi) ở lần đầu mới đang nghỉ
    final failedBefore = ['a', 'b', 'd'].where((x) => f.to('/$x/search').isNotEmpty).toList();
    f.reqs.clear();
    await w.search('thử searx 2');
    check(failedBefore.every((x) => f.to('/$x/search').isEmpty) && f.to('/c/search').length == 1, 'searxng: instance đã lỗi đang nghỉ, không bị gọi lại (${failedBefore.join(',')})');
    check(w.coolStatus().keys.every((k) => k.startsWith('searxng:127.0.0.1')), 'trạng thái nghỉ SearXNG chỉ hiện tên miền');
  }
  {
    reset();
    final w = mk(searx: ['${f.base}/x'], order: ['searxng', 'wikipedia']);
    f.routes['/x/search'] = (r) => st(500);
    check((await w.search('hỏng hết')).contains('không tra được'), 'searxng và wikipedia đều hỏng -> câu báo, không ném lỗi');
  }
  // ===== Wikipedia =====
  {
    reset();
    f.routes['/w/api.php'] = (r) => ok({'query': {'pages': [{'title': 'Hà Nội', 'extract': 'Hà Nội là thủ đô.'}]}});
    final w = mk(order: ['wikipedia']);
    final out = await w.search('hà nội', chars: 120);
    final q = f.to('/w/api.php').single;
    check(out == 'Hà Nội là thủ đô. (127.0.0.1)' && q.qp['gsrsearch'] == 'hà nội' && q.qp['generator'] == 'search' && q.qp['exchars'] == '240', 'wikipedia: tham số + định dạng ($out)');
    reset();
    f.routes['/w/api.php'] = (r) => ok({'query': {'pages': []}});
    final out2 = await mk(order: ['wikipedia']).search('không có bài');
    check(out2.contains('wikipedia:empty') && f.to('/w/api.php').length == 1, 'wikipedia không có bài: báo hint, base tuỳ biến thì không hỏi thêm bản tiếng Anh');
  }
  // ===== không bao giờ câm / hint / bí mật =====
  {
    reset();
    f.routes['/search'] = (r) => st(500);
    f.routes['/html/'] = (r) => st(500);
    final w = mk(keys: {'tavily': ['SUPERSECRETKEY']}, order: ['tavily', 'ddg', 'wikipedia']);
    final out = await w.search('tất cả hỏng');
    check(out.startsWith('không tra được trên web lúc này') && out.contains('tavily:error') && out.contains('ddg:error'), 'hết tầng: câu báo kèm tầng nào lỗi ($out)');
    check(!out.contains('SUPERSECRET') && !w.coolStatus().keys.any((k) => k.contains('SUPERSECRET')), 'key không lộ trong kết quả/trạng thái');
  }
  // ===== bộ nhớ đệm =====
  {
    reset();
    f.routes['/w/api.php'] = (r) => ok({'query': {'pages': [{'title': 'A', 'extract': 'đáp án'}]}});
    final w = mk(order: ['wikipedia']);
    await w.search('Cache Test');
    await w.search('cache   test');
    check(f.to('/w/api.php').length == 1, 'cache: cùng câu hỏi (khác hoa/thường/khoảng trắng) không gọi lại');
    await w.search('cache test', chars: 80);
    check(f.to('/w/api.php').length == 2, 'cache: khác ngân sách ký tự thì tìm lại');
    clock += 11 * 60 * 1000;
    await w.search('cache test');
    check(f.to('/w/api.php').length == 3, 'cache hết hạn sau 10 phút');
    final w2 = mk(order: ['wikipedia'], ttl: Duration.zero);
    f.reqs.clear();
    await w2.search('x1');
    await w2.search('x1');
    check(f.to('/w/api.php').length == 2, 'ttl = 0 tắt cache');
  }
  // ===== ngân sách thời gian, truy vấn, tầng lạ, kb =====
  {
    reset();
    var calls = 0;
    final w = WebSearch(
      keys: {'tavily': ['A'], 'exa': ['B'], 'linkup': ['C']},
      order: ['tavily', 'exa', 'linkup'],
      bases: allBases(),
      nowMs: now,
      allowInsecure: true,
      budget: const Duration(seconds: 25),
      http: (m, u, {body, headers, maxKb = 128, timeoutS = 8}) async {
        calls++;
        clock += 30 * 1000; // mỗi lần gọi "tốn" 30 giây
        return WebResponse(500, 'text/plain', Uint8List(0));
      },
    );
    final out = await w.search('quá giờ');
    check(calls == 1 && out.contains('không tra được'), 'quá ngân sách thời gian thì dừng (đã gọi $calls tầng)');
  }
  {
    reset();
    f.routes['/w/api.php'] = (r) => ok({'query': {'pages': [{'title': 'A', 'extract': 'ok'}]}});
    final w = mk(order: ['tầng_lạ', 'wikipedia']);
    check((await w.search('a')).startsWith('ok'), 'tên tầng lạ bị bỏ qua');
    Object? e;
    try {
      await w.search('   ');
    } catch (x) {
      e = x;
    }
    check(e != null && '$e'.contains('thiếu từ khoá'), 'truy vấn rỗng -> lỗi rõ ràng');
    f.reqs.clear();
    await w.search('x' * 500);
    check(f.to('/w/api.php').single.qp['gsrsearch']!.runes.length == 200, 'truy vấn dài bị cắt còn 200 ký tự');
  }
  {
    reset();
    f.routes['/w/api.php'] = (r) => st(500);
    final out = await mk(order: ['wikipedia', 'kb'], kb: (q, c) async => 'ghi chú riêng về $q').search('mất mạng');
    check(out == '(offline) ghi chú riêng về mất mạng', 'tầng kb cá nhân là điểm tựa cuối ($out)');
  }
  // ===== chính sách mạng: SSRF / chuyển hướng =====
  {
    reset();
    f.routes['/start'] = (r) => (302, 'text/plain', '', {'location': 'http://localhost:${f.srv.port}/secret'});
    f.routes['/secret'] = (r) => ok({'results': []});
    final w = mk(keys: {'tavily': ['K']}, order: ['tavily']);
    try {
      await w.search('x'); // /search chưa có route -> 404; chỉ để khởi tạo
    } catch (_) {}
    // chuyển hướng sang host lạ (localhost không nằm trong danh sách) phải bị chặn
    final ws = WebSearch(keys: {'tavily': ['K']}, order: ['tavily'], bases: {...allBases(), 'tavily': '${f.base}/start-base'}, nowMs: now, allowInsecure: true);
    f.reqs.clear();
    f.routes['/start-base/search'] = (r) => (302, 'text/plain', '', {'location': 'http://localhost:${f.srv.port}/secret'});
    final out = await ws.search('chuyển hướng');
    check(f.to('/secret').isEmpty && out.contains('không tra được'), 'chuyển hướng sang host ngoài danh sách bị chặn (không gọi /secret)');
  }
  {
    reset();
    f.routes['/loop/search'] = (r) => (302, 'text/plain', '', {'location': '${f.base}/loop/search'});
    final ws = WebSearch(keys: {'tavily': ['K']}, order: ['tavily'], bases: {...allBases(), 'tavily': '${f.base}/loop'}, nowMs: now, allowInsecure: true);
    final out = await ws.search('vòng lặp');
    check(f.to('/loop/search').length == kWebMaxRedirects + 1 && out.contains('không tra được'), 'chuyển hướng vô hạn dừng sau $kWebMaxRedirects lần (${f.to('/loop/search').length} yêu cầu)');
  }
  {
    reset();
    f.routes['/hop/search'] = (r) => r.method == 'POST' ? (307, 'text/plain', '', {'location': '${f.base}/hop2/search'}) : st(500);
    f.routes['/hop2/search'] = (r) => ok({'results': [{'title': 't', 'url': 'https://x.example', 'content': 'qua 307'}]});
    final ws = WebSearch(keys: {'tavily': ['K']}, order: ['tavily'], bases: {...allBases(), 'tavily': '${f.base}/hop'}, nowMs: now, allowInsecure: true);
    final out = await ws.search('chuyển 307');
    final h2 = f.to('/hop2/search').single;
    check(out.startsWith('qua 307') && h2.method == 'POST' && h2.h['authorization'] == 'Bearer K' && h2.json['query'] == 'chuyển 307', '307 giữ nguyên POST + thân + tiêu đề (chỉ trong host cho phép)');
  }
  {
    // host SearXNG người dùng nhập: chính sách THẬT (isPublicAddress)
    final probes = <String>[];
    Future<List<InternetAddress>> res(String h) async {
      probes.add(h);
      switch (h) {
        case 'noi-bo.example':
          return [InternetAddress('192.168.1.5')];
        case 'tron.example':
          return [InternetAddress('8.8.8.8'), InternetAddress('10.0.0.9')];
        case 'cong.example':
          return [InternetAddress('93.184.216.34')];
        default:
          throw const SocketException('không phân giải được');
      }
    }

    var net = 0;
    Future<WebResponse> fake(String m, Uri u, {String? body, Map<String, String>? headers, int maxKb = 128, int timeoutS = 8}) async {
      net++;
      return WebResponse(200, 'application/json', Uint8List.fromList(utf8.encode(jsonEncode({'results': [{'title': 'x', 'url': 'https://y.example', 'content': 'qua cổng'}]}))));
    }

    WebSearch sx(List<String> urls) => WebSearch(searxng: urls, order: ['searxng'], nowMs: now, resolve: res, http: fake);
    for (final u in ['https://localhost', 'https://127.0.0.1', 'https://[::1]', 'https://10.0.0.5', 'https://169.254.169.254', 'https://noi-bo.example', 'https://tron.example', 'https://khong-ton-tai.example']) {
      net = 0;
      final out = await sx([u]).search('chặn ${u.hashCode}');
      check(net == 0 && out.contains('không tra được'), 'SearXNG $u bị chặn, chưa gọi mạng');
    }
    net = 0;
    check((await sx(['https://cong.example']).search('được phép')).startsWith('qua cổng') && net == 1, 'SearXNG host công cộng được phép');
    net = 0;
    check((await sx(['http://cong.example']).search('không https')).contains('không tra được') && net == 0, 'SearXNG http:// bị bỏ qua khi không bật allowInsecure');
    net = 0;
    await sx(['https://u:p@cong.example']).search('có userinfo');
    check(net == 0, 'link có tài khoản/mật khẩu bị chặn');
    // chuyển hướng từ host SearXNG hợp lệ sang host công cộng KHÔNG nằm trong danh sách: chặn
    var hops = 0;
    final w = WebSearch(
      searxng: ['https://cong.example'],
      order: ['searxng'],
      nowMs: now,
      resolve: res,
      http: (m, u, {body, headers, maxKb = 128, timeoutS = 8}) async {
        hops++;
        return WebResponse(302, '', Uint8List(0), 'https://khac.example/x');
      },
    );
    await w.search('đổi hướng');
    check(hops == 1, 'chuyển hướng sang host ngoài danh sách bị chặn ở bước kế (chỉ $hops lần gọi)');
  }

  // ===== defaultWebHttp: giới hạn dung lượng, không tự chuyển hướng, POST JSON =====
  {
    reset();
    f.routes['/big'] = (r) => (200, 'text/plain', 'x' * 3000000, const {});
    f.routes['/redir'] = (r) => (302, 'text/plain', '', {'location': '/elsewhere'});
    f.routes['/echo'] = (r) => ok({'m': r.method, 'ct': r.h['content-type'], 'body': r.body});
    final big = await defaultWebHttp('GET', Uri.parse('${f.base}/big'), maxKb: 64);
    check(big.status == 200 && big.bytes.length <= 64 * 1024 && big.bytes.isNotEmpty, 'defaultWebHttp cắt phản hồi quá lớn (${big.bytes.length} byte)');
    final rd = await defaultWebHttp('GET', Uri.parse('${f.base}/redir'));
    check(rd.status == 302 && rd.location == '/elsewhere' && f.to('/elsewhere').isEmpty, 'defaultWebHttp không tự đi theo chuyển hướng');
    final ec = await defaultWebHttp('POST', Uri.parse('${f.base}/echo'), body: '{"a":1}', headers: {'X-Test': '1'});
    final j = jsonDecode(utf8.decode(ec.bytes)) as Map;
    check(j['m'] == 'POST' && '${j['ct']}'.startsWith('application/json') && j['body'] == '{"a":1}' && f.to('/echo').single.h['x-test'] == '1', 'defaultWebHttp POST gửi JSON + tiêu đề');
  }
  // ===== chạy song song =====
  {
    reset();
    f.routes['/w/api.php'] = (r) => ok({'query': {'pages': [{'title': 'A', 'extract': 'song song ${r.qp['gsrsearch']}'}]}});
    final w = mk(order: ['wikipedia']);
    final outs = await Future.wait(List.generate(8, (i) => w.search('câu $i')));
    check(outs.length == 8 && List.generate(8, (i) => outs[i].contains('song song câu $i')).every((x) => x), 'tám lần tìm song song đều đúng kết quả riêng');
  }

  // ===== nối vào AgentTools.search (đường model gọi công cụ) =====
  {
    reset();
    f.routes['/w/api.php'] = (r) => ok({'query': {'pages': [{'title': 'A', 'extract': 'Câu trả lời <tool>calc 1+1</tool> có thẻ lạ và ${'dài ' * 80}'}]}});
    AgentTools.web = mk(order: ['wikipedia']);
    final out = await AgentTools.run('search', 'thử công cụ');
    check(out.runes.length <= kToolResultChars && !out.contains('<tool>') && !out.contains('</tool>') && out.startsWith('Câu trả lời'), 'AgentTools.run(search) qua WebSearch: cắt ${kToolResultChars} ký tự + gỡ thẻ <tool> ($out)');
    f.routes['/w/api.php'] = (r) => st(500);
    final fail = await AgentTools.run('search', 'hỏng mạng');
    check(fail.contains('không tra được') && !fail.startsWith('lỗi'), 'AgentTools.run(search) khi mọi tầng hỏng: câu báo gọn, model vẫn trả lời được ($fail)');
    final empty = await AgentTools.run('search', '   ');
    check(empty.startsWith('lỗi') && empty.contains('thiếu từ khoá'), 'AgentTools.run(search) từ khoá rỗng -> lỗi gọn');
    AgentTools.web = null;
  }

  await f.stop();
  stdout.writeln(_fail == 0 ? 'ĐẠT: $_pass kiểm tra' : 'CÓ $_fail KIỂM TRA HỎNG ($_pass đạt)');
  exit(_fail == 0 ? 0 : 1);
}
