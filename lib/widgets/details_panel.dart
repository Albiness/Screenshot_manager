import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../models/screenshot_item.dart';

class DetailsPanel extends StatelessWidget {
  const DetailsPanel({
    super.key,
    required this.item,
    required this.busy,
    required this.onOpen,
    required this.onShowInFolder,
    required this.onFavorite,
    required this.onRerunOcr,
    required this.onCopyImage,
    required this.onDelete,
    this.ocrPending = false,
    this.searchQuery = '',
  });

  final ScreenshotItem? item;
  final bool busy;
  final bool ocrPending;
  final String searchQuery;
  final VoidCallback onOpen;
  final VoidCallback onShowInFolder;
  final VoidCallback onFavorite;
  final VoidCallback onRerunOcr;
  final VoidCallback onCopyImage;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final current = item;

    if (current == null) {
      return const Center(
        child: Text('Выберите скриншот слева'),
      );
    }

    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            flex: 5,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Image.file(
                  File(current.filePath),
                  // Ключ по пути: при смене снимка кэш не «залипает».
                  key: ValueKey<String>(current.filePath),
                  fit: BoxFit.contain,
                  // Ограничиваем размер декодирования, чтобы 4K не грузил GPU.
                  cacheWidth: 1800,
                  filterQuality: FilterQuality.medium,
                  gaplessPlayback: true,
                  errorBuilder: (context, error, stackTrace) => const Center(
                    child: Icon(Icons.broken_image_outlined, size: 64),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            current.fileName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            DateFormat('dd.MM.yyyy  HH:mm:ss').format(current.createdAt),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.tonalIcon(
                onPressed: busy ? null : onCopyImage,
                icon: const Icon(Icons.copy_all_outlined),
                label: const Text('Копировать'),
              ),
              FilledButton.tonalIcon(
                onPressed: busy ? null : onOpen,
                icon: const Icon(Icons.open_in_new),
                label: const Text('Открыть'),
              ),
              FilledButton.tonalIcon(
                onPressed: busy ? null : onShowInFolder,
                icon: const Icon(Icons.folder_open),
                label: const Text('В папке'),
              ),
              FilledButton.tonalIcon(
                onPressed: busy ? null : onFavorite,
                icon: Icon(current.favorite ? Icons.star : Icons.star_border),
                label: Text(current.favorite ? 'Из избранного' : 'В избранное'),
              ),
              FilledButton.tonalIcon(
                onPressed: (busy || ocrPending) ? null : onRerunOcr,
                icon: const Icon(Icons.document_scanner_outlined),
                label: const Text('OCR снова'),
              ),
              FilledButton.tonalIcon(
                onPressed: busy ? null : onDelete,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Удалить'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Text('Распознанный текст', style: theme.textTheme.titleSmall),
              if (ocrPending) ...<Widget>[
                const SizedBox(width: 10),
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
              const Spacer(),
              IconButton(
                tooltip: 'Копировать текст',
                onPressed: current.ocrText.isEmpty
                    ? null
                    : () {
                        Clipboard.setData(ClipboardData(text: current.ocrText));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('OCR-текст скопирован')),
                        );
                      },
                icon: const Icon(Icons.copy),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            flex: 3,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: theme.dividerColor),
                borderRadius: BorderRadius.circular(12),
              ),
              child: SingleChildScrollView(
                child: current.ocrText.isEmpty
                    ? SelectableText(
                        ocrPending
                            ? 'Распознаю текст…'
                            : 'Текст на изображении не найден или OCR не смог его распознать.',
                      )
                    : SelectableText.rich(
                        TextSpan(
                          children: _highlight(
                            current.ocrText,
                            searchQuery,
                            theme.colorScheme.tertiaryContainer,
                            theme.colorScheme.onTertiaryContainer,
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Подсвечивает в тексте слова из строки поиска.
  List<InlineSpan> _highlight(
    String text,
    String query,
    Color background,
    Color foreground,
  ) {
    final terms = query
        .trim()
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty)
        .toList();
    if (terms.isEmpty) return <InlineSpan>[TextSpan(text: text)];

    RegExp pattern;
    try {
      pattern = RegExp(
        terms.map(RegExp.escape).join('|'),
        caseSensitive: false,
        unicode: true,
      );
    } catch (_) {
      return <InlineSpan>[TextSpan(text: text)];
    }

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final match in pattern.allMatches(text)) {
      if (match.end == match.start) continue;
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      spans.add(
        TextSpan(
          text: text.substring(match.start, match.end),
          style: TextStyle(
            backgroundColor: background,
            color: foreground,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return spans.isEmpty ? <InlineSpan>[TextSpan(text: text)] : spans;
  }
}
