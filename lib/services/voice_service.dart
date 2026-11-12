import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../state.dart';
import 'sherpa_stt.dart';

/// Giọng nói cho Yui: tai (STT) -> não (model .yui, không đổi gì) -> miệng (TTS).
/// Không cần train lại model: chỉ biến giọng nói thành chữ gửi vào chat, và đọc chữ model đang stream ra.
/// - STT: bộ nhận dạng của Android (đặt "Chỉ offline" để ép chạy trên máy, cần gói tiếng Việt đã tải).
/// - TTS: giọng đọc của hệ điều hành, đọc TỪNG CÂU ngay khi model vừa viết xong câu đó.
class VoiceService extends ChangeNotifier {
  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();
  SharedPreferences? _p;

  bool autoSpeak = false; // đọc to câu trả lời
  bool handsFree = false; // đàm thoại: nghe -> gửi -> đọc -> nghe tiếp
  bool useSherpa = false; // nhận dạng offline bằng Sherpa-ONNX (model tiếng Việt tải về máy)
  bool sherpaBusy = false; // đang tải model
  double sherpaProgress = 0;
  final SherpaStt _sherpa = SherpaStt();
  bool listening = false;
  bool speaking = false;
  String partial = '';
  String? _error;

  bool _attached = false;
  bool _sttReady = false;
  bool _ttsReady = false;
  String? _sttLocale;

  // Windows chỉ nghe được bằng Sherpa (STT hệ thống chỉ có trên Android)
  bool get sttSupported => Platform.isAndroid || Platform.isWindows;
  bool get _sherpaMode => useSherpa || !Platform.isAndroid;
  bool get ttsSupported => Platform.isAndroid || Platform.isWindows;

  String? takeError() {
    final e = _error;
    _error = null;
    return e;
  }

  void _fail(String msg) {
    _error = msg;
    notifyListeners();
  }

  /// Gọi một lần khi mở màn chat (gọi lại không sao).
  Future<void> attach() async {
    if (_attached) return;
    _attached = true;
    _p = await SharedPreferences.getInstance();
    autoSpeak = _p!.getBool('voice_speak') ?? false;
    useSherpa = _p!.getBool('voice_sherpa') ?? false;
    app.addListener(_onApp);
    notifyListeners();
  }

  Future<void> setAutoSpeak(bool v) async {
    autoSpeak = v;
    if (!v) {
      handsFree = false;
      await stopSpeaking();
    }
    await _p?.setBool('voice_speak', v);
    notifyListeners();
  }

  /// Bật/tắt nhận dạng offline Sherpa. Lần đầu bật sẽ tải model (có tiến độ).
  Future<void> setSherpa(bool v) async {
    if (sherpaBusy) return;
    if (!v) {
      if (Platform.isAndroid) {
        useSherpa = false;
        await _p?.setBool('voice_sherpa', false);
      }
      notifyListeners();
      return;
    }
    try {
      if (!await _sherpa.isInstalled()) {
        sherpaBusy = true;
        sherpaProgress = 0;
        notifyListeners();
        await _sherpa.install((p) {
          sherpaProgress = p;
          notifyListeners();
        });
      }
      useSherpa = true;
      await _p?.setBool('voice_sherpa', true);
    } catch (e) {
      useSherpa = false;
      _fail('Không tải được model Sherpa: $e');
    } finally {
      sherpaBusy = false;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------------ TTS
  Future<bool> _initTts() async {
    if (_ttsReady) return true;
    if (!ttsSupported) return false;
    try {
      final ok = await _tts.isLanguageAvailable('vi-VN');
      if (ok != true && ok != 1) {
        _fail('Máy chưa có giọng đọc tiếng Việt. Vào Cài đặt Android → Ngôn ngữ → Chuyển văn bản thành giọng nói để tải gói tiếng Việt.');
      }
      await _tts.setLanguage('vi-VN');
      await _tts.setSpeechRate(0.5);
      await _tts.setPitch(1.0);
      await _tts.awaitSpeakCompletion(true);
      _ttsReady = true;
    } catch (e) {
      _fail('Không khởi tạo được giọng đọc: $e');
    }
    return _ttsReady;
  }

  final List<String> _queue = [];
  bool _pumping = false;

  void _enqueue(String raw) {
    final s = _clean(raw);
    if (s.length < 2) return;
    _queue.add(s);
    unawaited(_pump());
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    speaking = true;
    notifyListeners();
    try {
      if (await _initTts()) {
        while (_queue.isNotEmpty) {
          final s = _queue.removeAt(0);
          await _tts.speak(s); // awaitSpeakCompletion(true): xong câu này mới tới câu sau
        }
      } else {
        _queue.clear();
      }
    } catch (_) {
      _queue.clear();
    } finally {
      _pumping = false;
      speaking = false;
      notifyListeners();
      _maybeRelisten();
    }
  }

  Future<void> stopSpeaking() async {
    _queue.clear();
    _track = null;
    try {
      await _tts.stop();
    } catch (_) {}
  }

  /// Bỏ những thứ đọc lên nghe rất tệ: thẻ công cụ, link, markdown, emoji.
  static String _clean(String t) {
    var s = t;
    s = s.replaceAll(RegExp(r'<[^>]{1,40}>'), ' ');
    s = s.replaceAll(RegExp(r'https?://\S+'), ' ');
    s = s.replaceAll(RegExp(r'[*_#`>~|\[\]{}]'), ' ');
    s = s.replaceAll(RegExp('[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}\u{200D}]', unicode: true), ' ');
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  // ------------------------------------------- đọc câu trả lời đang stream
  bool _wasGen = false;
  ChatMessage? _track;
  int _spoken = 0;
  static final RegExp _boundary = RegExp(r'[.!?…]+\s|\n+');

  void _onApp() {
    final gen = app.generating;
    final msgs = app.currentChat?.messages;
    if (gen && !_wasGen) {
      _track = (msgs != null && msgs.isNotEmpty && msgs.last.role == 'assistant') ? msgs.last : null;
      _spoken = 0;
    }
    if (_track != null && autoSpeak) _feed(fin: !gen);
    if (!gen && _wasGen) {
      _track = null;
      _maybeRelisten();
    }
    _wasGen = gen;
  }

  void _feed({required bool fin}) {
    final m = _track;
    if (m == null) return;
    final text = m.content;
    if (text.startsWith('🔧')) {
      _spoken = 0; // đang gọi công cụ, chữ sẽ bị thay bằng câu trả lời thật
      return;
    }
    if (_spoken > text.length) _spoken = 0;
    for (final mt in _boundary.allMatches(text, _spoken)) {
      if (mt.end <= _spoken) continue;
      _enqueue(text.substring(_spoken, mt.end));
      _spoken = mt.end;
    }
    // Câu quá dài mà chưa có dấu chấm: cắt ở khoảng trắng để không im lặng quá lâu.
    while (text.length - _spoken > 180) {
      var cut = text.lastIndexOf(' ', _spoken + 160);
      if (cut <= _spoken) cut = _spoken + 160;
      _enqueue(text.substring(_spoken, cut));
      _spoken = cut;
    }
    if (fin) {
      if (_spoken < text.length && text.trim() != '…') _enqueue(text.substring(_spoken));
      _spoken = text.length;
    }
  }

  // ------------------------------------------------------------------ STT
  void Function(String text)? _onFinal;
  int _empty = 0;

  Future<bool> _initStt() async {
    if (_sttReady) return true;
    if (!sttSupported) {
      _fail('Nghe giọng nói hiện chỉ có trên Android.');
      return false;
    }
    try {
      _sttReady = await _stt.initialize(onStatus: _onStatus, onError: _onError);
      if (!_sttReady) {
        _fail('Chưa cấp quyền micro hoặc máy không có dịch vụ nhận dạng giọng nói (Google).');
        return false;
      }
      final ls = await _stt.locales();
      for (final l in ls) {
        if (l.localeId.toLowerCase().startsWith('vi')) {
          _sttLocale = l.localeId;
          break;
        }
      }
    } catch (e) {
      _sttReady = false;
      _fail('Không khởi tạo được nhận dạng giọng nói: $e');
    }
    return _sttReady;
  }

  /// Nghe một câu rồi gọi [onFinal] với chữ nhận được (đã có chữ mới gọi).
  Future<void> startListening(void Function(String text) onFinal) async {
    if (listening) return;
    await stopSpeaking();
    if (_sherpaMode) {
      await _listenSherpa(onFinal);
      return;
    }
    if (!await _initStt()) {
      handsFree = false;
      notifyListeners();
      return;
    }
    partial = '';
    _onFinal = onFinal;
    listening = true;
    notifyListeners();
    try {
      await _stt.listen(
        onResult: (r) {
          partial = r.recognizedWords;
          notifyListeners();
          if (r.finalResult) _finish();
        },
        localeId: _sttLocale ?? 'vi_VN',
        listenFor: const Duration(seconds: 45),
        pauseFor: const Duration(seconds: 3),
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.dictation,
        ),
      );
    } catch (e) {
      listening = false;
      handsFree = false;
      _fail('Không bắt đầu nghe được: $e');
    }
  }

  Future<void> _listenSherpa(void Function(String text) onFinal) async {
    try {
      if (!await _sherpa.isInstalled()) {
        handsFree = false;
        if (Platform.isAndroid) useSherpa = false;
        _fail('Chưa tải model Sherpa. Bật chip "Offline (Sherpa)" để tải (cần mạng một lần).');
        return;
      }
      partial = '';
      _onFinal = onFinal;
      listening = true;
      notifyListeners();
      final ok = await _sherpa.start(
        onPartial: (t) {
          partial = t;
          notifyListeners();
        },
        onFinal: (t) {
          partial = t;
          _finish();
        },
      );
      if (!ok) {
        listening = false;
        handsFree = false;
        notifyListeners();
        _fail('Chưa cấp quyền micro cho Yui.');
      }
    } catch (e) {
      listening = false;
      handsFree = false;
      notifyListeners();
      _fail('Lỗi nhận dạng offline: $e');
    }
  }

  /// Bấm lại nút mic: dừng nghe và dùng những gì đã nghe được.
  Future<void> stopListening() async {
    if (_sherpaMode) {
      await _sherpa.stop();
      return;
    }
    try {
      await _stt.stop();
    } catch (_) {}
    _finish();
  }

  Future<void> cancelListening() async {
    _onFinal = null;
    partial = '';
    listening = false;
    if (_sherpaMode) await _sherpa.cancel();
    try {
      await _stt.cancel();
    } catch (_) {}
    notifyListeners();
  }

  void _finish() {
    if (!listening) return;
    listening = false;
    final t = partial.trim();
    partial = '';
    final cb = _onFinal;
    _onFinal = null;
    notifyListeners();
    if (t.isNotEmpty) {
      _empty = 0;
      cb?.call(t);
    } else if (handsFree) {
      _empty++;
      if (_empty >= 3) {
        handsFree = false; // im lặng 3 lần liền thì thôi, khỏi nghe mãi
        _empty = 0;
        notifyListeners();
      } else {
        _relistenSoon();
      }
    }
  }

  void _onStatus(String s) {
    if ((s == 'done' || s == 'notListening') && listening) _finish();
  }

  void _onError(SpeechRecognitionError e) {
    final benign = e.errorMsg == 'error_no_match' || e.errorMsg == 'error_speech_timeout';
    if (benign) {
      _finish();
      return;
    }
    listening = false;
    partial = '';
    _onFinal = null;
    handsFree = false;
    var msg = 'Lỗi nhận dạng giọng nói: ${e.errorMsg}';
    if (e.errorMsg == 'error_permission') msg = 'Chưa cấp quyền micro cho Yui.';
    if (e.errorMsg == 'error_language_not_supported' || e.errorMsg == 'error_language_unavailable') {
      msg = 'Máy chưa có gói nhận dạng tiếng Việt. Tải trong Cài đặt Android → Google → Nhập liệu bằng giọng nói, hoặc bật chip "Offline (Sherpa)".';
    }
    _fail(msg);
  }

  // ------------------------------------------------------------ đàm thoại
  void Function(String text)? _handsFreeSend;

  Future<void> startHandsFree(void Function(String text) send) async {
    _handsFreeSend = send;
    handsFree = true;
    _empty = 0;
    if (!autoSpeak) await setAutoSpeak(true);
    handsFree = true;
    notifyListeners();
    await startListening(send);
  }

  Future<void> stopHandsFree() async {
    handsFree = false;
    _handsFreeSend = null;
    await cancelListening();
    await stopSpeaking();
    notifyListeners();
  }

  void _relistenSoon() {
    Future<void>.delayed(const Duration(milliseconds: 600), _maybeRelisten);
  }

  /// Nghe tiếp khi: đang đàm thoại, model đã trả lời xong và Yui đã đọc xong (tránh mic thu lại tiếng loa).
  void _maybeRelisten() {
    final send = _handsFreeSend;
    if (!handsFree || send == null) return;
    if (app.generating || speaking || listening || _queue.isNotEmpty || _pumping) return;
    Future<void>.delayed(const Duration(milliseconds: 600), () {
      if (handsFree && !app.generating && !speaking && !listening) unawaited(startListening(send));
    });
  }
}

final VoiceService voice = VoiceService();
