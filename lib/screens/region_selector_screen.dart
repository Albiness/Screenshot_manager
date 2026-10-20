import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Coordinates of [rect] are relative to the *visible screenshot*, not the
/// Flutter window. cropAndSave converts them to original screenshot pixels.
class RegionSelection {
  const RegionSelection({
    required this.rect,
    required this.displayedSize,
  });

  final Rect rect;
  final Size displayedSize;
}

class RegionSelectorScreen extends StatefulWidget {
  const RegionSelectorScreen({
    required this.imageFile,
    required this.onConfirm,
    required this.onCancel,
    super.key,
  });

  final File imageFile;
  final ValueChanged<RegionSelection> onConfirm;
  final VoidCallback onCancel;

  @override
  State<RegionSelectorScreen> createState() => _RegionSelectorScreenState();
}

class _RegionSelectorScreenState extends State<RegionSelectorScreen> {
  final FocusNode _focusNode = FocusNode();
  Timer? _readyTimer;

  /// Source pixel dimensions, independent of desktop DPI and Flutter units.
  Size? _sourceSize;
  String? _imageError;
  Rect _imageRect = Rect.zero;
  Offset? _start;
  Offset? _current;
  int? _activePointer;
  bool _ready = false;

  Rect? get _selectionRect {
    final a = _start;
    final b = _current;
    if (a == null || b == null || _imageRect.isEmpty) return null;
    final rect = Rect.fromPoints(a, b);
    return Rect.fromLTRB(
      rect.left.clamp(0.0, _imageRect.width),
      rect.top.clamp(0.0, _imageRect.height),
      rect.right.clamp(0.0, _imageRect.width),
      rect.bottom.clamp(0.0, _imageRect.height),
    );
  }

  bool get _hasSelection {
    final r = _selectionRect;
    return r != null && r.width >= 10 && r.height >= 10;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadImageDimensions());
    _readyTimer = Timer(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      setState(() => _ready = true);
      _focusNode.requestFocus();
    });
  }

  Future<void> _loadImageDimensions() async {
    try {
      final bytes = await widget.imageFile.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final frame = await codec.getNextFrame();
        final image = frame.image;
        final dimensions = Size(
          image.width.toDouble(),
          image.height.toDouble(),
        );
        image.dispose();
        if (!mounted) return;
        setState(() => _sourceSize = dimensions);
      } finally {
        codec.dispose();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _imageError = error.toString());
    }
  }

  @override
  void dispose() {
    _readyTimer?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  Offset _insideImage(Offset canvasPosition) => Offset(
        (canvasPosition.dx - _imageRect.left).clamp(0.0, _imageRect.width),
        (canvasPosition.dy - _imageRect.top).clamp(0.0, _imageRect.height),
      );

  void _onDown(PointerDownEvent event) {
    if (!_ready || _sourceSize == null || _activePointer != null) return;
    if ((event.buttons & kPrimaryMouseButton) == 0) return;
    if (!_imageRect.contains(event.localPosition)) return;
    _activePointer = event.pointer;
    final point = _insideImage(event.localPosition);
    setState(() {
      _start = point;
      _current = point;
    });
  }

  void _onMove(PointerMoveEvent event) {
    if (_activePointer != event.pointer || !_ready) return;
    if ((event.buttons & kPrimaryMouseButton) == 0) return;
    setState(() => _current = _insideImage(event.localPosition));
  }

  void _onUp(PointerUpEvent event) {
    if (_activePointer != event.pointer) return;
    setState(() {
      _current = _insideImage(event.localPosition);
      _activePointer = null;
    });
    // Releasing the mouse NEVER confirms or closes the screenshot selector.
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (_activePointer == event.pointer) _activePointer = null;
  }

  void _confirm() {
    final selection = _selectionRect;
    if (!_hasSelection || selection == null || _imageRect.isEmpty) return;
    widget.onConfirm(
      RegionSelection(rect: selection, displayedSize: _imageRect.size),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black,
      child: KeyboardListener(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: (event) {
          if (event is! KeyDownEvent) return;
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            widget.onCancel();
          } else if (event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.numpadEnter) {
            _confirm();
          }
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            final viewport = Size(constraints.maxWidth, constraints.maxHeight);
            final sourceSize = _sourceSize;
            if (sourceSize != null) {
              // This is the physical image's actual, letterboxed display rect.
              // Do not use BoxFit.cover or stretch it across the window.
              final fitted = applyBoxFit(BoxFit.contain, sourceSize, viewport);
              _imageRect = Alignment.center.inscribe(
                fitted.destination,
                Offset.zero & viewport,
              );
            } else {
              _imageRect = Rect.zero;
            }

            final selection = _selectionRect;
            final paintedRect = selection?.shift(_imageRect.topLeft);
            final selectionPx = sourceSize != null &&
                    selection != null &&
                    !_imageRect.isEmpty
                ? Size(
                    selection.width * sourceSize.width / _imageRect.width,
                    selection.height * sourceSize.height / _imageRect.height,
                  )
                : null;

            return Stack(
              fit: StackFit.expand,
              children: <Widget>[
                if (sourceSize != null)
                  Positioned.fromRect(
                    rect: _imageRect,
                    child: Image.file(
                      widget.imageFile,
                      fit: BoxFit.fill, // Fits EXACT image ratio inside the rect.
                      filterQuality: FilterQuality.medium,
                    ),
                  )
                else
                  Center(
                    child: _imageError == null
                        ? const CircularProgressIndicator()
                        : Text(
                            'Ошибка загрузки изображения: $_imageError',
                            style: const TextStyle(color: Colors.white),
                          ),
                  ),
                // This listener does not automatically close the overlay.
                Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: _onDown,
                  onPointerMove: _onMove,
                  onPointerUp: _onUp,
                  onPointerCancel: _onPointerCancel,
                  child: MouseRegion(
                    cursor: _ready && sourceSize != null
                        ? SystemMouseCursors.precise
                        : SystemMouseCursors.basic,
                    child: const SizedBox.expand(),
                  ),
                ),
                IgnorePointer(
                  child: CustomPaint(
                    painter: _SelectionPainter(selection: paintedRect),
                  ),
                ),
                Positioned(
                  top: 16,
                  left: 16,
                  right: 16,
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              !_ready || sourceSize == null
                                  ? 'Подготовка выделения…'
                                  : _hasSelection
                                      ? 'Область выделена. Enter / Сохранить — сохранить; можно выделить снова.'
                                      : 'Зажмите левую кнопку мыши и выделите участок. Esc — отмена.',
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        onPressed: _hasSelection ? _confirm : null,
                        icon: const Icon(Icons.check),
                        label: const Text('Сохранить'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: widget.onCancel,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white70),
                        ),
                        icon: const Icon(Icons.close),
                        label: const Text('Отмена'),
                      ),
                    ],
                  ),
                ),
                if (paintedRect != null && selectionPx != null)
                  Positioned(
                    left: (paintedRect.left + 8).clamp(8.0, viewport.width - 100),
                    top: (paintedRect.top + 8).clamp(70.0, viewport.height - 40),
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4,
                          ),
                          child: Text(
                            '${selectionPx.width.round()} × ${selectionPx.height.round()} px',
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SelectionPainter extends CustomPainter {
  const _SelectionPainter({required this.selection});
  final Rect? selection;

  @override
  void paint(Canvas canvas, Size size) {
    final full = Offset.zero & size;
    final rect = selection;
    if (rect == null) {
      canvas.drawRect(full, Paint()..color = Colors.black.withValues(alpha: 0.22));
      return;
    }

    final outside = Path.combine(
      PathOperation.difference,
      Path()..addRect(full),
      Path()..addRect(rect),
    );
    canvas.drawPath(
      outside,
      Paint()..color = Colors.black.withValues(alpha: 0.52),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _SelectionPainter oldDelegate) =>
      selection != oldDelegate.selection;
}
