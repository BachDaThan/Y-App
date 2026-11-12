import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as so;

/// Nhận dạng giọng nói tiếng Việt OFFLINE 100% bằng Sherpa-ONNX.
/// Mic (16 kHz) -> Silero VAD cắt câu -> Zipformer-vi-30M (int8) -> chữ. Không gửi âm thanh đi đâu cả.
/// Model tải MỘT lần từ GitHub (k2-fsa/sherpa-onnx, tag asr-models) rồi lưu trong thư mục dữ liệu của app.
/// Chạy trong isolate: giải nén .tar.bz2 -> chỉ giữ *.onnx và tokens.txt, phẳng vào [args[1]].
void _extractModel(List<String> args) {
  final tmp = args[0], dir = args[1];
  final bytes = File(tmp).readAsBytesSync();
  final tar = TarDecoder().decodeBytes(BZip2Decoder().decodeBytes(bytes));
  for (final f in tar.files) {
    if (!f.isFile) continue;
    final name = f.name.split('/').last;
    if (name.isEmpty || name.startsWith('.')) continue;
    if (name.endsWith('.onnx') || name == 'tokens.txt') {
      File('$dir${Platform.pathSeparator}$name').writeAsBytesSync(f.content as List<int>);
    }
  }
  File(tmp).deleteSync();
}

class SherpaStt {
  static const _base = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/';
  static const _modelName = 'sherpa-onnx-zipformer-vi-30M-int8-2026-02-09';
  static const _vadFile = 'silero_vad.onnx';
  static const _rate = 16000;

  so.OfflineRecognizer? _rec;
  so.VoiceActivityDetector? _vad;
  final AudioRecorder _mic = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  Timer? _tick;
  bool _bindings = false;

  bool running = false;
  bool get loaded => _rec != null && _vad != null;

  Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}stt');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<String> _p(String name) async => '${(await _dir()).path}${Platform.pathSeparator}$name';

  Future<bool> isInstalled() async {
    for (final f in ['encoder.int8.onnx', 'decoder.onnx', 'joiner.int8.onnx', 'tokens.txt', _vadFile]) {
      if (!await File(await _p(f)).exists()) return false;
    }
    return true;
  }

  Future<void> _download(String url, String dest, void Function(double) onProgress) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close(); // tự theo chuyển hướng của GitHub
      if (res.statusCode != 200) throw 'HTTP ${res.statusCode} khi tải $url';
      final total = res.contentLength;
      final out = File(dest).openWrite();
      var got = 0;
      await for (final chunk in res) {
        out.add(chunk);
        got += chunk.length;
        if (total > 0) onProgress(got / total);
      }
      await out.close();
    } finally {
      client.close();
    }
  }

  /// Tải model + VAD (khoảng vài chục MB). [onProgress] 0..1.
  Future<void> install(void Function(double) onProgress) async {
    final dir = await _dir();
    final tmp = '${dir.path}${Platform.pathSeparator}_model.tar.bz2';
    await _download('$_base$_modelName.tar.bz2', tmp, (p) => onProgress(p * 0.85));
    final dirPath = dir.path;
    // Giải nén bằng compute() + hàm top-level (KHÔNG dùng closure trong hàm async: nó kéo theo cả WidgetsFlutterBinding nên isolate từ chối)
    await compute(_extractModel, <String>[tmp, dirPath]);
    onProgress(0.9);
    await _download('$_base$_vadFile', await _p(_vadFile), (p) => onProgress(0.9 + p * 0.1));
    if (!await isInstalled()) {
      throw 'Tải xong nhưng thiếu file model (tên file trong gói có thể đã đổi).';
    }
    onProgress(1);
  }

  Future<void> uninstall() async {
    await stop();
    _free();
    final d = await _dir();
    if (await d.exists()) await d.delete(recursive: true);
  }

  Future<void> load() async {
    if (loaded) return;
    if (!_bindings) {
      so.initBindings();
      _bindings = true;
    }
    final recCfg = so.OfflineRecognizerConfig(
      model: so.OfflineModelConfig(
        transducer: so.OfflineTransducerModelConfig(
          encoder: await _p('encoder.int8.onnx'),
          decoder: await _p('decoder.onnx'),
          joiner: await _p('joiner.int8.onnx'),
        ),
        tokens: await _p('tokens.txt'),
        numThreads: 2,
        debug: false,
      ),
    );
    _rec = so.OfflineRecognizer(recCfg);
    final vadCfg = so.VadModelConfig(
      sileroVad: so.SileroVadModelConfig(
        model: await _p(_vadFile),
        minSilenceDuration: 0.4,
        minSpeechDuration: 0.25,
        maxSpeechDuration: 20,
      ),
      sampleRate: _rate,
      numThreads: 1,
      debug: false,
    );
    _vad = so.VoiceActivityDetector(config: vadCfg, bufferSizeInSeconds: 30);
  }

  void _free() {
    _rec?.free();
    _vad?.free();
    _rec = null;
    _vad = null;
  }

  String _decode(Float32List samples) {
    final r = _rec!;
    final s = r.createStream();
    s.acceptWaveform(samples: samples, sampleRate: _rate);
    r.decode(s);
    final t = r.getResult(s).text.trim();
    s.free();
    return t;
  }

  /// Nghe tới khi người nói dứt câu (im ~1 giây), rồi gọi [onFinal] đúng một lần.
  /// [onPartial] nhận chữ đã nhận được trong lúc nói. Trả false nếu không mở được mic.
  Future<bool> start({
    required void Function(String text) onPartial,
    required void Function(String text) onFinal,
    Duration endSilence = const Duration(milliseconds: 1000),
    Duration noSpeechTimeout = const Duration(seconds: 8),
    Duration maxTotal = const Duration(seconds: 45),
  }) async {
    if (running) return true;
    await load();
    if (!await _mic.hasPermission()) return false;
    _vad!.reset();
    running = true;
    final text = StringBuffer();
    var lastSpeech = DateTime.now();
    final began = DateTime.now();
    var done = false;

    Future<void> finish() async {
      if (done) return;
      done = true;
      await _halt();
      onFinal(text.toString().trim());
    }

    void drain() {
      final vad = _vad!;
      while (!vad.isEmpty()) {
        final seg = vad.front();
        vad.pop();
        final t = _decode(seg.samples);
        if (t.isNotEmpty) {
          if (text.isNotEmpty) text.write(' ');
          text.write(t);
          onPartial(text.toString());
        }
        lastSpeech = DateTime.now();
      }
    }

    final stream = await _mic.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: _rate,
      numChannels: 1,
    ));
    _sub = stream.listen((data) {
      if (done) return;
      final n = data.length ~/ 2;
      final f = Float32List(n);
      final bd = ByteData.sublistView(data);
      for (var i = 0; i < n; i++) {
        f[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
      }
      _vad!.acceptWaveform(f);
      drain();
      if (_vad!.isDetected()) lastSpeech = DateTime.now();
    });
    _tick = Timer.periodic(const Duration(milliseconds: 150), (_) {
      if (done) return;
      final now = DateTime.now();
      final has = text.isNotEmpty;
      if (has && !_vad!.isDetected() && now.difference(lastSpeech) > endSilence) finish();
      if (!has && now.difference(began) > noSpeechTimeout) finish();
      if (now.difference(began) > maxTotal) {
        _vad!.flush();
        drain();
        finish();
      }
    });
    _finishNow = () async {
      _vad?.flush();
      drain();
      await finish();
    };
    return true;
  }

  Future<void> Function()? _finishNow;

  /// Người dùng bấm "Xong": lấy nốt phần đang nói rồi trả kết quả.
  Future<void> stop() async {
    final f = _finishNow;
    _finishNow = null;
    if (running && f != null) {
      await f();
    } else {
      await _halt();
    }
  }

  /// Huỷ, không trả kết quả.
  Future<void> cancel() async {
    _finishNow = null;
    await _halt();
  }

  Future<void> _halt() async {
    _tick?.cancel();
    _tick = null;
    await _sub?.cancel();
    _sub = null;
    try {
      if (await _mic.isRecording()) await _mic.stop();
    } catch (_) {}
    running = false;
  }
}
