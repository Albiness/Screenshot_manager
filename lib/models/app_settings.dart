class AppSettings {
  const AppSettings({
    this.autoCopy = true,
    this.autoOcr = true,
    this.delaySeconds = 0,
  });

  /// Сразу после съёмки класть снимок в буфер обмена (можно вставить Ctrl+V).
  final bool autoCopy;

  /// Автоматически распознавать текст в фоне после сохранения.
  final bool autoOcr;

  /// Задержка перед съёмкой, секунды (удобно для меню и подсказок).
  final int delaySeconds;

  AppSettings copyWith({
    bool? autoCopy,
    bool? autoOcr,
    int? delaySeconds,
  }) {
    return AppSettings(
      autoCopy: autoCopy ?? this.autoCopy,
      autoOcr: autoOcr ?? this.autoOcr,
      delaySeconds: delaySeconds ?? this.delaySeconds,
    );
  }
}
