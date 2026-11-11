// smooth_stream.dart — làm chữ hiện ĐỀU (thay vì từng cục theo token/gói).
// Engine trả chữ theo token; có lúc dồn cục (đoán trước token trúng liền nhiều token, isolate gom gói). SmoothReveal giữ "văn bản đích"
// và nhả dần theo nhịp khung hình: bộ đệm ít thì chậm lại cho đều, nhiều thì tự tăng tốc để KHÔNG trễ quá maxLagMs so với engine.
// Thuần Dart, không phụ thuộc gói ngoài.
import 'dart:async';

class SmoothReveal {
  SmoothReveal({
    required this.onUpdate,
    this.minCps = 40, // chữ/giây tối thiểu khi bộ đệm còn ít
    this.maxLagMs = 300, // bộ đệm không được dồn tới mức trễ quá ngần này
    this.frameMs = 33, // ~30 khung hình/giây (đủ mượt, đỡ dựng lại danh sách chat quá dày)
  });

  /// Gọi mỗi khung hình với phần chữ ĐÃ được phép hiện (luôn là tiền tố của văn bản đích).
  final void Function(String shown) onUpdate;
  final double minCps;
  final int maxLagMs;
  final int frameMs;

  String _target = '';
  int _shown = 0; // số code unit đã hiện
  double _credit = 0; // phần lẻ "được nhả" giữa hai khung hình
  bool _done = false;
  bool _closed = false;
  Timer? _timer;
  Completer<void>? _drained;
  final Stopwatch _clock = Stopwatch()..start();
  int _lastUs = 0;

  /// Đặt văn bản đích mới (thường dài thêm; nếu ngắn đi, vd thẻ công cụ bị ẩn, phần hiện được cắt theo).
  void setTarget(String t) {
    if (_closed) return;
    _target = t;
    if (_shown > t.length) {
      _shown = t.length;
      _emit();
    }
    _startTimer();
  }

  /// Báo engine đã xong: xả nhanh phần còn lại; Future hoàn tất khi đã hiện hết.
  Future<void> finish() {
    _done = true;
    _drained ??= Completer<void>();
    if (_closed || _shown >= _target.length) {
      _finishNow();
    } else {
      _startTimer();
    }
    return _drained!.future;
  }

  /// Hiện NGAY toàn bộ phần còn lại (người dùng bấm Dừng, hoặc có lỗi).
  void cancel() {
    if (_closed) return;
    if (_shown != _target.length) {
      _shown = _target.length;
      _emit();
    }
    _finishNow();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _closed = true;
    final d = _drained;
    if (d != null && !d.isCompleted) d.complete();
  }

  void _startTimer() {
    if (_timer != null) return;
    _lastUs = _clock.elapsedMicroseconds;
    _timer = Timer.periodic(Duration(milliseconds: frameMs), (_) => _tick());
  }

  void _tick() {
    final now = _clock.elapsedMicroseconds;
    final dt = ((now - _lastUs) / 1e6).clamp(0.0, 0.1).toDouble();
    _lastUs = now;
    final backlog = _target.length - _shown;
    if (backlog <= 0) {
      _credit = 0;
      if (_done) _finishNow();
      return;
    }
    var cps = backlog / (maxLagMs / 1000.0);
    if (cps < minCps) cps = minCps;
    if (_done && cps < 400) cps = 400; // engine xong rồi: đừng bắt người dùng chờ
    if (cps > 5000) cps = 5000;
    _credit += cps * dt;
    var n = _credit.floor();
    if (n < 1) return;
    if (n > backlog) n = backlog;
    final end = _safeEnd(_shown + n);
    _credit -= (end - _shown);
    if (_credit < 0) _credit = 0;
    _shown = end;
    _emit();
    if (_done && _shown >= _target.length) _finishNow();
  }

  /// Không cắt giữa cặp surrogate (emoji) hay ngay trước dấu kết hợp (dấu thanh dạng NFD, ZWJ).
  int _safeEnd(int end) {
    final s = _target;
    if (end >= s.length) return s.length;
    final u = s.codeUnitAt(end - 1);
    if (u >= 0xD800 && u <= 0xDBFF) end++;
    while (end < s.length && _isCombining(s.codeUnitAt(end))) {
      end++;
    }
    return end > s.length ? s.length : end;
  }

  static bool _isCombining(int u) => (u >= 0x0300 && u <= 0x036F) || u == 0x200D || (u >= 0xFE00 && u <= 0xFE0F);

  void _emit() {
    if (!_closed) onUpdate(_target.substring(0, _shown));
  }

  void _finishNow() {
    _timer?.cancel();
    _timer = null;
    _closed = true;
    final d = _drained;
    if (d != null && !d.isCompleted) d.complete();
  }
}
