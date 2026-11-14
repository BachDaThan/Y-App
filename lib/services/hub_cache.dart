// hub_cache.dart - bộ nhớ đệm đĩa (LRU) cho các model tải từ Kho (P2-5).
// Dart thuần (dart:io/convert/async), không phụ thuộc Flutter: chạy thử bằng `dart tools/hub_cache_check.dart`.
//
// Quy tắc cốt lõi:
//  - CHỈ model có trong sổ "hub_index.json" (tức model tải từ Kho) mới có thể bị xoá. File .yui người dùng tự nhập/tải bằng link tay
//    KHÔNG có trong sổ nên không bao giờ bị đụng tới, dù lớn đến đâu.
//  - Model được truyền vào `protected` (đang chạy, model vừa tải, model đang chọn) không bao giờ bị xoá.
//  - Xoá theo thứ tự lâu chưa dùng nhất trước (lastUsed; nạp model là "dùng"), dừng ngay khi tổng ≤ trần.
//  - Sổ luôn đối chiếu với đĩa: file mất hoặc đã bị thay (dung lượng khác lúc ghi) thì bỏ khỏi sổ và KHÔNG xoá file đó.
//  - Trần là "mềm": kiểm sau khi tải xong (để tải hỏng không làm mất model cũ), nên tạm thời có thể vượt trần tối đa một model.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'hub_service.dart';

const int kHubCacheDefaultMb = 500;
const int kHubCacheMinMb = 50; // trần thấp nhất cho phép đặt
const int kHubCacheMaxEntries = 1000;
const Duration kHubPartialMaxAge = Duration(days: 7);

final RegExp _reFile = RegExp(r'^[^/\\]+\.yui$', caseSensitive: false);
final RegExp _rePartial = RegExp(r'^hub_[0-9a-f]{16}\.part$');

class HubCacheEntry {
  final String name; // tên file .yui trong thư mục model
  final String id;
  final String sha256;
  final int bytes;
  final int downloadedMs;
  final int lastUsedMs;
  final String source;
  const HubCacheEntry({
    required this.name,
    required this.id,
    required this.sha256,
    required this.bytes,
    required this.downloadedMs,
    required this.lastUsedMs,
    required this.source,
  });

  HubCacheEntry used(int ms) =>
      HubCacheEntry(name: name, id: id, sha256: sha256, bytes: bytes, downloadedMs: downloadedMs, lastUsedMs: ms, source: source);

  Map<String, Object> toJson() => {
        'name': name,
        'id': id,
        'sha256': sha256,
        'bytes': bytes,
        'downloaded_ms': downloadedMs,
        'last_used_ms': lastUsedMs,
        'source': source,
      };

  static HubCacheEntry? fromJson(Object? j) {
    if (j is! Map) return null;
    final name = j['name'], id = j['id'], sha = j['sha256'], source = j['source'];
    final bytes = j['bytes'], dl = j['downloaded_ms'], lu = j['last_used_ms'];
    if (name is! String || !_reFile.hasMatch(name) || name.startsWith('.') || name.length > 256) return null;
    if (id is! String || sha is! String || source is! String) return null;
    if (bytes is! int || bytes <= 0 || dl is! int || lu is! int) return null;
    return HubCacheEntry(name: name, id: id, sha256: sha, bytes: bytes, downloadedMs: dl, lastUsedMs: lu, source: source);
  }
}

class HubCache {
  final Directory dir;
  final int Function() now;
  HubCache(this.dir, {int Function()? now}) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  Future<void> _tail = Future<void>.value();

  /// Xếp hàng mọi thao tác đọc-sửa-ghi sổ để không giẫm lên nhau (vd nạp model trong lúc đang tải model khác).
  Future<T> _sync<T>(Future<T> Function() f) {
    final c = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        c.complete(await f());
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  File get _index => File('${dir.path}${Platform.pathSeparator}hub_index.json');
  File _file(String name) => File('${dir.path}${Platform.pathSeparator}$name');

  /// Đọc sổ (sổ hỏng = sổ rỗng), đối chiếu với đĩa; ghi lại nếu có đổi.
  Future<List<HubCacheEntry>> _load() async {
    final out = <HubCacheEntry>[];
    var changed = false;
    try {
      if (await _index.exists()) {
        final j = jsonDecode(await _index.readAsString());
        final ms = (j is Map) ? j['models'] : null;
        if (ms is List) {
          final seen = <String>{};
          for (final x in ms) {
            if (out.length >= kHubCacheMaxEntries) {
              changed = true;
              break;
            }
            final e = HubCacheEntry.fromJson(x);
            if (e == null || !seen.add(e.name)) {
              changed = true;
              continue;
            }
            out.add(e);
          }
        } else {
          changed = true;
        }
      }
    } catch (_) {
      changed = true; // sổ hỏng: coi như rỗng (các file .yui vẫn nguyên, chỉ không còn bị xoá tự động)
    }
    out.removeWhere((e) {
      final f = _file(e.name);
      final ok = f.existsSync() && f.lengthSync() == e.bytes;
      if (!ok) changed = true;
      return !ok;
    });
    if (changed) await _save(out);
    return out;
  }

  Future<void> _save(List<HubCacheEntry> es) async {
    await dir.create(recursive: true);
    final tmp = File('${_index.path}.tmp');
    await tmp.writeAsString(jsonEncode({'v': 1, 'models': es.map((e) => e.toJson()).toList()}), flush: true);
    await tmp.rename(_index.path);
  }

  Future<List<HubCacheEntry>> entries() => _sync(_load);

  Future<int> totalBytes() async => (await entries()).fold<int>(0, (a, e) => a + e.bytes);

  /// Ghi nhận model vừa tải từ Kho (coi như vừa dùng).
  Future<void> record(HubModel m, String fileName, int bytes) => _sync(() async {
        final es = await _load();
        es.removeWhere((e) => e.name == fileName);
        final t = now();
        es.add(HubCacheEntry(name: fileName, id: m.id, sha256: m.sha256, bytes: bytes, downloadedMs: t, lastUsedMs: t, source: m.sourceName));
        await _save(es);
      });

  /// Đánh dấu vừa dùng (gọi khi nạp model). Không phải model của Kho thì bỏ qua. Không bao giờ ném lỗi.
  Future<void> touch(String name) async {
    try {
      await _sync(() async {
        final es = await _load();
        final i = es.indexWhere((e) => e.name == name);
        if (i < 0) return;
        es[i] = es[i].used(now());
        await _save(es);
      });
    } catch (_) {}
  }

  /// Bỏ khỏi sổ (khi người dùng tự xoá model). Không đụng file. Không bao giờ ném lỗi.
  Future<void> forget(String name) async {
    try {
      await _sync(() async {
        final es = await _load();
        final n = es.length;
        es.removeWhere((e) => e.name == name);
        if (es.length != n) await _save(es);
      });
    } catch (_) {}
  }

  /// Xoá model ít dùng nhất trước cho tới khi tổng ≤ [capBytes]. Trả về danh sách đã xoá.
  /// Nếu chỉ còn model được bảo vệ mà vẫn vượt trần thì dừng (không xoá thêm).
  Future<List<HubCacheEntry>> trim(int capBytes, {Set<String> protected = const {}}) => _sync(() async {
        final es = await _load();
        var total = es.fold<int>(0, (a, e) => a + e.bytes);
        final order = [...es]..sort((a, b) {
            final c = a.lastUsedMs.compareTo(b.lastUsedMs);
            if (c != 0) return c;
            final d = a.downloadedMs.compareTo(b.downloadedMs);
            return d != 0 ? d : a.name.compareTo(b.name);
          });
        final gone = <HubCacheEntry>[];
        for (final e in order) {
          if (total <= capBytes) break;
          if (protected.contains(e.name)) continue;
          try {
            final f = _file(e.name);
            if (await f.exists()) await f.delete();
          } catch (_) {
            continue; // không xoá được thì giữ trong sổ và thử model khác
          }
          gone.add(e);
          total -= e.bytes;
        }
        if (gone.isNotEmpty) {
          final names = gone.map((e) => e.name).toSet();
          es.removeWhere((e) => names.contains(e.name));
          await _save(es);
        }
        return gone;
      });

  /// Xoá file tải dở (hub_<16 hex>.part) đã quá [maxAge] không được ghi thêm. Trả về số file đã xoá. Không bao giờ ném lỗi.
  Future<int> cleanPartials({Duration maxAge = kHubPartialMaxAge}) async {
    var n = 0;
    try {
      if (!await dir.exists()) return 0;
      final cutoff = DateTime.fromMillisecondsSinceEpoch(now()).subtract(maxAge);
      await for (final e in dir.list(followLinks: false)) {
        if (e is! File) continue;
        final base = e.path.split(RegExp(r'[\\/]')).last;
        if (!_rePartial.hasMatch(base)) continue;
        try {
          if ((await e.lastModified()).isBefore(cutoff)) {
            await e.delete();
            n++;
          }
        } catch (_) {}
      }
    } catch (_) {}
    return n;
  }
}
