import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'native_capture_script.dart';

enum CaptureMode {
  /// Выделение области с редактором (перо, стрелки, мозаика, текст…).
  region,

  /// Весь монитор, на котором сейчас курсор.
  screen,

  /// Все мониторы одним снимком.
  allScreens,

  /// Выделить область и достать из неё текст (снимок не сохраняется).
  text,
}

enum CaptureStatus { saved, cancelled, failed }

class CaptureResult {
  const CaptureResult._(this.status, {this.file, this.error});

  const CaptureResult.saved(File file)
      : this._(CaptureStatus.saved, file: file);
  const CaptureResult.cancelled() : this._(CaptureStatus.cancelled);
  const CaptureResult.failed(String error)
      : this._(CaptureStatus.failed, error: error);

  final CaptureStatus status;
  final File? file;
  final String? error;
}

class _NativeResult {
  const _NativeResult(this.status, [this.detail]);

  final String status; // ok | cancel | error
  final String? detail;

  bool get ok => status == 'ok';
  bool get cancelled => status == 'cancel';
}

/// Захват экрана на Windows. Снимок и выбор области делает отдельный процесс
/// (см. native_capture_script.dart), а Flutter-окно только прячется на время
/// съёмки — никаких fullscreen-переключений и тяжёлой работы с PNG в UI.
class ScreenshotService {
  String? lastError;

  Future<Directory> getScreenshotDirectory() async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final directory = Directory(
      p.join(documentsDirectory.path, 'SmartScreenshotManager', 'screenshots'),
    );
    await directory.create(recursive: true);
    return directory;
  }

  /// Компилирует нативный оверлей заранее, чтобы первая съёмка не тормозила.
  Future<void> warmUp() async {
    if (!Platform.isWindows) return;
    try {
      await _runNative(mode: 'warm', timeout: const Duration(minutes: 2));
    } catch (error) {
      debugPrint('Native warm-up failed: $error');
    }
  }

  Future<CaptureResult> capture(
    CaptureMode mode, {
    bool copyToClipboard = false,
    int delaySeconds = 0,
  }) async {
    lastError = null;
    if (!Platform.isWindows) {
      return const CaptureResult.failed(
        'Эта версия захвата поддерживает только Windows.',
      );
    }

    final output = mode == CaptureMode.text
        ? await _newTempFile()
        : await _newScreenshotFile();

    var hidden = false;
    try {
      // Если окно свёрнуто, его и так нет на экране — трогать не нужно.
      final minimized = await _safeBool(windowManager.isMinimized, false);
      final visible = await _safeBool(windowManager.isVisible, true);
      if (visible && !minimized) {
        await windowManager.hide();
        hidden = true;
        // Дать Windows доиграть анимацию скрытия, чтобы окно не попало в кадр.
        await Future<void>.delayed(const Duration(milliseconds: 320));
      }

      if (delaySeconds > 0) {
        await Future<void>.delayed(Duration(seconds: delaySeconds));
      }

      final result = await _runNative(
        mode: _modeName(mode),
        target: output.path,
        copy: copyToClipboard,
      );

      if (result.cancelled) {
        await deleteTemporaryFile(output);
        return const CaptureResult.cancelled();
      }
      if (!result.ok) {
        await deleteTemporaryFile(output);
        lastError = result.detail;
        return CaptureResult.failed(result.detail ?? 'неизвестная ошибка');
      }
      if (!await output.exists() || await output.length() == 0) {
        lastError = 'Windows не создала файл снимка.';
        return CaptureResult.failed(lastError!);
      }
      return CaptureResult.saved(output);
    } catch (error, stackTrace) {
      debugPrint('Screenshot capture failed: $error\n$stackTrace');
      lastError = error.toString();
      await deleteTemporaryFile(output);
      return CaptureResult.failed(error.toString());
    } finally {
      if (hidden) await _restoreWindow();
    }
  }

  /// Копирует готовый PNG в буфер обмена как изображение.
  /// Возвращает null при успехе или текст ошибки.
  Future<String?> copyImageToClipboard(File file) async {
    if (!Platform.isWindows) return 'Только Windows.';
    final result = await _runNative(
      mode: 'clip',
      target: file.path,
      timeout: const Duration(seconds: 30),
    );
    return result.ok ? null : (result.detail ?? 'неизвестная ошибка');
  }

  Future<void> deleteTemporaryFile(File? file) async {
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (error) {
      debugPrint('Temporary screenshot cleanup failed: $error');
    }
  }

  String _modeName(CaptureMode mode) {
    switch (mode) {
      case CaptureMode.region:
        return 'region';
      case CaptureMode.screen:
        return 'screen';
      case CaptureMode.allScreens:
        return 'all';
      case CaptureMode.text:
        return 'text';
    }
  }

  Future<bool> _safeBool(Future<bool> Function() read, bool fallback) async {
    try {
      return await read();
    } catch (_) {
      return fallback;
    }
  }

  Future<void> _restoreWindow() async {
    try {
      await windowManager.show();
      // Кратковременный always-on-top надёжно выводит окно вперёд даже если
      // Windows не даёт фокус процессу, не владеющему активным окном.
      await windowManager.setAlwaysOnTop(true);
      await windowManager.focus();
      await windowManager.setAlwaysOnTop(false);
    } catch (error) {
      debugPrint('Failed to restore application window: $error');
    }
  }

  Future<_NativeResult> _runNative({
    required String mode,
    String? target,
    bool copy = false,
    Duration timeout = const Duration(minutes: 3),
  }) async {
    final temp = await getTemporaryDirectory();
    final resultFile = File(
      p.join(
        temp.path,
        'ssm_result_${DateTime.now().microsecondsSinceEpoch}.txt',
      ),
    );

    try {
      final paths = await NativeCapture.ensureInstalled();

      final process = await Process.start(
        'powershell.exe',
        <String>[
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-STA',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-File',
          paths.scriptPath,
        ],
        environment: <String, String>{
          'SSM_MODE': mode,
          'SSM_OUT': target ?? '',
          'SSM_COPY': copy ? '1' : '0',
          'SSM_RESULT': resultFile.path,
          'SSM_DLL': paths.dllPath,
        },
        includeParentEnvironment: true,
        runInShell: false,
      );

      // Обязательно вычитываем потоки, иначе процесс может зависнуть на записи.
      final stderrBuffer = StringBuffer();
      final stderrSub = process.stderr
          .transform(systemEncoding.decoder)
          .listen(stderrBuffer.write);
      unawaited(process.stdout.drain<void>());

      var timedOut = false;
      final exitCode = await process.exitCode.timeout(
        timeout,
        onTimeout: () {
          timedOut = true;
          process.kill();
          return -1;
        },
      );
      await stderrSub.cancel();

      String? text;
      if (await resultFile.exists()) {
        text = (await resultFile.readAsString()).trim();
      }

      if (text == 'ok') return const _NativeResult('ok');
      if (text == 'cancel') return const _NativeResult('cancel');
      if (timedOut) {
        return const _NativeResult('error', 'Превышено время ожидания.');
      }

      var detail = '';
      if (text != null && text.isNotEmpty) {
        detail = text.replaceFirst(RegExp(r'^error:\s*'), '');
      } else if (stderrBuffer.toString().trim().isNotEmpty) {
        detail = stderrBuffer.toString().trim();
      } else {
        detail = 'PowerShell завершился с кодом $exitCode.';
      }
      return _NativeResult('error', _shorten(detail));
    } catch (error) {
      return _NativeResult('error', _shorten(error.toString()));
    } finally {
      try {
        if (await resultFile.exists()) await resultFile.delete();
      } catch (_) {}
    }
  }

  String _shorten(String value) {
    final single = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return single.length <= 400 ? single : '${single.substring(0, 400)}…';
  }

  Future<File> _newScreenshotFile() async {
    final directory = await getScreenshotDirectory();
    final stamp = DateFormat('yyyyMMdd_HHmmss_SSS').format(DateTime.now());
    return File(p.join(directory.path, 'screenshot_$stamp.png'));
  }

  Future<File> _newTempFile() async {
    final directory = await getTemporaryDirectory();
    final stamp = DateFormat('yyyyMMdd_HHmmss_SSS').format(DateTime.now());
    return File(p.join(directory.path, 'ssm_text_$stamp.png'));
  }
}
