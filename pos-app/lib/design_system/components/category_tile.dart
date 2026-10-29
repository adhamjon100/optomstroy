import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/category_sidebar_item.dart';
import 'package:optomstroy/design_system/components/ds_glyph.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/layout/text_measure.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Вариант `CategoryTile` (03 §9.10).
enum CategoryTileVariant {
  /// Плитка сетки (лист «Все категории», SCR-50): 96×96…160×120, обводка выбранной `primaryText` 2.
  grid,

  /// Вертикальная плитка колонки категорий SCR-10/12 на medium и шире (прототип 2026-10-29): изображение категории
  /// 46×40 или иконка в круге 40 → название `caption 600` до 2 строк; во всю ширину колонки, высота ≥ 88.
  sidebar,

  /// Карточка ленты подкатегорий SCR-10/12 (прототип 2026-10-29): фиксированный размер [CategoryTile.ribbonSize]
  /// 118×148, поле картинки 92 сверху → название `label 500` до 2 строк.
  ribbon,
}

/// Плитка категории `CategoryTile` (03 §9.10; 02 UI-12-006, лист «Все категории» на compact/medium):
/// карточка 96×96…160×120 → изображение 1С или иконка 32 `primaryText` в круге 56 `primaryContainer`
/// → название `label 500` 2 строки → счётчик `caption`. Выбранная — обводка `primaryText` 2.
///
/// Варианты [CategoryTileVariant.sidebar] и [CategoryTileVariant.ribbon] (экран выбора товаров по прототипу
/// 2026-10-29, ADR-112): фон `surface`, обводка `border` 1,5, радиус `md`; выбранная — заливка `primaryContainer`,
/// обводка `primaryContainerBorder` (декор) и подпись `primaryText` 700 (не только цвет — вес, A11Y-004), без
/// анимации масштаба; hover — обводка `primaryContainerBorder`, pressed — `surfacePressed`, фокус — кольцо,
/// недоступная ([onTap] `null`) — `disabledText`. Число товаров [countLabel] — пилюля `surfaceVariant` с
/// `micro 600 textSecondary tnum` в правом верхнем углу (паритет функций ADR-112: счётчик категории виден, как в
/// прежнем сайдбаре); у плитки без подписи ([showLabel] `false`) — только в тултипе ([semanticLabel]). Картинка —
/// только изображение категории из данных ([imageUrl],
/// `contain`); без неё у плитки колонки — иконка по `iconKey`/названию ([CategoryIcons.resolve]) в круге 40, у
/// карточки ленты — нейтральная заглушка [placeholderIcon] в круге 56. Фото товара не подставляется (CAT-009).
class CategoryTile extends StatelessWidget {
  /// Создаёт плитку.
  const CategoryTile({
    super.key,
    required this.label,
    required this.onTap,
    this.countLabel,
    this.imageUrl,
    this.iconKey,
    this.icon,
    this.selected = false,
    this.semanticLabel,
    this.variant = CategoryTileVariant.grid,
    this.showLabel = true,
    this.placeholderIcon,
  });

  /// Размер карточки ленты подкатегорий (одинаковый у всех карточек; прототип 2026-10-29 — 118×148).
  static const Size ribbonSize = Size(118, 148);

  /// Высота поля картинки карточки ленты (картинка ≤ 96×88, `contain`).
  static const double ribbonImageHeight = 92;

  /// Минимальная высота плитки колонки категорий.
  static const double sidebarMinHeight = 88;

  /// Название.
  final String label;

  /// Открыть категорию; `null` — недоступна.
  final VoidCallback? onTap;

  /// «124» / «124 товара».
  final String? countLabel;

  /// Изображение 1С.
  final String? imageUrl;

  /// Ключ иконки.
  final String? iconKey;

  /// Явная иконка (например, «Избранное» — `star`); иначе — по [iconKey]/[label].
  final IconData? icon;

  /// Текущая категория.
  final bool selected;

  /// «Смесители, 124 товаров» (`category_tile_a11y`).
  final String? semanticLabel;

  /// Вариант.
  final CategoryTileVariant variant;

  /// Подпись под иконкой (`sidebar`; свёрнутая колонка — только иконка с тултипом).
  final bool showLabel;

  /// Глиф заглушки карточки ленты без картинки (по умолчанию — контурная «сетка» `DsGlyphKind.gridOutline`; так же —
  /// первая карточка «Все товары»).
  final IconData? placeholderIcon;

  bool get _hasImage => imageUrl != null && imageUrl!.isNotEmpty;

  @override
  Widget build(BuildContext context) => switch (variant) {
    CategoryTileVariant.grid => _grid(context),
    CategoryTileVariant.sidebar || CategoryTileVariant.ribbon => _compactTile(context),
  };

  Widget _grid(BuildContext context) {
    final DsColors c = context.colors;
    return Semantics(
      button: true,
      selected: selected,
      enabled: onTap != null,
      label: semanticLabel ?? label,
      excludeSemantics: true,
      // Действие «нажать» для TalkBack/Narrator: жест DsInteractive из семантики исключён.
      onTap: onTap,
      child: DsInteractive(
        onTap: onTap,
        builder: (BuildContext context, DsInteractionState s) {
          final double scale = s.pressed && !context.motion.reduceMotion ? 0.98 : 1;
          return AnimatedScale(
            scale: scale,
            duration: context.motion.of(context.motion.fast),
            child: DsFocusRing(
              visible: s.focused,
              borderRadius: BorderRadius.all(context.radii.md),
              child: Container(
                constraints: const BoxConstraints(minWidth: 96, minHeight: 96),
                padding: EdgeInsets.all(context.space.s2),
                decoration: BoxDecoration(
                  color: s.pressed ? c.surfacePressed : c.surface,
                  borderRadius: BorderRadius.all(context.radii.md),
                  border: Border.all(color: selected ? c.primaryText : c.border, width: selected ? 2 : 1),
                  boxShadow: s.hovered ? context.elevation.e1 : null,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    if (_hasImage)
                      CategoryImage(
                        imageUrl: imageUrl,
                        iconKey: iconKey,
                        name: label,
                        size: 56,
                        iconSize: 32,
                        color: c.primaryText,
                      )
                    else
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(color: c.primaryContainer, shape: BoxShape.circle),
                        child: Icon(
                          icon ?? CategoryIcons.resolve(key: iconKey, name: label),
                          size: 32,
                          color: c.primaryText,
                        ),
                      ),
                    SizedBox(height: context.space.s2),
                    Text(
                      label,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.label.copyWith(fontWeight: FontWeight.w500, color: c.textPrimary),
                    ),
                    if (countLabel != null)
                      Text(
                        countLabel!,
                        maxLines: 1,
                        style: context.text.caption.copyWith(
                          color: c.textSecondary,
                          fontFeatures: DsTypography.numeric,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _compactTile(BuildContext context) {
    final DsColors c = context.colors;
    final bool ribbon = variant == CategoryTileVariant.ribbon;
    final bool enabled = onTap != null;
    final BorderRadius radius = BorderRadius.all(context.radii.md);
    final Widget tile = DsInteractive(
      // Повторный тап по выбранной решает вызывающий (корень, когда открыта его подкатегория, — переход к корню).
      onTap: onTap,
      enabled: enabled,
      builder: (BuildContext context, DsInteractionState s) {
        final Color fg = !enabled ? c.disabledText : (selected ? c.primaryText : c.textPrimary);
        final Color bg = selected ? c.primaryContainer : (enabled && s.pressed ? c.surfacePressed : c.surface);
        // Рамка тинта — декоративная (1.54:1); выбранное отличается заливкой, жирностью и цветом подписи (A11Y-004).
        final Color border = selected || (enabled && s.hovered) ? c.primaryContainerBorder : c.border;
        final Widget art = ribbon ? _ribbonArt(context, c) : _sidebarArt(context, c);
        final TextStyle labelStyle = (ribbon ? context.text.label : context.text.caption).copyWith(
          height: 1.2,
          fontWeight: selected ? FontWeight.w700 : (ribbon ? FontWeight.w500 : FontWeight.w600),
          color: fg,
        );
        final Widget text = _TileLabel(
          text: label,
          // Карточка ленты — кегль не уменьшается (прототип: line-clamp 2); плитка колонки — до 80 % (03 §9.10).
          shrink: !ribbon,
          style: labelStyle,
        );
        // Поля 8 / 8 / 12 (сверху / по бокам / снизу; у карточки ленты снизу 10, как в прототипе); у плитки колонки
        // (100 lp) по бокам 4 — подписи вроде «Водоснабжение» помещаются (прототип: 6).
        final double sideInset = ribbon ? context.space.s2 : context.space.s1;
        final EdgeInsets padding = EdgeInsets.fromLTRB(
          sideInset,
          context.space.s2,
          sideInset,
          ribbon ? context.space.s2 + 2 : (showLabel ? context.space.s3 : context.space.s2),
        );
        // Карточка ленты (прототип: space-between, подпись line-clamp 2 с min-height 2 строки): блок подписи высотой
        // 2 строки прижат к низу, одна строка — у его верха, на линии первых строк двухстрочных подписей. Число строк
        // подпись выбирает по всей высоте под картинкой (крупный шрифт системы — одна строка с многоточием).
        final Widget body = ribbon
            ? Padding(
                padding: padding,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    SizedBox(
                      height: ribbonImageHeight,
                      child: Center(child: art),
                    ),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (BuildContext context, BoxConstraints box) {
                          final TextScaler scaler = MediaQuery.textScalerOf(context);
                          final double twoLines = scaler.scale(labelStyle.fontSize!) * labelStyle.height! * 2;
                          return Stack(
                            clipBehavior: Clip.none,
                            children: <Widget>[
                              Positioned(
                                top: math.max(0, box.maxHeight - twoLines),
                                left: 0,
                                right: 0,
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(maxHeight: box.maxHeight),
                                  child: Align(alignment: Alignment.topCenter, heightFactor: 1, child: text),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
              )
            : ConstrainedBox(
                constraints: BoxConstraints(minHeight: showLabel ? sidebarMinHeight : 56),
                child: Padding(
                  padding: padding,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      art,
                      if (showLabel) ...<Widget>[SizedBox(height: context.space.s2), text],
                    ],
                  ),
                ),
              );
        final String? count = showLabel ? countLabel : null;
        return DsFocusRing(
          visible: s.focused,
          borderRadius: radius,
          child: AnimatedContainer(
            duration: context.motion.of(context.motion.fast),
            width: ribbon ? ribbonSize.width : null,
            height: ribbon ? ribbonSize.height : null,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: radius,
              border: Border.all(color: border, width: 1.5),
            ),
            child: count == null
                ? body
                : Stack(
                    // Ограничения рамки — телу как есть: плитка колонки (ширина 100 от списка) не сжимается до ширины
                    // содержимого у левого края, картинка и подпись — по центру, как без пилюли (QA паритета).
                    fit: StackFit.passthrough,
                    children: <Widget>[
                      body,
                      PositionedDirectional(top: 5, end: 5, child: _CountPill(text: count)),
                    ],
                  ),
          ),
        );
      },
    );
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: semanticLabel ?? label,
      excludeSemantics: true,
      // Действие «нажать» для TalkBack/Narrator (основная навигация экрана): жест DsInteractive из семантики исключён.
      onTap: onTap,
      child: showLabel ? tile : AppTooltip(message: semanticLabel ?? label, child: tile),
    );
  }

  /// Картинка плитки колонки: изображение категории 46×40 `contain` на прозрачном фоне; без него — иконка по
  /// `iconKey`/названию в круге 40 `surfaceVariant`.
  Widget _sidebarArt(BuildContext context, DsColors c) {
    if (_hasImage) {
      return CategoryImage(
        imageUrl: imageUrl,
        iconKey: iconKey,
        name: label,
        width: 46,
        height: 40,
        iconSize: 24,
        color: c.textSecondary,
        background: Colors.transparent,
        radius: BorderRadius.zero,
        fit: BoxFit.contain,
      );
    }
    final Color fg = onTap == null ? c.disabledText : (selected ? c.onPrimaryContainer : c.textSecondary);
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(color: selected ? c.surface : c.surfaceVariant, shape: BoxShape.circle),
      child: Icon(
        icon ?? CategoryIcons.resolve(key: iconKey, name: label),
        size: 22,
        color: fg,
      ),
    );
  }

  /// Поле картинки карточки ленты (высота [ribbonImageHeight]): изображение категории ≤ 96×88 `contain`; без него —
  /// нейтральная заглушка: круг 56 `surfaceVariant` с контурным глифом «сетка» `DsGlyphKind.gridOutline` 26 (или
  /// [placeholderIcon]) `borderStrong` (3.18:1).
  Widget _ribbonArt(BuildContext context, DsColors c) {
    if (_hasImage) {
      return CategoryImage(
        imageUrl: imageUrl,
        iconKey: iconKey,
        name: label,
        width: 96,
        height: 88,
        iconSize: 32,
        color: c.textSecondary,
        background: Colors.transparent,
        radius: BorderRadius.zero,
        fit: BoxFit.contain,
      );
    }
    final Color fg = onTap == null ? c.disabledText : c.borderStrong;
    return Container(
      key: const ValueKey<String>('category-tile-placeholder'),
      width: 56,
      height: 56,
      alignment: Alignment.center,
      // Круг `surfaceVariant` — и на выбранной карточке (прототип: #EEF3FA на тинте).
      decoration: BoxDecoration(color: c.surfaceVariant, shape: BoxShape.circle),
      child: placeholderIcon == null
          ? DsGlyph(kind: DsGlyphKind.gridOutline, size: 26, color: fg)
          : Icon(placeholderIcon, size: 26, color: fg),
    );
  }
}

/// Число товаров плитки колонки и карточки ленты: пилюля 16 `surfaceVariant`, `micro 600 textSecondary tnum`.
class _CountPill extends StatelessWidget {
  const _CountPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Container(
      key: const ValueKey<String>('category-tile-count'),
      height: 16,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.surfaceVariant, borderRadius: BorderRadius.all(context.radii.full)),
      child: Text(
        text,
        maxLines: 1,
        textScaler: TextScaler.noScaling,
        style: context.text.micro.copyWith(
          color: c.textSecondary,
          fontWeight: FontWeight.w600,
          fontFeatures: DsTypography.numeric,
          height: 1,
        ),
      ),
    );
  }
}

/// Подпись плитки колонки и карточки ленты: до 2 строк по центру, перенос — только между словами.
///
/// Плитка колонки ([shrink]): если самое длинное слово шире строки («Водоснабжение» в плитке 100), шрифт уменьшается до
/// ширины слова, но не ниже 80 %. Карточка ленты — кегль не меняется (прототип: line-clamp 2). Слово, которое не
/// помещается в строку и так («Электроинструмент» в карточке 118), не переносится посередине: строки раскладываются по
/// словам, лишнее обрезается многоточием.
class _TileLabel extends StatelessWidget {
  const _TileLabel({required this.text, required this.style, required this.shrink});

  /// Минимальный масштаб подписи.
  static const double minFactor = 0.8;

  /// Ключ подписи (первая строка при раскладке по словам).
  static const Key labelKey = ValueKey<String>('category-tile-label');

  final String text;
  final TextStyle style;

  /// Уменьшать кегль до [minFactor], если слово не помещается (плитка колонки).
  final bool shrink;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints box) {
      final TextScaler scaler = MediaQuery.textScalerOf(context);
      final List<String> words = text.split(RegExp(r'\s+')).where((String w) => w.isNotEmpty).toList();
      final double maxWidth = box.maxWidth;
      double widest = 0;
      for (final String word in words) {
        widest = math.max(widest, dsTextWidth(context, word, style));
      }
      final bool tooWide = box.hasBoundedWidth && widest > maxWidth && widest > 0;
      final double factor = shrink && tooWide ? math.max(minFactor, (maxWidth - 1) / widest) : 1;
      final double fontSize = style.fontSize ?? 12;
      final TextScaler effective = factor == 1 ? scaler : TextScaler.linear(scaler.scale(fontSize) / fontSize * factor);
      if (!tooWide || widest * factor <= maxWidth - 0.5) {
        // Все слова помещаются в строку — обычный перенос по словам.
        return Text(
          text,
          key: labelKey,
          maxLines: 2,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: style,
          textScaler: effective,
        );
      }
      // Слово шире строки: строки собираются по словам (≤ 2), каждая — в одну линию с многоточием.
      final double space = dsTextWidth(context, ' ', style) * factor;
      final List<String> lines = <String>[];
      String current = '';
      double width = 0;
      for (final String word in words) {
        final double w = dsTextWidth(context, word, style) * factor;
        if (current.isEmpty) {
          current = word;
          width = w;
        } else if (lines.isEmpty && width + space + w <= maxWidth - 1) {
          current = '$current $word';
          width += space + w;
        } else if (lines.isEmpty) {
          lines.add(current);
          current = word;
          width = w;
        } else {
          current = '$current $word';
        }
      }
      if (current.isNotEmpty) lines.add(current);
      // Вторая строка — только если помещается по высоте (крупный шрифт системы — одна строка с многоточием).
      final TextPainter probe = TextPainter(
        text: TextSpan(text: lines.first, style: style),
        textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
        textScaler: effective,
        maxLines: 1,
      )..layout();
      final double lineHeight = probe.height;
      probe.dispose();
      final int maxLines = !box.hasBoundedHeight || box.maxHeight >= lineHeight * 2 ? 2 : 1;
      if (lines.length > maxLines) {
        lines.replaceRange(maxLines - 1, lines.length, <String>[lines.sublist(maxLines - 1).join(' ')]);
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < lines.length; i++)
            Text(
              lines[i],
              key: i == 0 ? labelKey : null,
              maxLines: 1,
              softWrap: false,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: style,
              textScaler: effective,
            ),
        ],
      );
    },
  );
}
