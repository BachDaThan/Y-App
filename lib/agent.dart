// agent.dart - công cụ (tool) chạy NGAY TRONG APP cho model đã được dạy bằng tool_data.py (repo Adaptive-MoE).
// Khớp cú pháp của yui_agent.py:   model viết  <tool>calc 23*17</tool>  -> app chạy -> trả lại lượt user  <result>391</result>
// Chỉ có 3 công cụ an toàn, không cần sandbox: calc (máy tính duyệt cú pháp, không eval), time, search (Wikipedia tiếng Việt, cần mạng).
// fetch/read/write/py của yui_agent.py cố ý KHÔNG đưa vào app điện thoại.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

/// Độ dài tối đa kết quả công cụ đưa lại cho model. Phải <= TOOL_RESULT_CHARS lúc tạo data (mặc định 300),
/// và với model ngữ cảnh 128 token thì để 120 cho vừa. Đổi ở đây thì đổi cả TOOL_RESULT_CHARS khi chạy make_data.
const int kToolResultChars = 120;

class AgentCall {
  final String name;
  final String arg;
  const AgentCall(this.name, this.arg);
}

class AgentTools {
  static const int maxSteps = 2; // tối đa 2 lần gọi công cụ cho mỗi câu hỏi
  static const List<String> names = ['calc', 'time', 'search'];
  static const String fallback = 'Mik chưa trả lời được câu này.';
  static const List<String> _dow = ['Thứ Hai', 'Thứ Ba', 'Thứ Tư', 'Thứ Năm', 'Thứ Sáu', 'Thứ Bảy', 'Chủ Nhật'];

  static final RegExp _callRe = RegExp(r'<tool>(.*?)(?:</tool>|$)', dotAll: true, caseSensitive: false);

  /// Tách lệnh gọi. Dễ tính với model nhỏ: thiếu </tool>, dạng JSON, dấu | hoặc : sau tên đều được.
  static AgentCall? parseCall(String text) {
    final m = _callRe.firstMatch(text);
    if (m == null) return null;
    final body = (m.group(1) ?? '').trim();
    if (body.isEmpty) return null;
    String name, arg = '';
    if (body.startsWith('{')) {
      try {
        final o = jsonDecode(body);
        if (o is! Map) return null;
        name = '${o['name'] ?? o['tool'] ?? ''}';
        final a = o['arg'] ?? o['args'] ?? o['q'] ?? o['expr'] ?? '';
        if (a is String) {
          arg = a;
        } else if (a is Map) {
          arg = a.values.firstWhere((v) => v is String, orElse: () => '') as String;
        } else {
          arg = '$a';
        }
      } catch (_) {
        return null;
      }
    } else {
      final mm = RegExp(r'^([\w.\-]+)\s*[|:]?\s*(.*)$', dotAll: true).firstMatch(body);
      if (mm == null) return null;
      name = mm.group(1)!;
      arg = mm.group(2) ?? '';
    }
    return AgentCall(name.toLowerCase(), arg.trim());
  }

  static String stripToolTags(String text) =>
      text.replaceAll(RegExp(r'<tool>.*?(</tool>|$)', dotAll: true, caseSensitive: false), '').trim();

  /// Phần hiển thị khi đang sinh chữ: nếu model mở đầu bằng thẻ thì không để người dùng thấy thẻ thô.
  static String visible(String buf) => buf.trimLeft().startsWith('<') ? '🔧 …' : buf;

  /// Kết quả công cụ là dữ liệu không tin cậy: bỏ ký tự điều khiển và mọi thẻ <tool>/<result>.
  static String sanitize(String t) {
    t = t.replaceAll(RegExp(r'[\x00-\x08\x0b-\x1f\x7f]'), ' ');
    t = t.replaceAll(RegExp(r'</?\s*(tool|result)\b[^>]*>?', caseSensitive: false), ' ');
    return t.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static String _cutChars(String s, int n) {
    final r = s.runes.toList();
    return r.length <= n ? s : String.fromCharCodes(r.take(n));
  }

  /// Chạy một công cụ; mọi lỗi đều thành chuỗi ngắn để model còn trả lời được.
  static Future<String> run(String name, String arg) async {
    String out;
    try {
      switch (name) {
        case 'calc':
          out = calc(arg);
          break;
        case 'time':
          out = time(arg);
          break;
        case 'search':
          out = await search(arg);
          break;
        default:
          out = 'không có công cụ "$name"';
      }
    } catch (e) {
      out = 'lỗi: ${'$e'.replaceFirst('Exception: ', '').replaceFirst('FormatException: ', '')}';
    }
    out = _cutChars(sanitize(out), kToolResultChars);
    return out.isEmpty ? '(trống)' : out;
  }

  // ------------------------------ time ------------------------------
  static String time(String arg) {
    final m = RegExp(r'^\s*(?:utc)?\s*([+-]\d{1,2})?\s*$', caseSensitive: false).firstMatch(arg);
    final off = (m != null && m.group(1) != null) ? int.parse(m.group(1)!) : 7; // mặc định giờ Việt Nam
    if (off < -12 || off > 14) throw Exception('múi giờ không hợp lệ');
    final d = DateTime.now().toUtc().add(Duration(hours: off));
    String p(int x) => x.toString().padLeft(2, '0');
    return '${_dow[d.weekday - 1]}, ${p(d.day)}/${p(d.month)}/${d.year} ${p(d.hour)}:${p(d.minute)} (UTC${off >= 0 ? '+' : ''}$off)';
  }

  // ------------------------------ search ------------------------------
  static Future<String> search(String q) async {
    q = q.trim();
    if (q.isEmpty) throw Exception('thiếu từ khoá');
    if (q.length > 200) q = q.substring(0, 200);
    final uri = Uri.https('vi.wikipedia.org', '/w/api.php', {
      'action': 'query',
      'format': 'json',
      'formatversion': '2',
      'generator': 'search',
      'gsrsearch': q,
      'gsrlimit': '1',
      'prop': 'extracts',
      'exintro': '1',
      'explaintext': '1',
      'exchars': '${math.max(200, kToolResultChars * 2)}',
    });
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await c.getUrl(uri);
      req.headers.set('User-Agent', 'YuiApp/1.0');
      final resp = await req.close().timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      final body = await resp.transform(utf8.decoder).join().timeout(const Duration(seconds: 12));
      final pages = ((jsonDecode(body) as Map)['query'] as Map?)?['pages'] as List?;
      if (pages == null || pages.isEmpty) return 'không tìm thấy';
      final ex = (pages.first as Map)['extract'];
      return (ex is String && ex.trim().isNotEmpty) ? ex : 'không tìm thấy';
    } on SocketException {
      throw Exception('không có mạng');
    } on TimeoutException {
      throw Exception('hết thời gian chờ');
    } finally {
      c.close(force: true);
    }
  }

  // ------------------------------ calc ------------------------------
  /// Máy tính an toàn: tự phân tích cú pháp, KHÔNG eval. Số, + - * / // % ** ^ ( ) và vài hàm toán; chặn luỹ thừa khổng lồ.
  static String calc(String expr) {
    expr = expr
        .trim()
        .replaceAll('×', '*')
        .replaceAll('÷', '/')
        .replaceAll('^', '**')
        .replaceAll('−', '-')
        .replaceAllMapped(RegExp(r'(?<=\d),(?=\d)'), (_) => '.');
    if (expr.isEmpty || expr.length > 200) throw Exception('biểu thức rỗng hoặc quá dài');
    final v = _Calc(expr).run();
    if (v.isNaN || v.isInfinite) throw Exception('kết quả không xác định');
    if (v == v.truncateToDouble() && v.abs() < 1e15) return v.toInt().toString();
    return double.parse(v.toStringAsPrecision(10)).toString();
  }
}

class _Calc {
  final String s;
  int i = 0;
  int nodes = 0;
  _Calc(this.s);

  double run() {
    final v = _expr();
    _ws();
    if (i < s.length) throw Exception('biểu thức không hợp lệ');
    return v;
  }

  void _ws() {
    while (i < s.length && s[i] == ' ') {
      i++;
    }
  }

  bool _eat(String t) {
    _ws();
    if (s.startsWith(t, i)) {
      i += t.length;
      return true;
    }
    return false;
  }

  void _tick() {
    if (++nodes > 200) throw Exception('biểu thức quá phức tạp');
  }

  double _expr() {
    var v = _term();
    while (true) {
      if (_eat('+')) {
        v += _term();
      } else if (_eat('-')) {
        v -= _term();
      } else {
        return v;
      }
    }
  }

  double _term() {
    var v = _unary();
    while (true) {
      _ws();
      if (s.startsWith('**', i)) return v; // luỹ thừa do _power xử lý
      if (_eat('//')) {
        final b = _unary();
        if (b == 0) throw Exception('chia cho 0');
        v = (v / b).floorToDouble();
      } else if (_eat('*')) {
        v *= _unary();
      } else if (_eat('/')) {
        final b = _unary();
        if (b == 0) throw Exception('chia cho 0');
        v /= b;
      } else if (_eat('%')) {
        final b = _unary();
        if (b == 0) throw Exception('chia cho 0');
        v = v - b * (v / b).floorToDouble();
      } else {
        return v;
      }
    }
  }

  double _unary() {
    _tick();
    if (_eat('-')) return -_unary();
    if (_eat('+')) return _unary();
    return _power();
  }

  double _power() {
    final a = _atom();
    _ws();
    if (s.startsWith('**', i)) {
      i += 2;
      final b = _unary();
      if (b.abs() > 1000 || (a.abs() > 1 && b.abs() * (math.log(a.abs()) / math.ln2) > 4096)) {
        throw Exception('luỹ thừa quá lớn');
      }
      return math.pow(a, b).toDouble();
    }
    return a;
  }

  double _atom() {
    _tick();
    _ws();
    if (i >= s.length) throw Exception('biểu thức không hợp lệ');
    if (_eat('(')) {
      final v = _expr();
      if (!_eat(')')) throw Exception('thiếu dấu )');
      return v;
    }
    final nm = RegExp(r'\d+(\.\d+)?|\.\d+').matchAsPrefix(s, i);
    if (nm != null) {
      i = nm.end;
      return double.parse(nm.group(0)!);
    }
    final id = RegExp(r'[a-zA-Z_][a-zA-Z_0-9]*').matchAsPrefix(s, i);
    if (id != null) {
      final name = id.group(0)!.toLowerCase();
      i = id.end;
      if (_eat('(')) {
        final args = <double>[_expr()];
        while (_eat(',')) {
          args.add(_expr());
        }
        if (!_eat(')') || args.length > 2) throw Exception('biểu thức không hợp lệ');
        return _fn(name, args);
      }
      if (name == 'pi') return math.pi;
      if (name == 'e') return math.e;
    }
    throw Exception('biểu thức không hợp lệ');
  }

  double _fn(String n, List<double> a) {
    final x = a[0];
    switch (n) {
      case 'sqrt':
        if (x < 0) throw Exception('căn số âm');
        return math.sqrt(x);
      case 'abs':
        return x.abs();
      case 'round':
        return x.roundToDouble();
      case 'floor':
        return x.floorToDouble();
      case 'ceil':
        return x.ceilToDouble();
      case 'sin':
        return math.sin(x);
      case 'cos':
        return math.cos(x);
      case 'tan':
        return math.tan(x);
      case 'log':
        if (x <= 0) throw Exception('log số không dương');
        return a.length == 2 ? math.log(x) / math.log(a[1]) : math.log(x);
      case 'exp':
        return math.exp(x);
      case 'min':
        return a.length == 2 ? math.min(x, a[1]) : x;
      case 'max':
        return a.length == 2 ? math.max(x, a[1]) : x;
    }
    throw Exception('biểu thức không hợp lệ');
  }
}
