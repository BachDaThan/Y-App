// hub_service_check.dart - kiểm hub_service.dart bằng Dart thuần (không cần Flutter, không cần mạng thật).
//   dart run tools/hub_service_check.dart [đường dẫn manifest.json do make_manifest.py sinh]
// Có đối số thứ nhất: kiểm thêm việc Dart đọc đúng manifest do Python sinh. Mã thoát 0 = tất cả đạt, 1 = có mục hỏng.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../lib/services/hub_service.dart';

int _fail = 0, _pass = 0;
void check(bool ok, String what) {
  if (ok) {
    _pass++;
  } else {
    _fail++;
    stderr.writeln('HỎNG: $what');
  }
}

String sha(String c) => List.filled(64, c).join();

Map<String, dynamic> entry(String id, {Map<String, dynamic>? over}) => {
      'id': id,
      'name': id,
      'file': '$id.yui',
      'url': 'https://huggingface.co/u/r/resolve/main/$id.yui',
      'bytes': 1000,
      'sha256': sha('a'),
      'yui_ver': 3,
      'quant': 'q4',
      'params': 5000,
      'arch_id': 'amoe-d64-l2-h4-e4-s0-f128',
      'tokenizer_sha256': sha('b'),
      'domains': ['chat'],
      'lang': ['vi'],
      'license': 'MIT',
      'ctx': 512,
      ...?over,
    };

String manifest(List<Object?> models, {int version = 1}) =>
    jsonEncode({'manifest_version': version, 'generated': '2026-11-13', 'base_url': 'https://x/', 'models': models});

const A = HubSource('A', 'https://a.example/manifest.json');
const B = HubSource('B', 'https://b.example/manifest.json');

Future<void> main(List<String> args) async {
  final tmp = await Directory.systemTemp.createTemp('hubcheck');
  var clock = 1000000000000;
  final sleeps = <Duration>[];
  Future<void> fakeSleep(Duration d) async => sleeps.add(d);

  HubService svc(Directory d, HubFetch f) => HubService(d, fetch: f, now: () => clock, sleep: fakeSleep);
  Directory sub(String n) => Directory('${tmp.path}/$n');

  // 1) hai nguồn -> gộp theo thứ tự, gắn tên nguồn
  {
    final calls = <String>[];
    final s = svc(sub('t1'), (u) async {
      calls.add(u.host);
      return u.host == 'a.example' ? manifest([entry('m1'), entry('m2')]) : manifest([entry('m3')]);
    });
    final r = await s.load([A, B]);
    check(r.models.map((m) => m.id).join(',') == 'm1,m2,m3', '1: gộp 2 nguồn đúng thứ tự');
    check(r.models[0].sourceName == 'A' && r.models[2].sourceName == 'B', '1: gắn tên nguồn');
    check(r.statuses.every((x) => x.ok && !x.fromCache) && r.anyOk && !r.allFailed, '1: trạng thái');
  }
  // 2) một nguồn lỗi không làm hỏng nguồn kia
  {
    final s = svc(sub('t2'), (u) async => u.host == 'a.example' ? manifest([entry('m1')]) : throw const HubHttpException(404));
    final r = await s.load([A, B]);
    check(r.models.length == 1 && r.statuses[0].ok && !r.statuses[1].ok, '2: nguồn B lỗi, A vẫn dùng được');
    check((r.statuses[1].error ?? '').contains('404') && sleeps.isEmpty, '2: 404 không thử lại, có thông báo');
  }
  // 3) cache 24 giờ
  {
    var n = 0;
    final d = sub('t3');
    final s = svc(d, (u) async {
      n++;
      return manifest([entry('m1')]);
    });
    await s.load([A]);
    clock += 23 * 3600 * 1000;
    final r2 = await s.load([A]);
    check(n == 1 && r2.statuses[0].fromCache && !r2.statuses[0].stale && r2.models.length == 1, '3: trong 24 giờ dùng cache, không gọi mạng');
    clock += 2 * 3600 * 1000;
    final r3 = await s.load([A]);
    check(n == 2 && !r3.statuses[0].fromCache, '3: quá 24 giờ thì tải mới');
    await s.load([A], force: true);
    check(n == 3, '3: force bỏ qua cache còn hạn');
    clock -= 10 * 24 * 3600 * 1000; // đồng hồ chạy lùi -> coi như hết hạn
    await s.load([A]);
    check(n == 4, '3: đồng hồ lùi thì không tin cache');
  }
  // 4) mất mạng: dùng cache cũ, đánh dấu stale; không có cache thì báo lỗi
  {
    final d = sub('t4');
    await svc(d, (u) async => manifest([entry('m1')])).load([A]);
    clock += 3 * 24 * 3600 * 1000;
    final off = svc(d, (u) async => throw const SocketException('x'));
    final r = await off.load([A]);
    check(r.models.length == 1 && r.statuses[0].ok && r.statuses[0].stale && r.statuses[0].fromCache, '4: mất mạng dùng cache cũ');
    check((r.statuses[0].error ?? '').contains('mạng'), '4: có lý do tiếng Việt');
    final r2 = await off.load([B]);
    check(r2.allFailed && r2.models.isEmpty && r2.statuses[0].error != null, '4: không cache thì báo lỗi, không ném');
  }
  // 5) thử lại khi 429 / 5xx, theo Retry-After, tối đa 3 lần
  {
    sleeps.clear();
    var n = 0;
    final s = svc(sub('t5'), (u) async {
      n++;
      if (n == 1) throw const HubHttpException(429, retryAfter: Duration(seconds: 5));
      if (n == 2) throw const HubHttpException(503);
      return manifest([entry('m1')]);
    });
    final r = await s.load([A]);
    check(r.models.length == 1 && n == 3, '5: thành công ở lần thứ 3');
    check(sleeps.length == 2 && sleeps[0] == const Duration(seconds: 5) && sleeps[1] == const Duration(seconds: 2), '5: chờ theo Retry-After rồi lùi dần');
    n = 0;
    final s2 = svc(sub('t5b'), (u) async {
      n++;
      throw const HubHttpException(429);
    });
    final r2 = await s2.load([A]);
    check(n == kHubMaxAttempts && r2.allFailed && r2.statuses[0].error!.contains('429'), '5: quá 3 lần thì bỏ cuộc');
  }
  // 6) mục sai bị bỏ qua, mục đúng giữ lại
  {
    final bad = <Object?>[
      entry('ok1'),
      entry('badsha', over: {'sha256': 'ABC'}),
      entry('http', over: {'url': 'http://x.org/a.yui'}),
      entry('exe', over: {'url': 'https://x.org/a.exe'}),
      entry('dotdot', over: {'file': '../a.yui'}),
      entry('abs', over: {'file': '/a.yui'}),
      entry('cred', over: {'url': 'https://u:p@x.org/a.yui'}),
      entry('zero', over: {'bytes': 0}),
      entry('huge', over: {'bytes': kHubMaxModelBytes + 1}),
      entry('float', over: {'bytes': 10.5}),
      entry('ver9', over: {'yui_ver': 9}),
      entry('dom', over: {'domains': 'chat'}),
      entry('badid', over: {'id': 'a b'}),
      entry('date', over: {'created': '2026-13-45x'}),
      'không phải map',
      null,
      entry('ok1'), // trùng id trong cùng manifest
      entry('ok2', over: {'description': 'x' * 400, 'name': 'Tên\u0007lạ'}),
    ];
    final m = HubManifest.parse(manifest(bad), 'A');
    check(m.models.map((e) => e.id).join(',') == 'ok1,ok2', '6: chỉ giữ mục hợp lệ (${m.models.map((e) => e.id)})');
    check(m.skipped == bad.length - 2, '6: đếm đúng số mục bị bỏ (${m.skipped})');
    check(m.models[1].description.length == 300 && m.models[1].name == 'Tên lạ', '6: cắt mô tả, làm sạch ký tự điều khiển');
  }
  // 7) sai cấu trúc -> từ chối cả manifest
  for (final (label, body) in [
    ('không phải JSON', 'xin chào'),
    ('mảng gốc', '[]'),
    ('phiên bản 2', manifest([entry('a')], version: 2)),
    ('models không phải mảng', jsonEncode({'manifest_version': 1, 'models': 'x'})),
    ('quá nhiều mục', manifest(List.generate(kHubMaxModels + 1, (i) => entry('m$i')))),
  ]) {
    var threw = false;
    try {
      HubManifest.parse(body, 'A');
    } on HubFormatException {
      threw = true;
    }
    check(threw, '7: từ chối $label');
  }
  // 8) trùng id giữa các nguồn: nguồn đứng trước thắng
  {
    final s = svc(sub('t8'), (u) async => u.host == 'a.example' ? manifest([entry('x', over: {'name': 'từ A'})]) : manifest([entry('x', over: {'name': 'từ B'}), entry('y')]));
    final r = await s.load([A, B]);
    check(r.models.length == 2 && r.models[0].name == 'từ A' && r.notes.length == 1, '8: trùng id giữa nguồn');
  }
  // 9) link nguồn không an toàn bị từ chối, không gọi mạng
  {
    var n = 0;
    final s = svc(sub('t9'), (u) async {
      n++;
      return manifest([entry('m')]);
    });
    final r = await s.load([const HubSource('http', 'http://a.example/m.json'), const HubSource('cred', 'https://u:p@a.example/m.json'), const HubSource('rác', 'không phải url')]);
    check(n == 0 && r.allFailed && r.statuses.every((x) => x.error != null), '9: nguồn không https bị chặn, không gọi mạng');
  }
  // 10) cache hỏng / của link khác bị bỏ qua
  {
    final d = sub('t10');
    await svc(d, (u) async => manifest([entry('m1')])).load([A]);
    for (final f in d.listSync().whereType<File>()) {
      f.writeAsStringSync('{hỏng');
    }
    var n = 0;
    final r = await svc(d, (u) async {
      n++;
      return manifest([entry('m1')]);
    }).load([A]);
    check(n == 1 && r.models.length == 1, '10: cache hỏng thì tải lại');
    final f0 = d.listSync().whereType<File>().first;
    final j = jsonDecode(f0.readAsStringSync()) as Map;
    j['url'] = 'https://khac.example/m.json';
    f0.writeAsStringSync(jsonEncode(j));
    n = 0;
    await svc(d, (u) async {
      n++;
      return manifest([entry('m1')]);
    }).load([A]);
    check(n == 1, '10: cache ghi cho link khác không được dùng');
  }
  // 11) defaultHubFetch với máy chủ cục bộ: 200, 429 + Retry-After, quá lớn, chuyển hướng sang http
  {
    final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    srv.listen((req) async {
      final p = req.uri.path;
      if (p == '/ok') {
        req.response.write(manifest([entry('m1')]));
      } else if (p == '/429') {
        req.response.statusCode = 429;
        req.response.headers.set('Retry-After', '7');
      } else if (p == '/429big') {
        req.response.statusCode = 429;
        req.response.headers.set('Retry-After', '9999');
      } else if (p == '/big') {
        req.response.write('x' * (kHubMaxManifestBytes + 10));
      } else if (p == '/redir') {
        req.response.statusCode = 302;
        req.response.headers.set('Location', '/ok');
      }
      await req.response.close();
    });
    final base = 'http://127.0.0.1:${srv.port}';
    final body = await defaultHubFetch(Uri.parse('$base/ok'));
    check(HubManifest.parse(body, 'L').models.length == 1, '11: tải 200 và đọc được');
    try {
      await defaultHubFetch(Uri.parse('$base/429'));
      check(false, '11: 429 phải ném');
    } on HubHttpException catch (e) {
      check(e.status == 429 && e.retryAfter == const Duration(seconds: 7) && e.retryable, '11: 429 kèm Retry-After 7s');
    }
    try {
      await defaultHubFetch(Uri.parse('$base/429big'));
    } on HubHttpException catch (e) {
      check(e.retryAfter == const Duration(seconds: 30), '11: Retry-After bị chặn ở 30s');
    }
    try {
      await defaultHubFetch(Uri.parse('$base/big'));
      check(false, '11: quá lớn phải ném');
    } on HubFormatException {
      check(true, '');
    }
    try {
      await defaultHubFetch(Uri.parse('$base/redir'));
      check(false, '11: chuyển hướng sang http phải bị chặn');
    } on HubFormatException catch (e) {
      check(e.message.contains('https'), '11: chặn chuyển hướng sang http');
    }
    await srv.close(force: true);
  }
  // 12) đọc manifest do make_manifest.py sinh (Python -> Dart)
  if (args.isNotEmpty) {
    final body = await File(args[0]).readAsString();
    final m = HubManifest.parse(body, 'py');
    final j = jsonDecode(body) as Map;
    final n = (j['models'] as List).length;
    check(m.skipped == 0 && m.models.length == n && n > 0, '12: Dart đọc đủ $n mục do Python sinh, bỏ ${m.skipped}');
    check(m.models.any((e) => e.url.contains('%20')), '12: giữ nguyên link đã mã hoá %20');
    stdout.writeln('   Python -> Dart: ${m.models.map((e) => '${e.id}[${e.quant},${e.domains.join("/")}]').join(', ')}');
  }

  await tmp.delete(recursive: true);
  stdout.writeln(_fail == 0 ? 'ĐẠT: $_pass kiểm tra' : 'CÓ $_fail KIỂM TRA HỎNG ($_pass đạt)');
  exit(_fail == 0 ? 0 : 1);
}
