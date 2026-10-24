import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/product_image.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Фото галереи: URL основного размера, миниатюры и полноэкранного просмотра.
@immutable
class GalleryImage {
  /// Создаёт элемент.
  const GalleryImage({required this.url, this.thumbUrl, this.fullUrl, this.variantId, this.dotColor});

  /// Основное фото (`card`/`full`).
  final String? url;

  /// Миниатюра (`thumb`); по умолчанию [url].
  final String? thumbUrl;

  /// Полноэкранный просмотр (`full`); по умолчанию [url].
  final String? fullUrl;

  /// Фото варианта (тап по миниатюре выбирает вариант, B2 SCR-14).
  final String? variantId;

  /// Бейдж-точка цвета варианта 8 (если известен цвет оси).
  final Color? dotColor;
}

/// Расположение ленты миниатюр.
enum ImageGalleryStrip {
  /// Под фото, горизонтальная прокрутка (compact/medium).
  horizontal,

  /// Слева от фото, ширина 64 (expanded).
  vertical,
}

/// Галерея `ImageGallery` (03 §9.15, ядро §17.5): главное фото `ProductImage.full` 1:1, индикатор
/// «2 / 5» в пилюле `overlay`, лента миниатюр 56 (выбранная — рамка `primaryText` 2),
/// свайп и ←/→, тап по фото — полноэкранный просмотр (pinch-zoom до 3×, кнопки «+/−»).
/// Пустой список — одна заглушка «Нет фото», лента скрыта (вариант `single` — без ленты).
class ImageGallery extends StatefulWidget {
  /// Создаёт галерею.
  const ImageGallery({
    super.key,
    required this.images,
    this.index = 0,
    this.onIndexChanged,
    this.onThumbnailTap,
    this.strip = ImageGalleryStrip.horizontal,
    this.mainSize,
    this.enableFullscreen = true,
  });

  /// Фото (товара, затем вариантов).
  final List<GalleryImage> images;

  /// Текущий индекс (управляемый).
  final int index;

  /// Смена фото свайпом/стрелками.
  final ValueChanged<int>? onIndexChanged;

  /// Тап по миниатюре; по умолчанию — [onIndexChanged].
  final ValueChanged<int>? onThumbnailTap;

  /// Расположение ленты.
  final ImageGalleryStrip strip;

  /// Сторона главного фото; `null` — по ширине.
  final double? mainSize;

  /// Открывать полноэкранный просмотр по тапу.
  final bool enableFullscreen;

  /// Размер миниатюры.
  static const double thumbSize = 56;

  /// Полноэкранный просмотр (UI-14-022): фон `inverseSurface`, кнопки `onInverseSurface`.
  static Future<int?> openFullscreen(BuildContext context, List<GalleryImage> images, int index) =>
      Navigator.of(context).push<int>(
        PageRouteBuilder<int>(
          opaque: true,
          transitionDuration: context.motion.of(const Duration(milliseconds: 200)),
          pageBuilder: (BuildContext ctx, Animation<double> a, Animation<double> b) =>
              _FullscreenGallery(images: images, initialIndex: index),
          transitionsBuilder: (BuildContext ctx, Animation<double> a, Animation<double> b, Widget child) =>
              FadeTransition(opacity: a, child: child),
        ),
      );

  @override
  State<ImageGallery> createState() => _ImageGalleryState();
}

class _ImageGalleryState extends State<ImageGallery> {
  late PageController _pages = PageController(initialPage: _safeIndex);

  int get _safeIndex => widget.images.isEmpty ? 0 : widget.index.clamp(0, widget.images.length - 1);

  @override
  void didUpdateWidget(ImageGallery old) {
    super.didUpdateWidget(old);
    if (old.images.length != widget.images.length) {
      _pages.dispose();
      _pages = PageController(initialPage: _safeIndex);
      return;
    }
    if (_pages.hasClients && (_pages.page?.round() ?? 0) != _safeIndex) {
      final Duration d = context.motion.of(const Duration(milliseconds: 200));
      if (d == Duration.zero) {
        _pages.jumpToPage(_safeIndex);
      } else {
        unawaited(_pages.animateToPage(_safeIndex, duration: d, curve: Curves.easeInOut));
      }
    }
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _go(int i) {
    if (widget.images.isEmpty) return;
    widget.onIndexChanged?.call(i.clamp(0, widget.images.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    final List<GalleryImage> images = widget.images;
    final Widget main = _main(context);
    if (images.length < 2) return main;
    final Widget strip = _strip(context);
    return widget.strip == ImageGalleryStrip.vertical
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(width: 64, height: widget.mainSize, child: strip),
              const SizedBox(width: 8),
              Expanded(child: main),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              main,
              const SizedBox(height: 8),
              SizedBox(height: ImageGallery.thumbSize + 4, child: strip),
            ],
          );
  }

  Widget _main(BuildContext context) {
    final DsColors c = context.colors;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final List<GalleryImage> images = widget.images;
    if (images.isEmpty) {
      return ProductImage(url: null, size: ProductImageSize.full, dimension: widget.mainSize);
    }
    final int count = images.length;
    final Widget pager = PageView.builder(
      controller: _pages,
      itemCount: count,
      onPageChanged: _go,
      itemBuilder: (BuildContext context, int i) => GestureDetector(
        onTap: widget.enableFullscreen ? () => _openFullscreen(i) : null,
        child: ProductImage(
          url: images[i].url,
          size: ProductImageSize.full,
          borderRadius: BorderRadius.all(context.radii.md),
          semanticLabel: l10n.product_gallery_counter_a11y(count, '${i + 1}'),
        ),
      ),
    );
    return Focus(
      onKeyEvent: (FocusNode node, KeyEvent e) {
        if (e is! KeyDownEvent) return KeyEventResult.ignored;
        if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
          _go(_safeIndex + 1);
          return KeyEventResult.handled;
        }
        if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
          _go(_safeIndex - 1);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final double side = widget.mainSize ?? box.maxWidth;
          // «Предыдущее / Следующее фото» для screen reader (03 §9.15): действия узла фото.
          return Semantics(
            customSemanticsActions: count > 1
                ? <CustomSemanticsAction, VoidCallback>{
                    CustomSemanticsAction(label: l10n.ds_gallery_prev_a11y): () => _go(_safeIndex - 1),
                    CustomSemanticsAction(label: l10n.ds_gallery_next_a11y): () => _go(_safeIndex + 1),
                  }
                : null,
            child: SizedBox.square(
              dimension: side,
              child: Stack(
                children: <Widget>[
                  Positioned.fill(child: pager),
                  if (count > 1)
                    PositionedDirectional(
                      end: 8,
                      bottom: 8,
                      child: Semantics(
                        liveRegion: true,
                        label: l10n.product_gallery_counter_a11y(count, '${_safeIndex + 1}'),
                        excludeSemantics: true,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: c.overlay,
                            borderRadius: BorderRadius.all(context.radii.full),
                          ),
                          child: Text(
                            '${_safeIndex + 1} / $count',
                            style: context.text.caption.copyWith(color: c.onInverseSurface, fontFeatures: _tnum),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _strip(BuildContext context) {
    final List<GalleryImage> images = widget.images;
    final bool vertical = widget.strip == ImageGalleryStrip.vertical;
    final AppLocalizations l10n = AppLocalizations.of(context);
    return ListView.separated(
      scrollDirection: vertical ? Axis.vertical : Axis.horizontal,
      itemCount: images.length,
      padding: const EdgeInsets.all(2),
      separatorBuilder: (BuildContext context, int i) => const SizedBox(width: 8, height: 8),
      itemBuilder: (BuildContext context, int i) => _Thumb(
        image: images[i],
        selected: i == _safeIndex,
        label: l10n.product_gallery_counter_a11y(images.length, '${i + 1}'),
        onTap: () => (widget.onThumbnailTap ?? widget.onIndexChanged)?.call(i),
      ),
    );
  }

  Future<void> _openFullscreen(int i) async {
    final int? back = await ImageGallery.openFullscreen(context, widget.images, i);
    if (back != null && mounted) _go(back);
  }
}

const List<FontFeature> _tnum = <FontFeature>[FontFeature.tabularFigures()];

class _Thumb extends StatelessWidget {
  const _Thumb({required this.image, required this.selected, required this.label, required this.onTap});

  final GalleryImage image;
  final bool selected;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: DsInteractive(
        onTap: onTap,
        builder: (BuildContext context, DsInteractionState s) => DsFocusRing(
          visible: s.focused,
          borderRadius: BorderRadius.all(context.radii.sm),
          child: Container(
            width: ImageGallery.thumbSize,
            height: ImageGallery.thumbSize,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.all(context.radii.sm),
              border: Border.all(color: selected ? c.primaryText : c.border, width: selected ? 2 : 1),
            ),
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: ProductImage(
                    url: image.thumbUrl ?? image.url,
                    size: ProductImageSize.thumb,
                    borderRadius: BorderRadius.all(context.radii.xs),
                    showPlaceholderLabel: false,
                  ),
                ),
                if (image.dotColor != null)
                  PositionedDirectional(
                    end: 4,
                    top: 4,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: image.dotColor,
                        shape: BoxShape.circle,
                        border: Border.all(color: c.surface),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FullscreenGallery extends StatefulWidget {
  const _FullscreenGallery({required this.images, required this.initialIndex});

  final List<GalleryImage> images;
  final int initialIndex;

  @override
  State<_FullscreenGallery> createState() => _FullscreenGalleryState();
}

class _FullscreenGalleryState extends State<_FullscreenGallery> {
  late final PageController _pages = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  final TransformationController _zoom = TransformationController();

  @override
  void dispose() {
    _pages.dispose();
    _zoom.dispose();
    super.dispose();
  }

  void _scaleBy(double factor) {
    final double current = _zoom.value.getMaxScaleOnAxis();
    final double next = (current * factor).clamp(1.0, 3.0);
    _zoom.value = Matrix4.diagonal3Values(next, next, 1);
  }

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final AppLocalizations l10n = AppLocalizations.of(context);
    void close() => Navigator.of(context).pop(_index);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) close();
      },
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): close,
          const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
              _pages.nextPage(duration: context.motion.of(const Duration(milliseconds: 200)), curve: Curves.easeInOut),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _pages.previousPage(
            duration: context.motion.of(const Duration(milliseconds: 200)),
            curve: Curves.easeInOut,
          ),
        },
        child: Focus(
          autofocus: true,
          child: Material(
            color: c.inverseSurface,
            child: SafeArea(
              child: Stack(
                children: <Widget>[
                  PageView.builder(
                    controller: _pages,
                    itemCount: widget.images.length,
                    onPageChanged: (int i) {
                      _zoom.value = Matrix4.identity();
                      setState(() => _index = i);
                    },
                    itemBuilder: (BuildContext context, int i) => InteractiveViewer(
                      transformationController: i == _index ? _zoom : null,
                      maxScale: 3,
                      child: Center(
                        child: ProductImage(
                          url: widget.images[i].fullUrl ?? widget.images[i].url,
                          size: ProductImageSize.full,
                          borderRadius: BorderRadius.zero,
                          semanticLabel: l10n.product_gallery_counter_a11y(widget.images.length, '${i + 1}'),
                        ),
                      ),
                    ),
                  ),
                  PositionedDirectional(
                    top: 8,
                    end: 8,
                    child: IconTheme(
                      data: IconThemeData(color: c.onInverseSurface),
                      child: Row(
                        children: <Widget>[
                          _FullscreenButton(
                            icon: Icons.zoom_out_rounded,
                            label: l10n.ds_gallery_zoom_out_a11y,
                            onTap: () => _scaleBy(1 / 1.5),
                          ),
                          _FullscreenButton(
                            icon: Icons.zoom_in_rounded,
                            label: l10n.ds_gallery_zoom_in_a11y,
                            onTap: () => _scaleBy(1.5),
                          ),
                          _FullscreenButton(icon: Icons.close_rounded, label: l10n.ds_button_close, onTap: close),
                        ],
                      ),
                    ),
                  ),
                  if (widget.images.length > 1) ...<Widget>[
                    // «Предыдущее / Следующее фото» (03 §9.15) — кнопки и для screen reader.
                    PositionedDirectional(
                      start: 8,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: _FullscreenButton(
                          icon: Icons.chevron_left_rounded,
                          label: l10n.ds_gallery_prev_a11y,
                          onTap: () => _pages.previousPage(
                            duration: context.motion.of(const Duration(milliseconds: 200)),
                            curve: Curves.easeInOut,
                          ),
                        ),
                      ),
                    ),
                    PositionedDirectional(
                      end: 8,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: _FullscreenButton(
                          icon: Icons.chevron_right_rounded,
                          label: l10n.ds_gallery_next_a11y,
                          onTap: () => _pages.nextPage(
                            duration: context.motion.of(const Duration(milliseconds: 200)),
                            curve: Curves.easeInOut,
                          ),
                        ),
                      ),
                    ),
                  ],
                  PositionedDirectional(
                    start: 16,
                    top: 20,
                    child: Text(
                      '${_index + 1} / ${widget.images.length}',
                      style: context.text.label.copyWith(color: c.onInverseSurface, fontFeatures: _tnum),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FullscreenButton extends StatelessWidget {
  const _FullscreenButton({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    excludeSemantics: true,
    child: DsInteractive(
      onTap: onTap,
      builder: (BuildContext context, DsInteractionState s) => DsFocusRing(
        visible: s.focused,
        circle: true,
        child: SizedBox.square(dimension: 48, child: Icon(icon, size: 24, color: context.colors.onInverseSurface)),
      ),
    ),
  );
}
