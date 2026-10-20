import 'dart:async';

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

class HotkeyService {
  final List<HotKey> _registered = <HotKey>[];

  /// Регистрирует глобальные горячие клавиши.
  /// Возвращает список ошибок (например, если сочетание занято другой программой);
  /// сбой одной клавиши не мешает остальным.
  Future<List<String>> register({
    required Future<void> Function() onRegion,
    required Future<void> Function() onText,
  }) async {
    await hotKeyManager.unregisterAll();
    _registered.clear();
    final errors = <String>[];

    Future<void> add(
      String label,
      HotKey hotKey,
      Future<void> Function() handler,
    ) async {
      try {
        await hotKeyManager.register(
          hotKey,
          keyDownHandler: (_) {
            unawaited(handler());
          },
        );
        _registered.add(hotKey);
      } catch (error) {
        errors.add('$label ($error)');
      }
    }

    await add(
      'Ctrl+Shift+S',
      HotKey(
        key: PhysicalKeyboardKey.keyS,
        modifiers: <HotKeyModifier>[
          HotKeyModifier.control,
          HotKeyModifier.shift,
        ],
        scope: HotKeyScope.system,
      ),
      onRegion,
    );

    await add(
      'Ctrl+Alt+X',
      HotKey(
        key: PhysicalKeyboardKey.keyX,
        modifiers: <HotKeyModifier>[
          HotKeyModifier.control,
          HotKeyModifier.alt,
        ],
        scope: HotKeyScope.system,
      ),
      onText,
    );

    return errors;
  }

  Future<void> dispose() async {
    for (final hotKey in _registered) {
      try {
        await hotKeyManager.unregister(hotKey);
      } catch (_) {}
    }
    _registered.clear();
  }
}
