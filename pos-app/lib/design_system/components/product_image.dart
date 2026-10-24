import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Размер файла фото (D-30, RM-E-003): `thumb` 160, `card` 400, `full` 1200 px по длинной стороне.
enum ProductImageSize {
  /// Миниатюры, строки списков, корзина.
  thumb,

  /// Карточки сетки, главное фото на compact.
  card,

  /// Галерея SCR-14 и полноэкранный просмотр.
  full,
}

/// Источник картинки по URL: по умолчанию `CachedNetworkImageProvider` (файловый кэш,
/// `immutable` по `sha256`). Тесты и витрина подменяют его через [ProductImageScope].
typedef ProductImageProviderFactory = ImageProvider<Object> Function(String url);

/// Подмена источника картинок для поддерева (тесты, golden, витрина).
class ProductImageScope extends InheritedWidget {
  /// Создаёт область.
  const ProductImageScope({super.key, required this.providerFor, required super.child});

  /// Фабрика провайдера картинки по URL.
  final ProductImageProviderFactory providerFor;

  /// Фабрика ближайшей области или `null`.
  static ProductImageProviderFactory? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ProductImageScope>()?.providerFor;

  @override
  bool updateShouldNotify(ProductImageScope oldWidget) => oldWidget.providerFor != providerFor;
}

/// Фото товара `ProductImage` (03 §9.14, D-30, INV-050…052).
///
/// Квадрат `surfaceVariant`, радиус по умолчанию `md`; загрузка — скелетон (ANIM-013), появление —
/// fade 200 мс (ANIM-014); нет фото или ошибка загрузки — заглушка «Нет фото» (иконка + подпись),
/// никогда не показывается фото другого товара: URL строит вызывающий по `sha256` своего товара
/// ([pathFor]). Файлы неизменяемы (`/images/{sha256}/{size}.webp`, `Cache-Control: immutable`).
class ProductImage extends StatelessWidget {
  /// Создаёт фото.
  const ProductImage({
    super.key,
    required this.url,
    this.size = ProductImageSize.card,
    this.dimension,
    this.borderRadius,
    this.semanticLabel,
    this.fit = BoxFit.contain,
    this.showPlaceholderLabel = true,
  });

  /// Абсолютный URL файла; `null` — фото нет (заглушка).
  final String? url;

  /// Размер файла (определяет кэш-ключ и масштаб декодирования).
  final ProductImageSize size;

  /// Сторона квадрата; `null` — по ширине родителя (1:1).
  final double? dimension;

  /// Скругление; по умолчанию `md` (12).
  final BorderRadius? borderRadius;

  /// Описание для screen reader (название товара / «Фото 2 из 5»).
  final String? semanticLabel;

  /// Вписывание.
  final BoxFit fit;

  /// Подпись «Нет фото» под иконкой (у миниатюр < 64 скрывается автоматически).
  final bool showPlaceholderLabel;

  /// Относительный путь файла: `/images/{sha256}/{thumb|card|full}.webp` (RM-E-003).
  static String pathFor(String sha256, ProductImageSize size) => '/images/$sha256/${size.name}.webp';

  /// Ширина декодирования по размеру файла (экономия памяти на compact).
  static int cacheWidthOf(ProductImageSize size) => switch (size) {
    ProductImageSize.thumb => 160,
    ProductImageSize.card => 400,
    ProductImageSize.full => 1200,
  };

  @override
  Widget build(BuildContext context) {
    final BorderRadius radius = borderRadius ?? BorderRadius.all(context.radii.md);
    final Widget body = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final double side = dimension ?? (box.hasBoundedWidth ? box.maxWidth : 160);
        return SizedBox.square(
          dimension: side,
          child: ClipRRect(
            borderRadius: radius,
            child: ColoredBox(color: context.colors.surfaceVariant, child: _content(context, side)),
          ),
        );
      },
    );
    return Semantics(image: true, label: semanticLabel, excludeSemantics: true, child: body);
  }

  Widget _content(BuildContext context, double side) {
    final String? u = url;
    if (u == null || u.isEmpty) {
      return ProductImagePlaceholder(side: side, showLabel: showPlaceholderLabel);
    }
    final ProductImageProviderFactory factory = ProductImageScope.maybeOf(context) ?? CachedNetworkImageProvider.new;
    final Duration fade = context.motion.of(const Duration(milliseconds: 200));
    return Image(
      image: ResizeImage.resizeIfNeeded(cacheWidthOf(size), null, factory(u)),
      fit: fit,
      width: side,
      height: side,
      gaplessPlayback: true,
      frameBuilder: (BuildContext context, Widget child, int? frame, bool sync) {
        if (sync) return child;
        return AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: fade, child: child);
      },
      loadingBuilder: (BuildContext context, Widget child, ImageChunkEvent? progress) =>
          progress == null ? child : SkeletonBox(width: side, height: side, radius: Radius.zero),
      errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
          ProductImagePlaceholder(side: side, showLabel: showPlaceholderLabel),
    );
  }
}

/// Заглушка «Нет фото» (INV-050): иконка `image_not_supported` `textTertiary` + подпись `caption`.
class ProductImagePlaceholder extends StatelessWidget {
  /// Создаёт заглушку.
  const ProductImagePlaceholder({super.key, required this.side, this.showLabel = true});

  /// Сторона квадрата.
  final double side;

  /// Показывать подпись (скрывается у миниатюр меньше 64).
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool label = showLabel && side >= 64;
    final double icon = side >= 160 ? 48 : (side >= 64 ? 32 : 20);
    return Center(
      key: const ValueKey<String>('product-image-placeholder'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.image_not_supported_outlined, size: icon, color: c.textTertiary),
          if (label) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              AppLocalizations.of(context).ds_no_photo,
              style: context.text.caption.copyWith(color: c.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}
