// yui_header.dart - đọc nhanh phần ĐẦU file .yui (header + META của v3) bằng Dart thuần, không cần nạp model/engine.
// Dùng cho tab Model: hiện tên, miền, ngôn ngữ, lượng tử của file v3, và từ chối sớm file có phiên bản app chưa hỗ trợ.
// Bố cục (docs/YUI_FORMAT.md ở repo Adaptive-MoE): "YUI1" + 12×u32 + 2×f32 (60 byte), v3 thêm u32 độ dài META + JSON UTF-8 ngay sau đó.
// META chỉ là DỮ LIỆU để hiển thị: không bao giờ chạy, tải hay mở link từ META.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class YuiFormatException implements Exception {
  final String message;
  const YuiFormatException(this.message);
  @override
  String toString() => message;
}

/// Nhãn tiếng Việt cho các miền chuẩn; miền lạ (từ bản mới hơn) hiện nguyên slug.
const Map<String, String> kDomainLabels = {
  'general': 'Tổng quát',
  'chat': 'Trò chuyện',
  'code': 'Lập trình',
  'math': 'Toán',
  'vi-fiction': 'Truyện tiếng Việt',
  'translate': 'Dịch',
  'tool': 'Công cụ',
  'other': 'Khác',
};

String domainLabel(String slug) => kDomainLabels[slug] ?? slug;

final RegExp _ctrl = RegExp('[\\u0000-\\u001f\\u007f-\\u009f\\u2028\\u2029]');

class YuiHeader {
  static const int minVer = 1;
  static const int maxVer = 3;
  static const int headerBytes = 60;
  static const int maxMeta = 65536;

  final int ver;
  final int quant; // 0 f32, 1 int8, 2 q4, 3 t2
  final int vocab;
  final int d;
  final int layers;
  final int heads;
  final int experts;
  final int ctx;
  final Map<String, dynamic>? meta; // chỉ có ở v3

  const YuiHeader({
    required this.ver,
    required this.quant,
    required this.vocab,
    required this.d,
    required this.layers,
    required this.heads,
    required this.experts,
    required this.ctx,
    this.meta,
  });

  bool get hasMeta => meta != null;

  String? _str(String key, int max) {
    final v = meta?[key];
    if (v is! String) return null;
    final s = v.replaceAll(_ctrl, ' ').trim();
    if (s.isEmpty) return null;
    return s.length > max ? s.substring(0, max) : s;
  }

  List<String> _list(String key) {
    final v = meta?[key];
    if (v is! List) return const [];
    final out = <String>[];
    for (final x in v) {
      if (x is! String) continue;
      final s = x.replaceAll(_ctrl, ' ').trim();
      if (s.isNotEmpty && s.length <= 32) out.add(s);
      if (out.length >= 16) break;
    }
    return out;
  }

  String? get name => _str('name', 128);
  String? get description => _str('description', 300);
  String? get license => _str('license', 128);
  List<String> get domains => _list('domains');
  List<String> get langs => _list('lang');

  /// Số tham số ghi trong META (v3), vd "49.9M tham số".
  String? get paramsText {
    final p = meta?['params'];
    if (p is int && p > 0) return '${(p / 1e6).toStringAsFixed(1)}M tham số';
    return null;
  }

  String get quantLabel {
    final q = _str('quant', 16);
    if (q != null) return q;
    switch (quant) {
      case 0:
        return 'f32';
      case 1:
        return 'int8';
      case 2:
        return 'q4';
      default:
        return 't2';
    }
  }

  /// Phân tích các byte đầu file (cần tối đa headerBytes + 4 + maxMeta byte). Ném [YuiFormatException] với thông báo tiếng Việt.
  static YuiHeader parse(Uint8List b) {
    if (b.length < 4 || b[0] != 0x59 || b[1] != 0x55 || b[2] != 0x49 || b[3] != 0x31) {
      throw const YuiFormatException('Không phải file .yui (sai tiêu đề)');
    }
    if (b.length < headerBytes) {
      throw const YuiFormatException('File .yui bị cụt (thiếu phần đầu)');
    }
    final bd = ByteData.sublistView(b);
    int u(int off) => bd.getUint32(off, Endian.little);
    final ver = u(4);
    if (ver < minVer || ver > maxVer) {
      throw YuiFormatException(
          'File .yui phiên bản $ver chưa được app này hỗ trợ (hỗ trợ $minVer–$maxVer). Hãy cập nhật app lên bản mới nhất.');
    }
    final quant = u(8);
    if (quant > 3) {
      throw YuiFormatException('File .yui dùng kiểu lượng tử $quant mà app chưa hỗ trợ. Hãy cập nhật app lên bản mới nhất.');
    }
    final d = u(16);
    final layers = u(20);
    final heads = u(24);
    final experts = u(28);
    if (heads == 0 || d == 0 || layers == 0 || experts == 0 || experts > 256 || d % (heads * 2) != 0) {
      throw const YuiFormatException('File .yui có cấu hình không hợp lệ');
    }
    Map<String, dynamic>? meta;
    if (ver == 3) {
      if (b.length < headerBytes + 4) {
        throw const YuiFormatException('File .yui bị cụt (thiếu khối META)');
      }
      final n = u(headerBytes);
      if (n < 1 || n > maxMeta) {
        throw YuiFormatException('META của file .yui không hợp lệ (độ dài $n)');
      }
      if (b.length < headerBytes + 4 + n) {
        throw const YuiFormatException('File .yui bị cụt (thiếu khối META)');
      }
      try {
        final obj = jsonDecode(utf8.decode(Uint8List.sublistView(b, headerBytes + 4, headerBytes + 4 + n)));
        if (obj is! Map<String, dynamic>) throw const FormatException('META không phải đối tượng');
        meta = obj;
      } on FormatException {
        throw const YuiFormatException('META của file .yui không phải JSON hợp lệ');
      }
    }
    return YuiHeader(
      ver: ver,
      quant: quant,
      vocab: u(12),
      d: d,
      layers: layers,
      heads: heads,
      experts: experts,
      ctx: u(40),
      meta: meta,
    );
  }

  /// Đọc phần đầu của file rồi [parse]. Ném [YuiFormatException]; lỗi đọc file thì ném lỗi hệ thống.
  static YuiHeader readSync(String path) {
    final f = File(path).openSync();
    try {
      final len = f.lengthSync();
      const cap = headerBytes + 4 + maxMeta;
      final n = len < cap ? len : cap;
      return parse(f.readSync(n));
    } finally {
      f.closeSync();
    }
  }

  /// null nếu app dùng được file này; ngược lại là lời giải thích tiếng Việt.
  static String? problem(String path) {
    try {
      readSync(path);
      return null;
    } on YuiFormatException catch (e) {
      return e.message;
    } catch (_) {
      return 'Không đọc được file .yui';
    }
  }
}
