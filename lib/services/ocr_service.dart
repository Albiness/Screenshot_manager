import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:platform_ocr/platform_ocr.dart';

class OcrReadResult {
  const OcrReadResult({required this.text, this.error});

  final String text;
  final String? error;

  bool get succeeded => error == null;
}

class OcrService {
  final PlatformOcr _ocr = PlatformOcr();

  /// Распознаёт текст. Тяжёлая подготовка картинки идёт в отдельном изоляте,
  /// а сам вызов ограничен по времени — приложение не «зависает» на больших
  /// 4K-снимках.
  Future<OcrReadResult> recognize(File imageFile) async {
    File? prepared;
    try {
      final preparedPath = await compute(_prepareImageForOcr, imageFile.path);
      if (preparedPath != null) prepared = File(preparedPath);

      final result = await _ocr
          .recognizeText(OcrSource.file(prepared ?? imageFile))
          .timeout(const Duration(seconds: 45));
      return OcrReadResult(text: result.text.trim());
    } catch (error) {
      return OcrReadResult(text: '', error: error.toString());
    } finally {
      if (prepared != null) {
        try {
          await prepared.delete();
        } catch (_) {}
      }
    }
  }
}

/// Windows OCR плохо работает с огромными (>2600 px) и с очень маленькими
/// картинками. Большие уменьшаем, маленькие увеличиваем.
/// Возвращает путь к временному файлу или null, если исходник годится как есть.
String? _prepareImageForOcr(String path) {
  final image = img.decodeImage(File(path).readAsBytesSync());
  if (image == null) return null;

  final longest = math.max(image.width, image.height);
  double scale = 1;
  if (longest > 2500) {
    scale = 2500 / longest;
  } else if (longest < 900) {
    scale = 2;
  }
  if (scale == 1) return null;

  final resized = img.copyResize(
    image,
    width: math.max(1, (image.width * scale).round()),
    height: math.max(1, (image.height * scale).round()),
    interpolation: scale > 1 ? img.Interpolation.cubic : img.Interpolation.average,
  );

  final out = File(
    p.join(
      Directory.systemTemp.path,
      'ssm_ocr_${DateTime.now().microsecondsSinceEpoch}.png',
    ),
  );
  out.writeAsBytesSync(img.encodePng(resized));
  return out.path;
}
