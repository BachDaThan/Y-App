// hub_download_check.dart - kiểm hub_download.dart bằng Dart thuần, máy chủ cục bộ (không cần Flutter, không cần mạng thật).
//   dart tools/hub_download_check.dart
// Mã thoát 0 = tất cả đạt, 1 = có mục hỏng.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../lib/services/hub_download.dart';
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

// sha256 tham chiếu do Python hashlib tính cho dữ liệu byte i -> (i*7+3)&0xff
const Map<int, String> _vec = {
  0: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
  1: '084fed08b978af4d7d196a7446a86b58009e636b611db16211b65a9aadff29c5',
  3: '6ab0dba1f4f1dfbb37b4f9eeb092c09fca4900ad32bdcd147d8dde35d6c87c35',
  55: 'e7313d333c272e639f790978283f9eb392e843d0f29b7016828bb1daa4aac70b',
  56: '4324d65f3c103567f5589c710bc08f8523f929a9272e3af36fc968e52abc6c27',
  57: '35df609437dcfea3279283ab79fd554e2bf78f8f7ae2de532d8ee300b09e8f73',
  63: '81c80242132f230c3bd41b3e63bbcff16107339549214a99614ff26664625055',
  64: '39e3d7b6b5d075d37d053ad89b24b41bef4f3c29760c84447cab3f3be1882241',
  65: 'aacca6ff74fdbb296d165a45cecfa04e5127bc008770fbbdd48006f2d2fae95e',
  119: '9ce7368e4daf32341631b492e80359dc9f594b48453cd0dd5bf0b19279cc177e',
  120: '7836b787757e95e58b3ca5aec90b1b004e8deba1e50e9675af9cabf1a13a04b5',
  121: '1189a98a00c71bc1848ea8bdc9700b442bee0be7c3f45172303f1ab0b6f1617e',
  128: 'd2742f1f4ac6bb7ca2b239ee18402ba8b3f9f8e652d2a72973c2b9ba11c08cf6',
  1000: '1e9bc38cbf860b9ec31918b065f9b52476c549a782e0e7990bed8ce3868d2371',
  65539: '855fa87b029086aa3bb67d2d712d30fa2f0c1f2156c50262b853d9710ebf0868',
};
Uint8List refData(int n) => Uint8List.fromList(List.generate(n, (i) => (i * 7 + 3) & 0xff));

/// Dựng file .yui giả hợp lệ về header (đủ để YuiHeader đọc): v3 có META, v2 không.
Uint8List fakeYui({int ver = 3, String arch = 'amoe-d64-l2-h4-e4-s0-f128', int ctx = 512, int payload = 300000}) {
  final meta = utf8.encode(jsonEncode({'arch_id': arch, 'name': 'thu', 'quant': 'q4', 'params': 1000}));
  final head = ByteData(60);
  head.setUint8(0, 0x59);
  head.setUint8(1, 0x55);
  head.setUint8(2, 0x49);
  head.setUint8(3, 0x31);
  void u(int off, int v) => head.setUint32(off, v, Endian.little);
  u(4, ver);
  u(8, 2);
  u(12, 100);
  u(16, 64);
  u(20, 2);
  u(24, 4);
  u(28, 4);
  u(40, ctx);
  final b = BytesBuilder();
  b.add(head.buffer.asUint8List());
  if (ver == 3) {
    final n = ByteData(4)..setUint32(0, meta.length, Endian.little);
    b.add(n.buffer.asUint8List());
    b.add(meta);
  }
  b.add(Uint8List.fromList(List.generate(payload, (i) => (i * 31 + (i >> 8)) & 0xff)));
  return b.takeBytes();
}

String sha(Uint8List d) => (Sha256()..add(d)).close();

HubModel modelFor(Uint8List file, {int ver = 3, String arch = 'amoe-d64-l2-h4-e4-s0-f128', int ctx = 512, String name = 'thu'}) {
  final m = HubModel.tryParse({
    'id': name,
    'name': name,
    'file': 'sub dir/$name.yui',
    'url': 'https://example.org/$name.yui',
    'bytes': file.length,
    'sha256': sha(file),
    'yui_ver': ver,
    'quant': 'q4',
    'params': 1000,
    'arch_id': arch,
    'tokenizer_sha256': 'b' * 64,
    'domains': ['chat'],
    'lang': ['vi'],
    'license': 'MIT',
    'ctx': ctx,
  }, 'T');
  return m!;
}

HubModel patch(HubModel m, {String? url, int? bytes, String? sha256, String? archId, int? ctx}) => HubModel(
      id: m.id,
      name: m.name,
      file: m.file,
      url: url ?? m.url,
      bytes: bytes ?? m.bytes,
      sha256: sha256 ?? m.sha256,
      yuiVer: m.yuiVer,
      quant: m.quant,
      params: m.params,
      archId: archId ?? m.archId,
      tokenizerSha256: m.tokenizerSha256,
      domains: m.domains,
      lang: m.lang,
      license: m.license,
      ctx: ctx ?? m.ctx,
      description: m.description,
      created: m.created,
      base: m.base,
      sourceName: m.sourceName,
    );

/// Máy chủ thử: phục vụ một file với các kiểu hỏng có điều khiển.
class Srv {
  final Uint8List file;
  late HttpServer server;
  final List<Map<String, String?>> reqs = []; // mỗi yêu cầu: path, range, auth, host
  int dropAfter = -1; // > 0: yêu cầu ĐẦU TIÊN bị cắt sau ngần này byte
  int dropAlways = -1; // >= 0: MỌI yêu cầu bị cắt sau ngần này byte
  bool ignoreRange = false;
  bool range416 = false;
  int extra = 0; // gửi thêm ngần này byte rác (không khai Content-Length)
  int tooMany429 = 0; // số yêu cầu đầu trả 429 + Retry-After: 3
  String? redirectTo; // /r trả 302 tới địa chỉ này
  int slice = 0; // > 0: gửi từng mảnh ngần này byte, nghỉ giữa các mảnh (để thử bấm dừng giữa chừng)
  Srv(this.file);

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final r = req.response;
      reqs.add({'path': req.uri.path, 'range': req.headers.value('range'), 'auth': req.headers.value('authorization'), 'host': req.headers.value('host')});
      if (req.uri.path == '/r') {
        r.statusCode = 302;
        r.headers.set('Location', redirectTo ?? '/f');
        await r.close();
        return;
      }
      if (tooMany429 > 0) {
        tooMany429--;
        r.statusCode = 429;
        r.headers.set('Retry-After', '3');
        await r.close();
        return;
      }
      final total = file.length;
      var start = 0;
      final rg = req.headers.value('range');
      var status = 200;
      if (rg != null && !ignoreRange) {
        if (range416) {
          r.statusCode = 416;
          await r.close();
          return;
        }
        final mm = RegExp(r'bytes=(\d+)-').firstMatch(rg);
        if (mm != null) {
          start = int.parse(mm[1]!);
          status = 206;
          r.headers.set('Content-Range', 'bytes $start-${total - 1}/$total');
        }
      }
      r.statusCode = status;
      final body = file.sublist(start);
      final out = extra > 0 ? Uint8List.fromList([...body, ...List.filled(extra, 7)]) : body;
      if (extra == 0) r.contentLength = body.length;
      var cut = -1;
      if (dropAlways >= 0) {
        cut = dropAlways;
      } else if (dropAfter > 0 && reqs.length == 1) {
        cut = dropAfter;
      }
      if (cut >= 0) {
        r.contentLength = body.length;
        final sock = await r.detachSocket(); // ghi tiêu đề rồi tự viết thân bài dở
        sock.add(out.sublist(0, cut));
        await sock.flush();
        sock.destroy();
        return;
      }
      if (slice > 0) {
        for (var i = 0; i < out.length; i += slice) {
          r.add(out.sublist(i, i + slice > out.length ? out.length : i + slice));
          await r.flush();
          await Future<void>.delayed(const Duration(milliseconds: 3));
        }
        await r.close();
        return;
      }
      r.add(out);
      await r.close();
    });
  }

  String get base => 'http://127.0.0.1:${server.port}';
  Future<void> stop() => server.close(force: true);
}

Future<void> main() async {
  final tmp = await Directory.systemTemp.createTemp('hubdl');
  Directory sub(String n) => Directory('${tmp.path}/$n');
  final sleeps = <Duration>[];
  Future<void> nap(Duration d) async => sleeps.add(d);

  Future<Object?> fails(Future<void> Function() f) async {
    try {
      await f();
      return null;
    } catch (e) {
      return e;
    }
  }

  // ---- SHA-256 ----
  check((Sha256()..add(<int>[])).close() == 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', 'sha256 chuỗi rỗng');
  check((Sha256()..add(utf8.encode('abc'))).close() == 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', 'sha256 "abc"');
  check((Sha256()..add(utf8.encode('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'))).close() == '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      'sha256 vector 2 khối');
  {
    final h = Sha256();
    final a = Uint8List.fromList(List.filled(1000, 0x61));
    for (var i = 0; i < 1000; i++) {
      h.add(a);
    }
    check(h.close() == 'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0', 'sha256 một triệu chữ a');
  }
  for (final e in _vec.entries) {
    check(sha(refData(e.key)) == e.value, 'sha256 độ dài ${e.key} khớp Python');
    final d = refData(e.key);
    for (final step in [1, 7, 63, 64, 65]) {
      final h = Sha256();
      for (var i = 0; i < d.length; i += step) {
        h.add(d.sublist(i, i + step > d.length ? d.length : i + step));
      }
      check(h.close() == e.value, 'sha256 độ dài ${e.key} cắt mảnh $step byte');
    }
  }

  // ---- kiểm cấu hình ----
  check(parseArchId('amoe-d64-l2-h4-e4-s0-f128')?.d == 64 && parseArchId('amoe-d64-l2-h4-e4-s0-f128')?.e == 4, 'parseArchId đúng dạng');
  check(parseArchId('amoe-d64') == null && parseArchId('x') == null && parseArchId('amoe-d6a-l2-h4-e4-s0-f128') == null, 'parseArchId sai dạng -> null');
  {
    final m = modelFor(fakeYui());
    check(hubFileName(m) == 'thu.yui', 'hubFileName lấy tên cuối');
    check(hubFileName(patch(m)) == 'thu.yui', 'hubFileName ổn định');
  }

  final v3 = fakeYui();
  final v2 = fakeYui(ver: 2);
  final m3 = modelFor(v3);

  // 1) tải bình thường (v3), có tiến độ
  {
    final s = Srv(v3);
    await s.start();
    final d = sub('t1');
    var last = 0;
    var total = 0;
    final f = await hubDownload(patch(m3, url: '${s.base}/f'), dir: d, destName: 'thu.yui', allowInsecure: true, sleep: nap, onProgress: (a, b) {
      last = a;
      total = b;
    });
    check(await f.exists() && sha(await f.readAsBytes()) == m3.sha256, '1: file đúng sha256');
    check(last == v3.length && total == v3.length, '1: tiến độ tới 100%');
    check(!d.listSync().any((e) => e.path.endsWith('.part')), '1: không còn file .part');
    check(s.reqs.length == 1 && s.reqs[0]['range'] == null, '1: một yêu cầu, không Range');
    await s.stop();
  }
  // 2) đứt mạng giữa chừng -> tự tải tiếp bằng Range
  {
    sleeps.clear();
    final s = Srv(v3)..dropAfter = 100000;
    await s.start();
    final f = await hubDownload(patch(m3, url: '${s.base}/f'), dir: sub('t2'), destName: 'thu.yui', allowInsecure: true, sleep: nap);
    check(sha(await f.readAsBytes()) == m3.sha256, '2: tải xong đúng sha256 sau khi đứt');
    check(s.reqs.length == 2 && s.reqs[1]['range'] != null && s.reqs[1]['range']!.startsWith('bytes=') && s.reqs[1]['range'] != 'bytes=0-', '2: lần 2 gửi Range (${s.reqs.map((e) => e['range'])})');
    final startAt = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(s.reqs[1]['range']!)![1]!);
    check(startAt > 0 && startAt <= 100000, '2: tiếp tục từ byte đã nhận ($startAt)');
    check(sleeps.length == 1 && sleeps[0] == const Duration(seconds: 1), '2: chờ 1s rồi thử lại');
    await s.stop();
  }
  // 3) bấm dừng rồi tải tiếp ở lần gọi sau
  {
    final d = sub('t3');
    final s = Srv(v3)..slice = 20000;
    await s.start();
    final c = HubCancel();
    final e = await fails(() => hubDownload(patch(m3, url: '${s.base}/f'), dir: d, destName: 'thu.yui', allowInsecure: true, cancel: c, sleep: nap, onProgress: (a, b) {
          if (a > 0) c.cancel();
        }));
    check(e is HubCancelled, '3: bấm dừng ném HubCancelled ($e)');
    final part = d.listSync().whereType<File>().where((x) => x.path.endsWith('.part')).toList();
    final have = part.isEmpty ? 0 : part.first.lengthSync();
    check(part.length == 1 && have > 0 && have < v3.length, '3: giữ file dở ($have/${v3.length})');
    s.reqs.clear();
    final f = await hubDownload(patch(m3, url: '${s.base}/f'), dir: d, destName: 'thu.yui', allowInsecure: true, sleep: nap);
    check(sha(await f.readAsBytes()) == m3.sha256, '3: tải tiếp xong đúng sha256');
    check(s.reqs.length == 1 && s.reqs[0]['range'] == 'bytes=$have-', '3: chỉ xin phần còn lại (${s.reqs.map((e) => e['range'])})');
    await s.stop();
  }
  // 4) máy chủ bỏ qua Range (trả 200 cả file) -> ghi đè từ đầu
  {
    final d = sub('t4')..createSync(recursive: true);
    File('${d.path}/hub_${m3.sha256.substring(0, 16)}.part').writeAsBytesSync(v3.sublist(0, 1000));
    final s = Srv(v3)..ignoreRange = true;
    await s.start();
    final f = await hubDownload(patch(m3, url: '${s.base}/f'), dir: d, destName: 'thu.yui', allowInsecure: true, sleep: nap);
    check(sha(await f.readAsBytes()) == m3.sha256 && s.reqs.length == 1 && s.reqs[0]['range'] == 'bytes=1000-', '4: bỏ qua Range vẫn ra file đúng');
    await s.stop();
  }
  // 5) 416 -> bỏ phần dở, tải lại từ đầu
  {
    final d = sub('t5')..createSync(recursive: true);
    File('${d.path}/hub_${m3.sha256.substring(0, 16)}.part').writeAsBytesSync(v3.sublist(0, 500));
    final s = Srv(v3)..range416 = true;
    await s.start();
    final f = await hubDownload(patch(m3, url: '${s.base}/f'), dir: d, destName: 'thu.yui', allowInsecure: true, sleep: nap);
    check(sha(await f.readAsBytes()) == m3.sha256 && s.reqs.length == 2 && s.reqs[1]['range'] == null, '5: 416 thì tải lại từ đầu');
    await s.stop();
  }
  // 6) sai sha256 -> xoá hết, không tạo file .yui
  {
    final d = sub('t6');
    final s = Srv(v3);
    await s.start();
    final bad = patch(m3, url: '${s.base}/f', sha256: 'c' * 64);
    final e = await fails(() => hubDownload(bad, dir: d, destName: 'thu.yui', allowInsecure: true, sleep: nap));
    check(e is HubDownloadException && '$e'.contains('sha256'), '6: sai sha256 bị từ chối ($e)');
    check(d.listSync().isEmpty, '6: xoá sạch file dở, không có .yui');
    await s.stop();
  }
  // 7) trần dung lượng: từ chối TRƯỚC khi tải
  {
    final s = Srv(v3);
    await s.start();
    final e = await fails(() => hubDownload(patch(m3, url: '${s.base}/f'), dir: sub('t7'), destName: 'thu.yui', allowInsecure: true, maxBytes: 100000, sleep: nap));
    check(e is HubDownloadException && '$e'.contains('trần') && s.reqs.isEmpty, '7: vượt trần bị từ chối, chưa gọi mạng ($e)');
    final e2 = await fails(() => hubDownload(patch(m3, url: '${s.base}/f', bytes: kHubMaxModelBytes + 1), dir: sub('t7b'), destName: 'thu.yui', allowInsecure: true, sleep: nap));
    check(e2 is HubDownloadException && s.reqs.isEmpty, '7: trần tuyệt đối 2 GB vẫn áp dụng dù maxBytes không đặt');
    await s.stop();
  }
  // 8) máy chủ gửi thừa byte so với khai báo
  {
    final d = sub('t8');
    final s = Srv(v3)..extra = 500;
    await s.start();
    final e = await fails(() => hubDownload(patch(m3, url: '${s.base}/f'), dir: d, destName: 'thu.yui', allowInsecure: true, sleep: nap));
    check(e is HubDownloadException && '$e'.contains('nhiều byte'), '8: gửi thừa byte bị chặn ($e)');
    check(d.listSync().isEmpty, '8: xoá file dở');
    await s.stop();
  }
  // 9) Content-Length khác manifest
  {
    final d = sub('t9');
    final s = Srv(v3);
    await s.start();
    final e = await fails(() => hubDownload(patch(m3, url: '${s.base}/f', bytes: v3.length + 5), dir: d, destName: 'thu.yui', allowInsecure: true, sleep: nap));
    check(e is HubDownloadException && '$e'.contains('không khớp'), '9: kích thước khác manifest bị từ chối ($e)');
    check(d.listSync().isEmpty, '9: không để lại file');
    await s.stop();
  }
  // 10) sai cấu hình: arch_id / ctx / META
  {
    final s = Srv(v3);
    await s.start();
    for (final (label, mm) in [
      ('arch d khác', patch(m3, url: '${s.base}/f', archId: 'amoe-d99-l2-h4-e4-s0-f128')),
      ('arch l khác', patch(m3, url: '${s.base}/f', archId: 'amoe-d64-l9-h4-e4-s0-f128')),
      ('arch e khác', patch(m3, url: '${s.base}/f', archId: 'amoe-d64-l2-h4-e8-s0-f128')),
      ('META arch_id khác (cùng d/l/h/e)', patch(m3, url: '${s.base}/f', archId: 'amoe-d64-l2-h4-e4-s1-f999')),
      ('ctx khác', patch(m3, url: '${s.base}/f', ctx: 1024)),
      ('arch sai dạng', patch(m3, url: '${s.base}/f', archId: 'lạ')),
    ]) {
      final d = sub('t10_${label.hashCode}');
      final e = await fails(() => hubDownload(mm, dir: d, destName: 'thu.yui', allowInsecure: true, sleep: nap));
      check(e is HubDownloadException && '$e'.contains('manifest') && '$e'.contains('xoá'), '10: $label bị từ chối ($e)');
      check(!d.existsSync() || d.listSync().isEmpty, '10: $label xoá sạch');
    }
    await s.stop();
  }
  // 11) file v2 (không META) tải được khi arch_id khớp header
  {
    final s = Srv(v2);
    await s.start();
    final m2 = modelFor(v2, ver: 2, name: 'cu');
    final f = await hubDownload(patch(m2, url: '${s.base}/f'), dir: sub('t11'), destName: 'cu.yui', allowInsecure: true, sleep: nap);
    check(await f.exists(), '11: v2 không META vẫn tải được');
    await s.stop();
  }
  // 12) 429 -> chờ theo Retry-After rồi thử lại
  {
    sleeps.clear();
    final s = Srv(v3)..tooMany429 = 2;
    await s.start();
    final f = await hubDownload(patch(m3, url: '${s.base}/f'), dir: sub('t12'), destName: 'thu.yui', allowInsecure: true, sleep: nap);
    check(await f.exists() && sleeps.length == 2 && sleeps.every((x) => x == const Duration(seconds: 3)), '12: 429 chờ Retry-After 3s hai lần (${sleeps.length})');
    await s.stop();
  }
  // 13) hết số lần thử: báo lỗi tiếng Việt, giữ file dở
  {
    sleeps.clear();
    final d = sub('t13');
    final s = Srv(v3)..dropAlways = 5000;
    await s.start();
    final e = await fails(() => hubDownload(patch(m3, url: '${s.base}/f'), dir: d, destName: 'thu.yui', allowInsecure: true, sleep: nap));
    check(e is HubDownloadException && '$e'.contains('giữ lại') && s.reqs.length == kHubDlMaxAttempts, '13: hết lần thử sau ${s.reqs.length} yêu cầu ($e)');
    check(sleeps.length == kHubDlMaxAttempts - 1 && sleeps.last == const Duration(seconds: 4), '13: lùi dần 1s,2s,4s');
    check(d.listSync().whereType<File>().any((x) => x.path.endsWith('.part')) && !File('${d.path}/thu.yui').existsSync(), '13: giữ file dở, không có .yui');
    await s.stop();
  }
  // 14) chuyển hướng: đi theo; token chỉ gửi tới máy chủ gốc
  {
    final s = Srv(v3);
    await s.start();
    s.redirectTo = 'http://localhost:${s.server.port}/f';
    final f = await hubDownload(patch(m3, url: '${s.base}/r'), dir: sub('t14'), destName: 'thu.yui', allowInsecure: true, token: 'SECRET', sleep: nap);
    check(await f.exists() && s.reqs.length == 2, '14: đi theo chuyển hướng');
    check(s.reqs[0]['auth'] == 'Bearer SECRET', '14: gửi token tới máy chủ gốc');
    check(s.reqs[1]['auth'] == null, '14: KHÔNG gửi token sang máy chủ khác (${s.reqs[1]['host']})');
    await s.stop();
  }
  // 15) link http bị chặn khi không bật allowInsecure; file đích có sẵn bị từ chối
  {
    final s = Srv(v3);
    await s.start();
    final e = await fails(() => hubDownload(patch(m3, url: '${s.base}/f'), dir: sub('t15'), destName: 'thu.yui', sleep: nap));
    check(e is HubDownloadException && '$e'.contains('https') && s.reqs.isEmpty, '15: link http bị chặn, chưa gọi mạng ($e)');
    final d = sub('t15b')..createSync(recursive: true);
    File('${d.path}/thu.yui').writeAsStringSync('x');
    final e2 = await fails(() => hubDownload(patch(m3, url: '${s.base}/f'), dir: d, destName: 'thu.yui', allowInsecure: true, sleep: nap));
    check(e2 is HubDownloadException && '$e2'.contains('Đã có') && s.reqs.isEmpty, '15: không ghi đè file đã có');
    await s.stop();
  }
  // 16) file dở của bản khác (sha khác) không bị nối nhầm
  {
    final d = sub('t16')..createSync(recursive: true);
    final other = modelFor(fakeYui(payload: 1000), name: 'khac');
    File('${d.path}/hub_${other.sha256.substring(0, 16)}.part').writeAsBytesSync(List.filled(50, 1));
    final s = Srv(v3);
    await s.start();
    final f = await hubDownload(patch(m3, url: '${s.base}/f'), dir: d, destName: 'thu.yui', allowInsecure: true, sleep: nap);
    check(await f.exists() && s.reqs.length == 1 && s.reqs[0]['range'] == null, '16: file dở của bản khác không dùng lại');
    check(File('${d.path}/hub_${other.sha256.substring(0, 16)}.part').existsSync(), '16: không đụng file dở của bản khác');
    await s.stop();
  }
  // 17) file dở lớn hơn khai báo -> bỏ
  {
    final d = sub('t17')..createSync(recursive: true);
    File('${d.path}/hub_${m3.sha256.substring(0, 16)}.part').writeAsBytesSync(Uint8List(v3.length + 10));
    final s = Srv(v3);
    await s.start();
    final f = await hubDownload(patch(m3, url: '${s.base}/f'), dir: d, destName: 'thu.yui', allowInsecure: true, sleep: nap);
    check(sha(await f.readAsBytes()) == m3.sha256 && s.reqs[0]['range'] == null, '17: file dở quá khổ bị bỏ, tải lại từ đầu');
    await s.stop();
  }

  await tmp.delete(recursive: true);
  stdout.writeln(_fail == 0 ? 'ĐẠT: $_pass kiểm tra' : 'CÓ $_fail KIỂM TRA HỎNG ($_pass đạt)');
  exit(_fail == 0 ? 0 : 1);
}
