// hub_cache_check.dart - kiểm hub_cache.dart bằng Dart thuần (không cần Flutter).
//   dart tools/hub_cache_check.dart
// Mã thoát 0 = tất cả đạt, 1 = có mục hỏng.
import 'dart:convert';
import 'dart:io';

import '../lib/services/hub_cache.dart';
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

HubModel model(String id, {String source = 'Yui-Models'}) => HubModel.tryParse({
      'id': id,
      'name': id,
      'file': '$id.yui',
      'url': 'https://example.org/$id.yui',
      'bytes': 1000,
      'sha256': 'a' * 64,
      'yui_ver': 3,
      'quant': 'q4',
      'params': 1000,
      'arch_id': 'amoe-d64-l2-h4-e4-s0-f128',
      'tokenizer_sha256': 'b' * 64,
      'domains': ['chat'],
      'lang': ['vi'],
      'license': 'MIT',
      'ctx': 512,
    }, source)!;

Future<void> main() async {
  final tmp = await Directory.systemTemp.createTemp('hubcache');
  var clock = 1000000000000;
  int tick() => clock += 1000; // mỗi lần gọi now() đi tới 1 giây để thứ tự thời gian rõ ràng

  Future<(Directory, HubCache)> fresh(String n) async {
    final d = Directory('${tmp.path}/$n')..createSync(recursive: true);
    return (d, HubCache(d, now: tick));
  }

  void put(Directory d, String name, int bytes) => File('${d.path}/$name').writeAsBytesSync(List.filled(bytes, 1));
  bool has(Directory d, String name) => File('${d.path}/$name').existsSync();

  // 1) ghi nhận + tổng dung lượng
  {
    final (d, c) = await fresh('t1');
    for (final n in ['a', 'b', 'c']) {
      put(d, '$n.yui', 100);
      await c.record(model(n), '$n.yui', 100);
    }
    check((await c.totalBytes()) == 300 && (await c.entries()).length == 3, '1: tổng 300 byte, 3 mục');
    check((await c.entries()).first.source == 'Yui-Models', '1: lưu tên nguồn');
  }
  // 2) xoá ít dùng nhất trước; nạp model (touch) làm nó "mới"; dừng ngay khi đủ trần
  {
    final (d, c) = await fresh('t2');
    for (final n in ['a', 'b', 'c']) {
      put(d, '$n.yui', 100);
      await c.record(model(n), '$n.yui', 100);
    }
    await c.touch('a.yui'); // a vừa dùng -> thứ tự cũ nhất: b, c, a
    final gone = await c.trim(250);
    check(gone.map((e) => e.name).join(',') == 'b.yui' && !has(d, 'b.yui') && has(d, 'a.yui') && has(d, 'c.yui'), '2: xoá b (cũ nhất), giữ a vừa dùng');
    final gone2 = await c.trim(150);
    check(gone2.map((e) => e.name).join(',') == 'c.yui' && has(d, 'a.yui'), '2: lần sau xoá c, còn a');
    check((await c.trim(1000)).isEmpty, '2: dưới trần thì không xoá gì');
  }
  // 3) model được bảo vệ không bao giờ bị xoá, dù cũ nhất; chỉ còn model bảo vệ thì dừng
  {
    final (d, c) = await fresh('t3');
    for (final n in ['a', 'b', 'c']) {
      put(d, '$n.yui', 100);
      await c.record(model(n), '$n.yui', 100);
    }
    final gone = await c.trim(100, protected: {'a.yui'}); // a cũ nhất nhưng được bảo vệ
    check(gone.map((e) => e.name).join(',') == 'b.yui,c.yui' && has(d, 'a.yui'), '3: bảo vệ a (cũ nhất), xoá b rồi c');
    final gone2 = await c.trim(0, protected: {'a.yui'});
    check(gone2.isEmpty && has(d, 'a.yui') && (await c.totalBytes()) == 100, '3: chỉ còn model bảo vệ thì dừng, vẫn vượt trần');
  }
  // 4) file người dùng tự nhập (không có trong sổ) không bao giờ bị xoá
  {
    final (d, c) = await fresh('t4');
    put(d, 'cua_toi.yui', 5000);
    put(d, 'tai_link.yui', 7000);
    put(d, 'k.yui', 100);
    await c.record(model('k'), 'k.yui', 100);
    final gone = await c.trim(0);
    check(gone.map((e) => e.name).join(',') == 'k.yui' && has(d, 'cua_toi.yui') && has(d, 'tai_link.yui') && !has(d, 'k.yui'), '4: chỉ xoá model của Kho, file tự nhập còn nguyên');
  }
  // 5) file bị thay (khác dung lượng) hoặc mất: bỏ khỏi sổ, KHÔNG xoá
  {
    final (d, c) = await fresh('t5');
    put(d, 'x.yui', 100);
    put(d, 'y.yui', 100);
    await c.record(model('x'), 'x.yui', 100);
    await c.record(model('y'), 'y.yui', 100);
    put(d, 'x.yui', 333); // người dùng ghi đè bằng file khác
    File('${d.path}/y.yui').deleteSync();
    final gone = await c.trim(0);
    check(gone.isEmpty && has(d, 'x.yui') && File('${d.path}/x.yui').lengthSync() == 333, '5: file đã bị thay thì không xoá');
    check((await c.entries()).isEmpty, '5: sổ tự dọn mục lệch/mất');
  }
  // 6) forget chỉ bỏ khỏi sổ, không đụng file; sau đó không bị xoá tự động
  {
    final (d, c) = await fresh('t6');
    put(d, 'a.yui', 100);
    await c.record(model('a'), 'a.yui', 100);
    await c.forget('a.yui');
    await c.forget('khong_co.yui'); // không ném lỗi
    check((await c.entries()).isEmpty && has(d, 'a.yui') && (await c.trim(0)).isEmpty && has(d, 'a.yui'), '6: forget không xoá file, mục không còn bị xoá tự động');
  }
  // 7) sổ hỏng / mục độc hại
  {
    final (d, c) = await fresh('t7');
    put(d, 'a.yui', 100);
    File('${d.path}/hub_index.json').writeAsStringSync('{hỏng');
    check((await c.entries()).isEmpty && (await c.trim(0)).isEmpty && has(d, 'a.yui'), '7: sổ hỏng = rỗng, không xoá gì');
    // file thật nằm ngoài thư mục model / trong thư mục con, đúng dung lượng khai trong sổ: chỉ việc kiểm TÊN mới cứu được chúng
    File('${tmp.path}/ngoai.yui').writeAsBytesSync(List.filled(100, 1));
    Directory('${d.path}/sub').createSync();
    File('${d.path}/sub/b.yui').writeAsBytesSync(List.filled(100, 1));
    final good = {'name': 'a.yui', 'id': 'a', 'sha256': 'a' * 64, 'bytes': 100, 'downloaded_ms': 1, 'last_used_ms': 1, 'source': 'S'};
    File('${d.path}/hub_index.json').writeAsStringSync(jsonEncode({
      'v': 1,
      'models': [
        good,
        {...good, 'name': '../ngoai.yui'},
        {...good, 'name': 'sub/b.yui'},
        {...good, 'name': r'x\y.yui'},
        {...good, 'name': '.an.yui'},
        {...good, 'name': 'a.txt'},
        {...good, 'bytes': -5},
        {...good, 'bytes': 1.5},
        {...good}, // trùng tên
        'rác',
      ]
    }));
    final es = await c.entries();
    check(es.length == 1 && es[0].name == 'a.yui', '7: chỉ giữ mục hợp lệ, bỏ tên có đường dẫn/ẩn/trùng (${es.length})');
    await c.trim(0);
    check(File('${tmp.path}/ngoai.yui').existsSync() && File('${d.path}/sub/b.yui').existsSync(), '7: tên "../" hoặc "sub/" không thể khiến xoá file ngoài thư mục model');
  }
  // 8) bền qua lần mở lại; thao tác song song không mất mục
  {
    final (d, c) = await fresh('t8');
    await Future.wait(List.generate(20, (i) async {
      put(d, 'm$i.yui', 10);
      await c.record(model('m$i'), 'm$i.yui', 10);
      await c.touch('m$i.yui');
    }));
    final c2 = HubCache(d, now: tick);
    check((await c2.entries()).length == 20 && (await c2.totalBytes()) == 200, '8: 20 thao tác song song đều được ghi, mở lại vẫn còn');
  }
  // 9) ghi nhận lại cùng tên thì thay mục cũ
  {
    final (d, c) = await fresh('t9');
    put(d, 'a.yui', 100);
    await c.record(model('a'), 'a.yui', 100);
    put(d, 'a.yui', 120);
    await c.record(model('a'), 'a.yui', 120);
    check((await c.entries()).length == 1 && (await c.totalBytes()) == 120, '9: ghi lại cùng tên không nhân đôi');
  }
  // 10) dọn file tải dở quá hạn, giữ file mới và file lạ
  {
    final (d, c) = await fresh('t10');
    final old = File('${d.path}/hub_0123456789abcdef.part')..writeAsBytesSync([1]);
    final recent = File('${d.path}/hub_fedcba9876543210.part')..writeAsBytesSync([1]);
    final other = File('${d.path}/tai_tay.part')..writeAsBytesSync([1]);
    final keep = File('${d.path}/hub_0123456789abcdef.yui')..writeAsBytesSync([1]);
    old.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 30)));
    recent.setLastModifiedSync(DateTime.now().subtract(const Duration(days: 1)));
    final real = HubCache(d); // đồng hồ thật để so với ngày sửa file
    final n = await real.cleanPartials();
    check(n == 1 && !old.existsSync() && recent.existsSync() && other.existsSync() && keep.existsSync(), '10: chỉ xoá .part của Kho đã quá 7 ngày ($n)');
    check(await HubCache(Directory('${tmp.path}/khong_co')).cleanPartials() == 0, '10: thư mục không có thì trả 0');
  }
  // 11) các hằng số
  check(kHubCacheDefaultMb == 500 && kHubCacheMinMb == 50, '11: mặc định 500 MB, tối thiểu 50 MB');

  await tmp.delete(recursive: true);
  stdout.writeln(_fail == 0 ? 'ĐẠT: $_pass kiểm tra' : 'CÓ $_fail KIỂM TRA HỎNG ($_pass đạt)');
  exit(_fail == 0 ? 0 : 1);
}
