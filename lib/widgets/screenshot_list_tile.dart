import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/screenshot_item.dart';

class ScreenshotListTile extends StatelessWidget {
  const ScreenshotListTile({
    super.key,
    required this.item,
    required this.selected,
    required this.onTap,
    required this.onFavorite,
    this.ocrPending = false,
  });

  final ScreenshotItem item;
  final bool selected;
  final bool ocrPending;
  final VoidCallback onTap;
  final VoidCallback onFavorite;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    String ocrLine;
    if (ocrPending) {
      ocrLine = 'OCR: распознаю текст…';
    } else if (item.ocrText.isEmpty) {
      ocrLine = 'OCR: текст не найден';
    } else {
      ocrLine = item.ocrText.replaceAll('\n', ' ');
    }

    return Card(
      elevation: selected ? 2 : 0,
      color: selected ? colors.secondaryContainer : null,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 112,
                  height: 72,
                  // cacheWidth — главное: без него для каждой плитки
                  // декодируется полноразмерный 4K-PNG, и список «подвисает».
                  child: Image.file(
                    File(item.filePath),
                    fit: BoxFit.cover,
                    cacheWidth: 240,
                    filterQuality: FilterQuality.low,
                    gaplessPlayback: true,
                    errorBuilder: (context, error, stackTrace) =>
                        const ColoredBox(
                      color: Colors.black12,
                      child: Center(child: Icon(Icons.broken_image_outlined)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      item.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      DateFormat('dd.MM.yyyy  HH:mm:ss').format(item.createdAt),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 5),
                    Text(
                      ocrLine,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: item.favorite
                    ? 'Убрать из избранного'
                    : 'Добавить в избранное',
                onPressed: onFavorite,
                icon: Icon(
                  item.favorite ? Icons.star : Icons.star_border,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
