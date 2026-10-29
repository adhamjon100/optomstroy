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

/// Адрес API для относительных URL фото (`/images/{sha256}/{size}`, контракт `Image.*Url` 00_root.yaml): сервер
/// отдаёт путь без хоста, а загрузчику нужен абсолютный URL. Корень приложения ставит область с `API_BASE_URL`;
/// [ProductImage] и картинки категорий разрешают относительный путь от origin этого адреса.
class ProductImageBase extends InheritedWidget {
  /// Создаёт область.
  const ProductImageBase({super.key, required this.baseUri, required super.child});

  /// Базовый адрес API (`http://host:port/api/v1`): путь `/images/…` разрешается от его origin.
  final Uri baseUri;

  /// Абсолютный URL для [url] в контексте ближайшей области (без области — как есть).
  static String resolve(BuildContext context, String url) =>
      resolveAgainst(context.dependOnInheritedWidgetOfExactType<ProductImageBase>()?.baseUri, url);

  /// Абсолютный URL: с схемой — как есть; относительный путь — от origin [base] (`/images/x/card` →
  /// `http://host/images/x/card`); без [base] — как есть.
  static String resolveAgainst(Uri? base, String url) {
    final Uri? parsed = Uri.tryParse(url);
    if (base == null || parsed == null || parsed.hasScheme || !base.hasScheme) {
      return url;
    }
    return base.resolve(url.startsWith('/') ? url : '/$url').toString();
  }

  @override
  bool updateShouldNotify(ProductImageBase oldWidget) => oldWidget.baseUri != baseUri;
}

/// Фото товара `ProductImage` (03 §9.14, D-30, INV-050…052).
///
/// Квадрат `surfaceVariant`, радиус по умолчанию `md`; загрузка — скелетон (ANIM-013), появление —
/// fade 200 мс (ANIM-014); нет фото или ошибка загрузки — заглушка «Нет фото» (иконка + подпись),
/// никогда не показывается фото другого товара: URL строит вызывающий по `sha256` своего товара
/// ([pathFor]). Файлы неизменяемы (`/images/{sha256}/{size}.webp`, `Cache-Control: immutable`).
///
/// Без повторного «проявления»: фото из памяти (`ImageCache`) показывается в том же кадре без fade; появление
/// (ANIM-014) — только у первого кадра экземпляра; смена URL у того же экземпляра (обновление выборки кэш → сеть)
/// держит прежний кадр до нового (`gaplessPlayback`, аналог `useOldImageOnUrlChange`) — без затухания в 0.
///
/// Неквадратное поле ([height], ширина — по родителю) и свой фон ([background]) — карточка сетки каталога по
/// прототипу 2026-10-29 (поле 150, `contain` на `surface`); с [background] заглушка — плашка `surfaceVariant` с
/// радиусом `md`, иконкой `image` 34 и подписью «Нет фото».
class ProductImage extends StatefulWidget {
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
    this.height,
    this.background,
  });

  /// URL файла — абсолютный или путь от адреса API (`/images/{sha256}/card`, разрешается [ProductImageBase]);
  /// `null` — фото нет (заглушка).
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

  /// Высота неквадратного поля (ширина — [dimension] или по родителю); `null` — квадрат.
  final double? height;

  /// Фон поля; `null` — `surfaceVariant` (квадрат с фото «в рамке»). С фоном заглушка рисуется плашкой.
  final Color? background;

  /// Относительный путь файла: `/images/{sha256}/{thumb|card|full}.webp` (RM-E-003).
  static String pathFor(String sha256, ProductImageSize size) => '/images/$sha256/${size.name}.webp';

  /// Ширина декодирования по размеру файла (экономия памяти на compact).
  static int cacheWidthOf(ProductImageSize size) => switch (size) {
    ProductImageSize.thumb => 160,
    ProductImageSize.card => 400,
    ProductImageSize.full => 1200,
  };

  @override
  State<ProductImage> createState() => _ProductImageState();
}

class _ProductImageState extends State<ProductImage> {
  /// Экземпляр уже показал кадр фото — дальнейшие смены источника без fade.
  bool _shown = false;

  /// Экземпляр показывал фото через `AnimatedOpacity` (асинхронная загрузка) — форма поддерева сохраняется.
  bool _faded = false;

  String? get url => widget.url;
  ProductImageSize get size => widget.size;
  double? get dimension => widget.dimension;
  BorderRadius? get borderRadius => widget.borderRadius;
  String? get semanticLabel => widget.semanticLabel;
  BoxFit get fit => widget.fit;
  bool get showPlaceholderLabel => widget.showPlaceholderLabel;

  @override
  Widget build(BuildContext context) {
    final BorderRadius radius = borderRadius ?? BorderRadius.all(context.radii.md);
    final Widget body = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final double side = dimension ?? (box.hasBoundedWidth ? box.maxWidth : 160);
        final double h = widget.height ?? side;
        return SizedBox(
          width: side,
          height: h,
          child: ClipRRect(
            borderRadius: radius,
            child: ColoredBox(
              color: widget.background ?? context.colors.surfaceVariant,
              child: _content(context, side, h),
            ),
          ),
        );
      },
    );
    return Semantics(image: true, label: semanticLabel, excludeSemantics: true, child: body);
  }

  Widget _placeholder(double width, double height) => ProductImagePlaceholder(
    side: width < height ? width : height,
    showLabel: showPlaceholderLabel,
    plate: widget.background != null,
  );

  Widget _content(BuildContext context, double side, double height) {
    final String? raw = url;
    if (raw == null || raw.isEmpty) {
      return _placeholder(side, height);
    }
    final String u = ProductImageBase.resolve(context, raw);
    final ProductImageProviderFactory factory = ProductImageScope.maybeOf(context) ?? CachedNetworkImageProvider.new;
    final Duration fade = context.motion.of(const Duration(milliseconds: 200));
    return Image(
      image: ResizeImage.resizeIfNeeded(ProductImage.cacheWidthOf(size), null, factory(u)),
      fit: fit,
      width: side,
      height: height,
      gaplessPlayback: true,
      frameBuilder: (BuildContext context, Widget child, int? frame, bool sync) {
        if (sync && !_faded) {
          // Из памяти в том же кадре — без анимации.
          _shown = true;
          return child;
        }
        // Асинхронная загрузка: fade 0 → 1 только до первого показанного кадра экземпляра; дальше (новый URL,
        // `gaplessPlayback` держит прежний кадр) — сразу 1. Форма поддерева после первого fade не меняется.
        _faded = true;
        final bool visible = _shown || frame != null;
        if (frame != null) {
          _shown = true;
        }
        return AnimatedOpacity(opacity: visible ? 1 : 0, duration: fade, child: child);
      },
      loadingBuilder: (BuildContext context, Widget child, ImageChunkEvent? progress) =>
          progress == null ? child : SkeletonBox(width: side, height: height, radius: Radius.zero),
      errorBuilder: (BuildContext context, Object error, StackTrace? stack) => _placeholder(side, height),
    );
  }
}

/// Заглушка «Нет фото» (INV-050): иконка `image_not_supported` `textTertiary` + подпись `caption textSecondary`.
///
/// [plate] — плашка `surfaceVariant` с радиусом [radius] (по умолчанию `md`) во всё поле: иконка `image` 34
/// `borderStrong` (3.18:1) и подпись [label] (по умолчанию `ds_no_photo`) `caption textSecondary` (кегль 12 — не
/// `textTertiary`, DS-007) — карточка
/// сетки каталога по прототипу 2026-10-29 (без обещания «Фото появится из 1С»).
class ProductImagePlaceholder extends StatelessWidget {
  /// Создаёт заглушку.
  const ProductImagePlaceholder({
    super.key,
    required this.side,
    this.showLabel = true,
    this.plate = false,
    this.label,
    this.radius,
  });

  /// Сторона квадрата (меньшая сторона поля).
  final double side;

  /// Показывать подпись (скрывается у миниатюр меньше 64).
  final bool showLabel;

  /// Плашка во всё поле (карточка сетки).
  final bool plate;

  /// Подпись; по умолчанию «Нет фото» (`ds_no_photo`).
  final String? label;

  /// Скругление плашки; по умолчанию `md`.
  final BorderRadius? radius;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final String text = label ?? AppLocalizations.of(context).ds_no_photo;
    if (plate) {
      return Container(
        key: const ValueKey<String>('product-image-placeholder'),
        decoration: BoxDecoration(color: c.surfaceVariant, borderRadius: radius ?? BorderRadius.all(context.radii.md)),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.image_outlined, size: 34, color: c.borderStrong),
            if (showLabel && side >= 64) ...<Widget>[
              SizedBox(height: context.space.s1),
              Text(
                text,
                style: context.text.caption.copyWith(color: c.textSecondary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      );
    }
    final bool showText = showLabel && side >= 64;
    final double icon = side >= 160 ? 48 : (side >= 64 ? 32 : 20);
    return Center(
      key: const ValueKey<String>('product-image-placeholder'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.image_not_supported_outlined, size: icon, color: c.textTertiary),
          if (showText) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              text,
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
