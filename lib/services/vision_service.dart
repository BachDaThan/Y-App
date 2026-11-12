import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../engine.dart';

/// Xem ảnh: ảnh -> (resize 224x224, chuẩn hoá [-1,1]) -> model .onnx (SigLIP + projector, chạy trong engine bằng ONNX Runtime của Sherpa)
/// -> embedding ảnh -> engine gắn vào tin user. Chỉ có tác dụng với model .yui đã train ảnh bằng train_vision.py.
class VisionService extends ChangeNotifier {
  bool _loaded = false;

  Future<File> _modelFile() async {
    final d = Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}vision');
    if (!await d.exists()) await d.create(recursive: true);
    return File('${d.path}${Platform.pathSeparator}yui-vision.onnx');
  }

  Future<bool> installed() async => (await _modelFile()).exists();

  /// Chép file .onnx người dùng chọn vào thư mục của app. [deleteSrc]: xoá bản tạm do file_picker sao chép.
  Future<void> importModel(String src, {bool deleteSrc = false}) async {
    final dst = await _modelFile();
    if (await dst.exists()) await dst.delete();
    await File(src).copy(dst.path);
    if (deleteSrc) {
      try {
        await File(src).delete();
      } catch (_) {}
    }
    _loaded = false;
    notifyListeners();
  }

  Future<void> remove(YuiEngine e) async {
    try {
      await e.unloadVision();
    } catch (_) {}
    final f = await _modelFile();
    if (await f.exists()) await f.delete();
    _loaded = false;
    notifyListeners();
  }

  Future<void> _ensureLoaded(YuiEngine e) async {
    if (_loaded) return;
    await e.loadVision((await _modelFile()).path);
    _loaded = true;
  }

  /// Trả embedding ảnh phẳng (N*D float). Ném lỗi (chữ tiếng Việt) nếu không nạp/chạy được.
  Future<Float32List> encode(YuiEngine e, String imagePath) async {
    await _ensureLoaded(e);
    final chw = await compute(_prep, imagePath);
    return e.encodeImage(chw);
  }
}

const int _size = 224;

/// Chạy trong isolate: đọc ảnh, xoay theo EXIF, resize thẳng 224x224 (như SigLIP), CHW float [-1,1].
Float32List _prep(String path) {
  var im = img.decodeImage(File(path).readAsBytesSync());
  if (im == null) throw Exception('Không đọc được ảnh (định dạng không hỗ trợ)');
  im = img.bakeOrientation(im);
  im = img.copyResize(im, width: _size, height: _size, interpolation: img.Interpolation.average);
  final out = Float32List(3 * _size * _size);
  const plane = _size * _size;
  for (var y = 0; y < _size; y++) {
    for (var x = 0; x < _size; x++) {
      final p = im.getPixel(x, y);
      final o = y * _size + x;
      out[o] = (p.r / 255.0 - 0.5) / 0.5;
      out[plane + o] = (p.g / 255.0 - 0.5) / 0.5;
      out[2 * plane + o] = (p.b / 255.0 - 0.5) / 0.5;
    }
  }
  return out;
}

final VisionService vision = VisionService();
