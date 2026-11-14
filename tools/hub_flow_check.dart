// hub_flow_check.dart - kiểm CẢ DÒNG tải model từ Kho đúng như AppState.downloadHubModel làm:
// hubDownload -> HubCache.record -> HubCache.trim (bảo vệ model vừa tải/đang chạy/đang chọn), dùng máy chủ cục bộ.
//   dart tools/hub_flow_check.dart
import 'dart:io';
import 'dart:typed_data';

import '../lib/services/hub_cache.dart';
import '../lib/services/hub_download.dart';
import 'hub_download_check.dart' show Srv, fakeYui, modelFor, patch;

int _fail = 0, _pass = 0;
void check(bool ok, String what) {
  if (ok) {
    _pass++;
  } else {
    _fail++;
    stderr.writeln('HỎNG: $what');
  }
}

Future<void> main() async {
  final tmp = await Directory.systemTemp.createTemp('hubflow');
  final dir = Directory('${tmp.path}/models')..createSync();
  var clock = 1000000000000;
  final cache = HubCache(dir, now: () => clock += 1000);
  const cap = 250000;
  String? loaded, active;
  Future<void> nap(Duration d) async {}

  // người dùng tự nhập một model lớn: không bao giờ được đụng tới
  File('${dir.path}/mine.yui').writeAsBytesSync(Uint8List(500000));

  /// Bản sao đúng trình tự của AppState.downloadHubModel (không có phần giao diện).
  Future<List<String>> flow(Uint8List bytes, String name, {String? sha, int? maxBytes}) async {
    final base = modelFor(bytes, name: name);
    final srv = Srv(bytes);
    await srv.start();
    try {
      final m = patch(base, url: '${srv.base}/f', sha256: sha);
      final f = await hubDownload(m, dir: dir, destName: '$name.yui', allowInsecure: true, sleep: nap, maxBytes: (maxBytes == null || maxBytes > cap) ? cap : maxBytes);
      await cache.record(m, '$name.yui', await f.length());
      final gone = await cache.trim(cap, protected: {'$name.yui', if (loaded != null) loaded, if (active != null) active});
      return gone.map((e) => e.name).toList();
    } finally {
      await srv.stop();
    }
  }

  bool has(String n) => File('${dir.path}/$n').existsSync();
  Future<int> total() => cache.totalBytes();

  final a = fakeYui(payload: 100000), b = fakeYui(payload: 120000, ctx: 512), c = fakeYui(payload: 90000), d = fakeYui(payload: 100000, ctx: 512), e = fakeYui(payload: 200000);
  // làm cho 5 file khác nhau (khác sha) dù cùng cấu hình
  for (final (i, x) in [a, b, c, d, e].indexed) {
    x[x.length - 1] = i + 1;
  }

  var gone = await flow(a, 'a');
  check(gone.isEmpty && has('a.yui'), '1: tải A, chưa vượt trần');
  gone = await flow(b, 'b');
  check(gone.isEmpty && has('a.yui') && has('b.yui'), '2: tải B, tổng ≈ 220 KB ≤ trần');
  gone = await flow(c, 'c');
  check(gone.join(',') == 'a.yui' && !has('a.yui') && has('b.yui') && has('c.yui'), '3: tải C vượt trần -> xoá A (cũ nhất) ($gone)');
  check(has('mine.yui') && File('${dir.path}/mine.yui').lengthSync() == 500000, '3: file tự nhập 500 KB không bị đụng dù vượt trần');

  await cache.touch('b.yui'); // người dùng nạp B -> B "mới" hơn C
  gone = await flow(d, 'd');
  check(gone.join(',') == 'c.yui' && has('b.yui') && has('d.yui') && !has('c.yui'), '4: nạp B làm B mới hơn -> xoá C chứ không xoá B ($gone)');

  loaded = 'b.yui';
  active = 'b.yui';
  gone = await flow(e, 'e');
  check(has('b.yui') && has('e.yui') && !has('d.yui') && gone.join(',') == 'd.yui', '5: B đang chạy được bảo vệ, E vừa tải được bảo vệ, xoá D ($gone)');
  check((await total()) == b.length + e.length && (await total()) > cap, '5: còn lại toàn model được bảo vệ nên tạm vượt trần (đúng thiết kế)');

  // tải hỏng (sai sha256): không ghi sổ, không xoá model nào
  final before = (await cache.entries()).map((x) => x.name).toSet();
  final f0 = fakeYui(payload: 50000)..[100] = 99;
  Object? err;
  try {
    await flow(f0, 'f', sha: 'c' * 64);
  } catch (ex) {
    err = ex;
  }
  check(err is HubDownloadException && !has('f.yui'), '6: tải hỏng bị từ chối ($err)');
  check(before.containsAll({'b.yui', 'e.yui'}) && (await cache.entries()).map((x) => x.name).toSet().containsAll(before) && has('b.yui') && has('e.yui'), '6: tải hỏng không làm mất model cũ');

  // model lớn hơn cả trần: từ chối trước khi tải
  err = null;
  try {
    await flow(fakeYui(payload: 300000), 'big');
  } catch (ex) {
    err = ex;
  }
  check(err is HubDownloadException && '$err'.contains('trần') && !has('big.yui'), '7: model lớn hơn trần bị từ chối ($err)');

  // người dùng xoá B bằng tay (ModelStore.delete -> forget): không còn trong sổ
  File('${dir.path}/b.yui').deleteSync();
  await cache.forget('b.yui');
  check(!(await cache.entries()).any((x) => x.name == 'b.yui') && has('mine.yui'), '8: xoá tay rồi forget, sổ gọn');

  await tmp.delete(recursive: true);
  stdout.writeln(_fail == 0 ? 'ĐẠT: $_pass kiểm tra' : 'CÓ $_fail KIỂM TRA HỎNG ($_pass đạt)');
  exit(_fail == 0 ? 0 : 1);
}
