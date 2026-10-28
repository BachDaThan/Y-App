// engine.dart - cầu nối Dart <-> engine C++ (libyui.so / yui.dll) qua FFI.
// Mọi lời gọi nặng (nạp model, sinh chữ) chạy trong một isolate riêng nên giao diện không bị đứng.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

class GenOptions {
  final double temperature;
  final int topK;
  final double topP;
  final double repeatPenalty;
  final int k; // số expert dùng: 1 nhanh hơn, 2 chất lượng hơn
  final int maxNew;
  const GenOptions({
    this.temperature = 0.8,
    this.topK = 40,
    this.topP = 0.95,
    this.repeatPenalty = 1.1,
    this.k = 2,
    this.maxNew = 120,
  });

  String toJson() => jsonEncode({
        'temperature': temperature,
        'top_k': topK,
        'top_p': topP,
        'repeat_penalty': repeatPenalty,
        'num_predict': maxNew,
        'k': k,
      });
}

abstract class GenEvent {
  const GenEvent();
}

class GenChunk extends GenEvent {
  final String text;
  const GenChunk(this.text);
}

class GenDone extends GenEvent {
  final int tokens;
  final int millis;
  final bool cancelled;
  const GenDone(this.tokens, this.millis, this.cancelled);
}

class GenError extends GenEvent {
  final String message;
  const GenError(this.message);
}

class GenSession {
  final int id;
  final Stream<GenEvent> events;
  final void Function() cancel;
  GenSession(this.id, this.events, this.cancel);
}

class YuiEngine {
  Isolate? _isolate;
  SendPort? _tx;
  ReceivePort? _rx;
  bool _started = false;
  Future<void>? _starting;
  int _nextId = 1;
  final Map<int, StreamController<List<dynamic>>> _pending = {};

  Future<void> _ensureStarted() {
    if (_started) return Future<void>.value();
    return _starting ??= _start();
  }

  Future<void> _start() async {
    final rx = ReceivePort();
    _rx = rx;
    final ready = Completer<SendPort>();
    rx.listen((dynamic msg) {
      if (msg is SendPort) {
        if (!ready.isCompleted) ready.complete(msg);
        return;
      }
      if (msg is List && msg.isNotEmpty && msg[0] is int) {
        _pending[msg[0] as int]?.add(msg);
      }
    });
    _isolate = await Isolate.spawn(_workerMain, rx.sendPort);
    _tx = await ready.future;
    _started = true;
  }

  Future<List<dynamic>> _call(List<dynamic> Function(int id) build) async {
    await _ensureStarted();
    final id = _nextId++;
    final c = StreamController<List<dynamic>>();
    _pending[id] = c;
    _tx!.send(build(id));
    final msg = await c.stream.first;
    _pending.remove(id);
    await c.close();
    if (msg[1] == 'error') throw Exception(msg[2]);
    return msg;
  }

  /// Nạp một file .yui (giải phóng model cũ trước). Trả về thông tin model.
  Future<Map<String, dynamic>> load(String path) async {
    final m = await _call((id) => ['load', id, path]);
    return jsonDecode(m[2] as String) as Map<String, dynamic>;
  }

  Future<void> unload() async {
    await _call((id) => ['unload', id]);
  }

  /// Chat theo định dạng SFT. messages = [{role, content}, ...], tin cuối phải là của user.
  GenSession chat(List<Map<String, String>> messages, GenOptions o) => _gen(true, jsonEncode(messages), o);

  /// Viết tiếp văn bản thuần (không phải chat).
  GenSession complete(String prompt, GenOptions o) => _gen(false, prompt, o);

  GenSession _gen(bool chat, String input, GenOptions o) {
    final id = _nextId++;
    final ctl = StreamController<GenEvent>();
    final inbox = StreamController<List<dynamic>>();
    _pending[id] = inbox;
    () async {
      try {
        await _ensureStarted();
        _tx!.send(['gen', id, chat, input, o.toJson(), o.k]);
        await for (final m in inbox.stream) {
          final type = m[1] as String;
          if (type == 'chunk') {
            ctl.add(GenChunk(m[2] as String));
          } else if (type == 'done') {
            ctl.add(GenDone(m[2] as int, m[3] as int, m[4] as bool));
            return;
          } else if (type == 'error') {
            ctl.add(GenError(m[2] as String));
            return;
          }
        }
      } catch (e) {
        ctl.add(GenError('$e'));
      } finally {
        _pending.remove(id);
        await inbox.close();
        await ctl.close();
      }
    }();
    return GenSession(id, ctl.stream, () => _tx?.send(['cancel', id]));
  }

  /// Chọn số luồng CPU cho engine (0 = tự chọn). Trả về mô tả CPU, vd "neon+dotprod, 4 thread".
  Future<String> setThreads(int n) async {
    final m = await _call((id) => ['threads', id, n]);
    return m[2] as String;
  }

  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _rx?.close();
  }
}

// ====================== phần chạy trong isolate nền ======================

typedef _LoadN = Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _LoadD = Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>, int);
typedef _FreeN = Void Function(Pointer<Void>);
typedef _FreeD = void Function(Pointer<Void>);
typedef _InfoN = Int32 Function(Pointer<Void>, Pointer<Utf8>, Int32);
typedef _InfoD = int Function(Pointer<Void>, Pointer<Utf8>, int);
typedef _BeginN = Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Int32, Pointer<Utf8>, Int32);
typedef _BeginD = Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, int, Pointer<Utf8>, int);
typedef _NextN = Int32 Function(Pointer<Void>, Pointer<Utf8>, Int32);
typedef _NextD = int Function(Pointer<Void>, Pointer<Utf8>, int);
typedef _ThreadsN = Void Function(Int32);
typedef _ThreadsD = void Function(int);
typedef _FeatN = Int32 Function(Pointer<Utf8>, Int32);
typedef _FeatD = int Function(Pointer<Utf8>, int);
typedef _TokN = Int32 Function(Pointer<Void>);
typedef _TokD = int Function(Pointer<Void>);

class _Native {
  final DynamicLibrary lib;
  late final _LoadD load = lib.lookupFunction<_LoadN, _LoadD>('yui_load');
  late final _FreeD free = lib.lookupFunction<_FreeN, _FreeD>('yui_free');
  late final _InfoD info = lib.lookupFunction<_InfoN, _InfoD>('yui_info');
  late final _BeginD chatBegin = lib.lookupFunction<_BeginN, _BeginD>('yui_chat_begin');
  late final _BeginD completeBegin = lib.lookupFunction<_BeginN, _BeginD>('yui_complete_begin');
  late final _NextD next = lib.lookupFunction<_NextN, _NextD>('yui_gen_next');
  late final _TokD tokens = lib.lookupFunction<_TokN, _TokD>('yui_gen_tokens');
  late final _FreeD end = lib.lookupFunction<_FreeN, _FreeD>('yui_gen_end');
  late final _ThreadsD setThreads = lib.lookupFunction<_ThreadsN, _ThreadsD>('yui_set_threads');
  late final _FeatD features = lib.lookupFunction<_FeatN, _FeatD>('yui_cpu_features');

  _Native(this.lib);

  static _Native open() {
    DynamicLibrary lib;
    if (Platform.isAndroid || Platform.isLinux) {
      lib = DynamicLibrary.open('libyui.so');
    } else if (Platform.isWindows) {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final p = '$exeDir${Platform.pathSeparator}yui.dll';
      lib = DynamicLibrary.open(File(p).existsSync() ? p : 'yui.dll');
    } else {
      throw UnsupportedError('Nền tảng này chưa được hỗ trợ');
    }
    return _Native(lib);
  }
}

void _workerMain(SendPort toMain) {
  final rx = ReceivePort();
  toMain.send(rx.sendPort);
  final w = _Worker(toMain);
  rx.listen((dynamic m) => w.handle(m as List<dynamic>));
}

class _Worker {
  final SendPort out;
  _Worker(this.out);

  _Native? _n;
  Pointer<Void> _model = nullptr;
  final Set<int> _cancelled = {};
  bool _busy = false;

  _Native get n => _n ??= _Native.open();

  void handle(List<dynamic> m) {
    switch (m[0] as String) {
      case 'load':
        _load(m[1] as int, m[2] as String);
        break;
      case 'unload':
        _unloadNow();
        out.send([m[1] as int, 'ok', '']);
        break;
      case 'gen':
        _gen(m[1] as int, m[2] as bool, m[3] as String, m[4] as String, m[5] as int);
        break;
      case 'cancel':
        _cancelled.add(m[1] as int);
        break;
      case 'threads':
        _threads(m[1] as int, m[2] as int);
        break;
    }
  }

  void _threads(int id, int count) {
    try {
      n.setThreads(count);
      final buf = calloc<Uint8>(128);
      final k = n.features(buf.cast<Utf8>(), 128);
      final info = k > 0 ? buf.cast<Utf8>().toDartString() : '';
      calloc.free(buf);
      out.send([id, 'ok', info]);
    } catch (e) {
      out.send([id, 'error', '$e']);
    }
  }

  void _unloadNow() {
    if (_model != nullptr) {
      n.free(_model);
      _model = nullptr;
    }
  }

  void _load(int id, String path) {
    if (_busy) {
      out.send([id, 'error', 'Engine đang bận sinh chữ']);
      return;
    }
    final err = calloc<Uint8>(512);
    try {
      _unloadNow();
      final p = path.toNativeUtf8();
      final h = n.load(p, err.cast<Utf8>(), 512);
      malloc.free(p);
      if (h == nullptr) {
        out.send([id, 'error', err.cast<Utf8>().toDartString()]);
        return;
      }
      _model = h;
      final buf = calloc<Uint8>(1024);
      final k = n.info(h, buf.cast<Utf8>(), 1024);
      final info = k > 0 ? buf.cast<Utf8>().toDartString() : '{}';
      calloc.free(buf);
      out.send([id, 'loaded', info]);
    } catch (e) {
      out.send([id, 'error', '$e']);
    } finally {
      calloc.free(err);
    }
  }

  Future<void> _gen(int id, bool chat, String input, String optsJson, int k) async {
    if (_busy) {
      out.send([id, 'error', 'Engine đang bận']);
      return;
    }
    if (_model == nullptr) {
      out.send([id, 'error', 'Chưa nạp model']);
      return;
    }
    _busy = true;
    final err = calloc<Uint8>(512);
    final buf = calloc<Uint8>(4096);
    Pointer<Void> g = nullptr;
    final sw = Stopwatch()..start();
    var cancelled = false;
    try {
      final inP = input.toNativeUtf8();
      final optP = optsJson.toNativeUtf8();
      g = (chat ? n.chatBegin : n.completeBegin)(_model, inP, optP, k, err.cast<Utf8>(), 512);
      malloc.free(inP);
      malloc.free(optP);
      if (g == nullptr) {
        out.send([id, 'error', err.cast<Utf8>().toDartString()]);
        return;
      }
      while (true) {
        if (_cancelled.remove(id)) {
          cancelled = true;
          break;
        }
        final r = n.next(g, buf.cast<Utf8>(), 4096);
        if (r < 0) {
          out.send([id, 'error', 'Lỗi engine ($r)']);
          return;
        }
        if (r == 0) break;
        out.send([id, 'chunk', utf8.decode(buf.asTypedList(r), allowMalformed: true)]);
        // nhường event loop để nhận lệnh huỷ giữa chừng
        await Future<void>.delayed(Duration.zero);
      }
      out.send([id, 'done', n.tokens(g), sw.elapsedMilliseconds, cancelled]);
    } catch (e) {
      out.send([id, 'error', '$e']);
    } finally {
      if (g != nullptr) n.end(g);
      calloc.free(buf);
      calloc.free(err);
      _cancelled.remove(id);
      _busy = false;
    }
  }
}
