import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_file/open_file.dart';
import 'package:path/path.dart' as p;

import '../models/app_settings.dart';
import '../models/screenshot_item.dart';
import '../services/database_service.dart';
import '../services/hotkey_service.dart';
import '../services/ocr_service.dart';
import '../services/screenshot_service.dart';
import '../widgets/details_panel.dart';
import '../widgets/screenshot_list_tile.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final DatabaseService _databaseService = DatabaseService();
  final ScreenshotService _screenshotService = ScreenshotService();
  final OcrService _ocrService = OcrService();
  final HotkeyService _hotkeyService = HotkeyService();
  final TextEditingController _searchController = TextEditingController();

  List<ScreenshotItem> _items = <ScreenshotItem>[];
  ScreenshotItem? _selected;
  AppSettings _settings = const AppSettings();
  Timer? _searchDebounce;
  bool _favoritesOnly = false;
  bool _loading = true;

  /// true только пока идёт съёмка/удаление. OCR сюда НЕ входит: он работает
  /// в фоне, и приложение остаётся отзывчивым.
  bool _busy = false;

  /// id снимков, для которых OCR ещё выполняется.
  final Set<int> _ocrPending = <int>{};
  Future<void> _ocrChain = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_init());
    });
  }

  Future<void> _init() async {
    try {
      final settings = await _databaseService.loadSettings();
      if (mounted) setState(() => _settings = settings);
    } catch (error) {
      debugPrint('Не удалось прочитать настройки: $error');
    }

    await _loadScreenshots();

    // Компиляция нативного оверлея в фоне: первая съёмка не будет тормозить.
    unawaited(_screenshotService.warmUp());

    try {
      final errors = await _hotkeyService.register(
        onRegion: () => _startCapture(CaptureMode.region),
        onText: () => _startCapture(CaptureMode.text),
      );
      if (errors.isNotEmpty && mounted) {
        _showMessage(
          'Не удалось зарегистрировать горячие клавиши (заняты другой программой?): '
          '${errors.join('; ')}',
        );
      }
    } catch (error) {
      if (mounted) {
        _showMessage('Не удалось зарегистрировать горячие клавиши: $error');
      }
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController
      ..removeListener(_onSearchChanged)
      ..dispose();
    unawaited(_hotkeyService.dispose());
    unawaited(_databaseService.close());
    super.dispose();
  }

  void _onSearchChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(
      const Duration(milliseconds: 220),
      _loadScreenshots,
    );
    // Чтобы крестик «очистить» и подсветка в деталях обновлялись сразу.
    if (mounted) setState(() {});
  }

  Future<void> _loadScreenshots() async {
    if (!mounted) {
      return;
    }

    setState(() => _loading = true);

    try {
      final items = await _databaseService.getScreenshots(
        search: _searchController.text,
        favoritesOnly: _favoritesOnly,
      );

      ScreenshotItem? nextSelected;
      final previousSelectedId = _selected?.id;
      if (previousSelectedId != null) {
        for (final item in items) {
          if (item.id == previousSelectedId) {
            nextSelected = item;
            break;
          }
        }
      }
      nextSelected ??= items.isNotEmpty ? items.first : null;

      if (!mounted) {
        return;
      }

      setState(() {
        _items = items;
        _selected = nextSelected;
      });
    } catch (error) {
      if (mounted) {
        _showMessage('Ошибка чтения базы: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  // ---------------------------------------------------------------- capture

  Future<void> _startCapture(CaptureMode mode) async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);

    try {
      final result = await _screenshotService.capture(
        mode,
        copyToClipboard: mode != CaptureMode.text && _settings.autoCopy,
        delaySeconds: _settings.delaySeconds,
      );
      if (!mounted) return;

      switch (result.status) {
        case CaptureStatus.cancelled:
          break;
        case CaptureStatus.failed:
          _showMessage(
            'Не удалось сделать снимок: ${result.error ?? 'неизвестная ошибка'}',
          );
          break;
        case CaptureStatus.saved:
          final file = result.file;
          if (file == null) break;
          if (mode == CaptureMode.text) {
            await _finishTextCapture(file);
          } else {
            await _addScreenshot(file);
          }
          break;
      }
    } catch (error) {
      if (mounted) _showMessage('Ошибка съёмки: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Режим «текст с экрана»: выделили область — текст сразу в буфере обмена.
  Future<void> _finishTextCapture(File file) async {
    _showMessage('Распознаю текст…');
    final result = await _ocrService.recognize(file);
    await _screenshotService.deleteTemporaryFile(file);
    if (!mounted) return;

    if (!result.succeeded) {
      _showMessage('OCR не сработал: ${result.error}');
      return;
    }
    if (result.text.isEmpty) {
      _showMessage('Текст в выделенной области не найден.');
      return;
    }

    await Clipboard.setData(ClipboardData(text: result.text));
    final preview = result.text.replaceAll(RegExp(r'\s+'), ' ');
    _showMessage(
      'Текст скопирован (${result.text.length} симв.): '
      '${preview.length > 90 ? '${preview.substring(0, 90)}…' : preview}',
    );
  }

  Future<void> _addScreenshot(File file) async {
    final fileName = p.basename(file.path);
    final item = ScreenshotItem(
      filePath: file.path,
      fileName: fileName,
      createdAt: DateTime.now(),
      ocrText: '',
      searchText: fileName.toLowerCase(),
    );

    final id = await _databaseService.insertScreenshot(item);
    final saved = item.copyWith(id: id);

    // Сбрасываем фильтры, иначе новый снимок может оказаться «невидимым».
    _favoritesOnly = false;
    _selected = saved;
    if (_searchController.text.isNotEmpty) {
      _searchController.clear();
    }
    await _loadScreenshots();

    if (!mounted) return;
    _showMessage(
      _settings.autoCopy
          ? 'Скриншот сохранён и скопирован в буфер обмена.'
          : 'Скриншот сохранён.',
    );

    // OCR — в фоне, без блокировки интерфейса.
    if (_settings.autoOcr) {
      _enqueueOcr(saved);
    }
  }

  // -------------------------------------------------------------------- OCR

  void _enqueueOcr(ScreenshotItem item) {
    final id = item.id;
    if (id == null || _ocrPending.contains(id)) return;

    setState(() => _ocrPending.add(id));
    _ocrChain = _ocrChain
        .then((_) => _processOcr(item))
        .catchError((Object error) {
      debugPrint('OCR queue error: $error');
    });
  }

  Future<void> _processOcr(ScreenshotItem item) async {
    final id = item.id;
    if (id == null) return;

    try {
      final file = File(item.filePath);
      if (!await file.exists()) return;

      final result = await _ocrService.recognize(file);
      if (!result.succeeded) {
        if (mounted) _showMessage('OCR не сработал: ${result.error}');
        return;
      }

      await _databaseService.updateOcr(
        id: id,
        fileName: item.fileName,
        ocrText: result.text,
      );
      await _loadScreenshots();
    } finally {
      if (mounted) setState(() => _ocrPending.remove(id));
    }
  }

  void _rerunOcr(ScreenshotItem item) {
    if (item.id == null) return;
    _enqueueOcr(item);
    _showMessage('OCR запущен в фоне.');
  }

  // ---------------------------------------------------------------- actions

  Future<void> _toggleFavorite(ScreenshotItem item) async {
    final id = item.id;
    if (id == null) {
      return;
    }

    await _databaseService.setFavorite(id, !item.favorite);
    _selected = item.copyWith(favorite: !item.favorite);
    await _loadScreenshots();
  }

  Future<void> _copyImage(ScreenshotItem item) async {
    if (!await File(item.filePath).exists()) {
      _showMessage('Файл не найден.');
      return;
    }
    final error = await _screenshotService.copyImageToClipboard(
      File(item.filePath),
    );
    _showMessage(
      error == null
          ? 'Изображение скопировано в буфер обмена.'
          : 'Не удалось скопировать: $error',
    );
  }

  Future<void> _deleteScreenshot(ScreenshotItem item) async {
    final id = item.id;
    if (id == null) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить скриншот?'),
        content: const Text('Файл и запись в локальной базе будут удалены.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    try {
      final file = File(item.filePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (error) {
      _showMessage('Не удалось удалить файл: $error');
    }
    await _databaseService.deleteScreenshot(id);
    _selected = null;
    await _loadScreenshots();
  }

  Future<void> _openScreenshot(ScreenshotItem item) async {
    if (!await File(item.filePath).exists()) {
      _showMessage('Файл не найден.');
      return;
    }
    await OpenFile.open(item.filePath);
  }

  Future<void> _showInFolder(ScreenshotItem item) async {
    if (!Platform.isWindows) {
      return;
    }

    if (!await File(item.filePath).exists()) {
      _showMessage('Файл не найден.');
      return;
    }

    await Process.run(
      'explorer.exe',
      <String>['/select,', item.filePath],
      runInShell: true,
    );
  }

  // --------------------------------------------------------------- settings

  Future<void> _applySettings(AppSettings settings) async {
    setState(() => _settings = settings);
    try {
      await _databaseService.saveSettings(settings);
    } catch (error) {
      _showMessage('Не удалось сохранить настройки: $error');
    }
  }

  Future<void> _openSettings() async {
    var draft = _settings;
    final saved = await showDialog<AppSettings>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Настройки'),
          content: SizedBox(
            width: 430,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Копировать снимок в буфер обмена'),
                  subtitle: const Text('Сразу после съёмки можно вставить Ctrl+V'),
                  value: draft.autoCopy,
                  onChanged: (value) =>
                      setLocal(() => draft = draft.copyWith(autoCopy: value)),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Распознавать текст автоматически'),
                  subtitle: const Text('OCR выполняется в фоне, поиск по тексту'),
                  value: draft.autoOcr,
                  onChanged: (value) =>
                      setLocal(() => draft = draft.copyWith(autoOcr: value)),
                ),
                const SizedBox(height: 12),
                Text(
                  'Горячие клавиши',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 6),
                const Text(
                  'Ctrl + Shift + S — область с редактором\n'
                  'Ctrl + Alt + X — текст с экрана сразу в буфер\n\n'
                  'В редакторе области: V выбор, P перо, L линия, A стрелка, '
                  'R рамка, H маркер, B мозаика (скрыть данные), T текст; '
                  'колесо мыши — толщина; Ctrl+Z — шаг назад; '
                  'Shift при рисовании линии — ровный угол.',
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, draft),
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );

    if (saved != null) {
      await _applySettings(saved);
    }
  }

  void _showMessage(String text) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  // ------------------------------------------------------------------ build

  Widget _delayMenu() {
    final delay = _settings.delaySeconds;
    return PopupMenuButton<int>(
      tooltip: 'Задержка перед снимком',
      initialValue: delay,
      onSelected: (value) =>
          unawaited(_applySettings(_settings.copyWith(delaySeconds: value))),
      itemBuilder: (context) => const <PopupMenuEntry<int>>[
        PopupMenuItem<int>(value: 0, child: Text('Без задержки')),
        PopupMenuItem<int>(value: 3, child: Text('Через 3 секунды')),
        PopupMenuItem<int>(value: 5, child: Text('Через 5 секунд')),
        PopupMenuItem<int>(value: 10, child: Text('Через 10 секунд')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              delay == 0 ? Icons.timer_off_outlined : Icons.timer_outlined,
              size: 20,
            ),
            if (delay > 0) ...<Widget>[
              const SizedBox(width: 4),
              Text('$delay с'),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart Screenshot Manager'),
        actions: <Widget>[
          _delayMenu(),
          IconButton(
            tooltip: 'Настройки',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12, left: 4),
            child: Center(
              child: Text(
                'Ctrl+Shift+S · Ctrl+Alt+X',
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: 'Поиск по имени файла и тексту внутри скриншота',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searchController.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Очистить поиск',
                              onPressed: _searchController.clear,
                              icon: const Icon(Icons.close),
                            ),
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilterChip(
                  selected: _favoritesOnly,
                  label: const Text('Избранное'),
                  avatar: const Icon(Icons.star_outline, size: 18),
                  onSelected: (value) {
                    setState(() => _favoritesOnly = value);
                    _loadScreenshots();
                  },
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: _busy ? null : () => _startCapture(CaptureMode.region),
                  icon: const Icon(Icons.crop_free),
                  label: const Text('Область'),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : () => _startCapture(CaptureMode.text),
                  icon: const Icon(Icons.text_fields),
                  label: const Text('Текст'),
                ),
                const SizedBox(width: 8),
                PopupMenuButton<CaptureMode>(
                  tooltip: 'Снимок всего экрана',
                  enabled: !_busy,
                  onSelected: _startCapture,
                  itemBuilder: (context) => const <PopupMenuEntry<CaptureMode>>[
                    PopupMenuItem<CaptureMode>(
                      value: CaptureMode.screen,
                      child: Text('Текущий монитор'),
                    ),
                    PopupMenuItem<CaptureMode>(
                      value: CaptureMode.allScreens,
                      child: Text('Все мониторы'),
                    ),
                  ],
                  // IgnorePointer: клик обрабатывает PopupMenuButton, а не кнопка.
                  child: IgnorePointer(
                    child: FilledButton.tonalIcon(
                      onPressed: _busy ? null : () {},
                      icon: const Icon(Icons.desktop_windows_outlined),
                      label: const Text('Экран'),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final showDetails = constraints.maxWidth >= 900;

                final listPanel = SizedBox(
                  width: showDetails
                      ? constraints.maxWidth * 0.47
                      : constraints.maxWidth,
                  child: _buildListPanel(),
                );

                if (!showDetails) {
                  return listPanel;
                }

                final selected = _selected;
                return Row(
                  children: <Widget>[
                    listPanel,
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: DetailsPanel(
                        item: selected,
                        busy: _busy,
                        ocrPending: selected?.id != null &&
                            _ocrPending.contains(selected!.id),
                        searchQuery: _searchController.text,
                        onOpen: () {
                          if (selected != null) _openScreenshot(selected);
                        },
                        onShowInFolder: () {
                          if (selected != null) _showInFolder(selected);
                        },
                        onFavorite: () {
                          if (selected != null) _toggleFavorite(selected);
                        },
                        onRerunOcr: () {
                          if (selected != null) _rerunOcr(selected);
                        },
                        onCopyImage: () {
                          if (selected != null) _copyImage(selected);
                        },
                        onDelete: () {
                          if (selected != null) _deleteScreenshot(selected);
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildListPanel() {
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.screenshot_monitor_outlined, size: 72),
              const SizedBox(height: 16),
              Text(
                _searchController.text.trim().isEmpty
                    ? 'Скриншотов пока нет'
                    : 'Ничего не найдено',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                'Нажмите «Область» или Ctrl+Shift+S. После сохранения OCR выполнится локально, в фоне.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return Stack(
      children: <Widget>[
        ListView.builder(
          padding: const EdgeInsets.all(10),
          itemCount: _items.length,
          itemBuilder: (context, index) {
            final item = _items[index];
            return ScreenshotListTile(
              key: ValueKey<int?>(item.id),
              item: item,
              selected: item.id == _selected?.id,
              ocrPending: item.id != null && _ocrPending.contains(item.id),
              onTap: () => setState(() => _selected = item),
              onFavorite: () => _toggleFavorite(item),
            );
          },
        ),
        if (_loading)
          const Positioned(
            top: 8,
            right: 8,
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
      ],
    );
  }
}
