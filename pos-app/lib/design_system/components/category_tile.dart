import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/category_sidebar_item.dart';
import 'package:optomstroy/design_system/components/ds_glyph.dart';
import 'package:optomstroy/design_system/components/ds_hairline.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/layout/text_measure.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Вариант `CategoryTile` (03 §9.10).
enum CategoryTileVariant {
  /// Плитка сетки (лист «Все категории», SCR-50): 96×96…160×120, обводка выбранной `primaryText` 2.
  grid,

  /// Вертикальная плитка колонки категорий SCR-10/12 на medium и шире (прототип, ADR-114): картинка категории 46×40
  /// или иконка в круге 40 → название `tileLabel 12/600` до 2 строк; во всю ширину колонки, высота ≥ 88.
  sidebar,

  /// Карточка ленты подкатегорий SCR-10/12 (прототип, ADR-114): 118×148 (шире — по самому длинному слову подписи,
  /// [CategoryTile.ribbonWidthFor]), поле картинки 92 сверху → название `ribbonLabel 13/500` до 2 строк.
  ribbon,
}

/// Плитка категории `CategoryTile` (03 §9.10; 02 UI-12-006, лист «Все категории» на compact/medium):
/// карточка 96×96…160×120 → изображение 1С или иконка 32 `primaryText` в круге 56 `primaryContainer`
/// → название `label 500` 2 строки → счётчик `caption`. Выбранная — обводка `primaryText` 2.
///
/// Варианты [CategoryTileVariant.sidebar] и [CategoryTileVariant.ribbon] — значения прототипа без округления
/// (ADR-114): фон `surface`, обводка `border` 1,5 CSS-px ([DsHairline]: 1 lp при DPR 1), радиус `md`; выбранная —
/// заливка `primaryContainer`, обводка `primaryContainerBorder` (декор) и подпись `primaryText` 700 (не только цвет —
/// вес, A11Y-004), смена — 120 мс. Плитка колонки при наведении — обводка `primaryContainerBorder` (замысел дизайнера,
/// ADR-114), у карточки ленты наведения нет (как в прототипе); нажатие — `surfacePressed`, фокус — кольцо, недоступная
/// ([onTap] `null`) — `disabledText`.
///
/// Число товаров ([countLabel]) не рисуется (прототип: без пилюль; паритет функций ADR-114): оно — в подсказке
/// «{название}, N товаров» (задержка 700 мс) и в `Semantics` ([semanticLabel]). Подпись переносится только между
/// словами — ширину, при которой самое длинное слово помещается, дают [sidebarMinWidthFor] и [ribbonWidthFor].
///
/// Картинка — только изображение категории из данных ([imageUrl]; плитка колонки — `contain` 46×40, карточка ленты —
/// `scaleDown` в 96×88, без увеличения; `FilterQuality.high`, без фона). Без неё и при ошибке загрузки: у плитки
/// колонки — иконка по `iconKey`/названию ([CategoryIcons.resolve]) 22 в круге 40 `ribbonPlaceholderBg`; у карточки
/// ленты — круг 56 `ribbonPlaceholderBg` с иконкой 26 явного `iconKey` сервера или с глифом «четыре квадрата» (как у
/// «Все товары» и подкатегорий без фото в прототипе). Фото товара не подставляется (CAT-009).
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

  /// Наименьший размер карточки ленты подкатегорий (прототип: `flex: 0 0 118px`, высота 148).
  static const Size ribbonSize = DsCatalogMetrics.ribbonCard;

  /// Высота поля картинки карточки ленты (картинка ≤ 96×88, `scaleDown`).
  static const double ribbonImageHeight = 92;

  /// Наибольший размер картинки карточки ленты.
  static const Size ribbonImageMax = Size(96, 88);

  /// Минимальная высота блока подписи карточки ленты (прототип: `min-height: 31px`).
  static const double ribbonLabelMinHeight = 31;

  /// Поля карточки ленты: сверху 8, по бокам 8, снизу 10.
  static const EdgeInsets ribbonPadding = EdgeInsets.fromLTRB(8, 8, 8, 10);

  /// Минимальная высота плитки колонки категорий (с обводкой).
  static const double sidebarMinHeight = DsCatalogMetrics.tileMinHeight;

  /// Поле картинки плитки колонки (`contain`).
  static const Size sidebarArt = DsCatalogMetrics.tileArt;

  /// Зазор картинка — подпись плитки колонки (прототип: gap 6).
  static const double sidebarGap = 6;

  /// Смена фона и обводки (прототип: `transition: 120ms ease`).
  static const Duration transition = Duration(milliseconds: 120);

  /// Название.
  final String label;

  /// Открыть категорию; `null` — недоступна.
  final VoidCallback? onTap;

  /// «124» / «124 товара» — не рисуется; входит в подсказку и `Semantics`, если нет [semanticLabel].
  final String? countLabel;

  /// Изображение 1С.
  final String? imageUrl;

  /// Ключ иконки.
  final String? iconKey;

  /// Явная иконка (например, «Избранное» — `star`); иначе — по [iconKey]/[label].
  final IconData? icon;

  /// Текущая категория.
  final bool selected;

  /// «Смесители, 124 товаров» (`category_tile_a11y`) — `Semantics` и подсказка.
  final String? semanticLabel;

  /// Вариант.
  final CategoryTileVariant variant;

  /// Подпись под иконкой (`sidebar`; свёрнутая колонка — только иконка с тултипом).
  final bool showLabel;

  /// Иконка заглушки карточки ленты без картинки (по умолчанию — иконка явного [iconKey] или контурный глиф
  /// «четыре квадрата» `DsGlyphKind.gridOutline`; так же — первая карточка «Все товары»).
  final IconData? placeholderIcon;

  bool get _hasImage => imageUrl != null && imageUrl!.isNotEmpty;

  /// Подпись `Semantics` и подсказки: [semanticLabel], иначе название с [countLabel].
  String get _a11y => semanticLabel ?? (countLabel == null ? label : '$label, $countLabel');

  /// Самое длинное слово [text] стилем [style] (lp, с масштабом шрифта системы).
  static double _longestWord(BuildContext context, String text, TextStyle style) {
    double widest = 0;
    for (final String word in text.split(RegExp(r'\s+'))) {
      if (word.isNotEmpty) {
        widest = math.max(widest, dsTextWidth(context, word, style));
      }
    }
    return widest;
  }

  /// Ширина плитки колонки, при которой самое длинное слово [label] помещается в строку (прототип: плитка растёт по
  /// min-content — «Водоснабжение» даёт 111,3): слово + поля 6 + 6 + обводки; выбранная — по весу 700. Колонка берёт
  /// наибольшую ширину по своим плиткам (целые lp — вызывающий).
  static double sidebarMinWidthFor(BuildContext context, String label, {bool selected = false}) {
    final DsTypography t = context.text;
    final double word = _longestWord(context, label, selected ? t.tileLabelSelected : t.tileLabel);
    return word + DsCatalogMetrics.tilePadding.horizontal + 2 * DsHairline.of(context, 1.5);
  }

  /// Ширина карточки ленты для подписи [label]: max(118, ceil(самое длинное слово `ribbonLabel` + поля 8 + 8 +
  /// обводки)) — прототип: `flex: 0 0 118px`, растёт по min-content («Канализационные трубы и фитинги» — 136);
  /// выбранная — по весу 700, как в браузере.
  static double ribbonWidthFor(BuildContext context, String label, {bool selected = false}) {
    final DsTypography t = context.text;
    final double word = _longestWord(context, label, selected ? t.ribbonLabelSelected : t.ribbonLabel);
    final double need = (word + ribbonPadding.horizontal + 2 * DsHairline.of(context, 1.5)).ceilToDouble();
    return math.max(ribbonSize.width, need);
  }

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
                        // Лист «Все категории» — прежний вид: поле `surfaceVariant`, скругление `sm`, `cover`.
                        background: c.surfaceVariant,
                        radius: BorderRadius.all(context.radii.sm),
                        fit: BoxFit.cover,
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
    final double border = DsHairline.of(context, 1.5);
    final Widget tile = DsInteractive(
      // Повторный тап по выбранной решает вызывающий (корень, когда открыта его подкатегория, — переход к корню).
      onTap: onTap,
      enabled: enabled,
      builder: (BuildContext context, DsInteractionState s) {
        final Color fg = !enabled ? c.disabledText : (selected ? c.primaryText : c.textPrimary);
        final Color bg = selected ? c.primaryContainer : (enabled && s.pressed ? c.surfacePressed : c.surface);
        // Рамка тинта — декоративная (1.54:1); выбранное отличается заливкой, жирностью и цветом подписи (A11Y-004).
        // Наведение — только у плитки колонки (`.tile:hover` прототипа); у карточки ленты его нет.
        final bool hover = !ribbon && enabled && s.hovered;
        final Color line = selected || hover ? c.primaryContainerBorder : c.border;
        final DsTypography t = context.text;
        final TextStyle labelStyle = ribbon
            ? (selected ? t.ribbonLabelSelected : t.ribbonLabel).copyWith(color: fg)
            : (selected ? t.tileLabelSelected : t.tileLabel).copyWith(color: fg);
        final Widget text = _TileLabel(text: label, style: labelStyle);
        final Widget body = ribbon
            ? Padding(
                padding: ribbonPadding,
                // Прототип: колонка `space-between` — поле картинки 92 сверху, блок подписи (min-height 31, текст у его
                // верха) прижат к низу: подписи в одну строку — на линии первых строк двухстрочных.
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    SizedBox(
                      height: ribbonImageHeight,
                      child: Center(child: _ribbonArt(context, c)),
                    ),
                    Flexible(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: ribbonLabelMinHeight),
                        child: Align(alignment: Alignment.topCenter, heightFactor: 1, child: text),
                      ),
                    ),
                  ],
                ),
              )
            : Padding(
                padding: showLabel
                    ? DsCatalogMetrics.tilePadding
                    : EdgeInsets.symmetric(horizontal: context.space.s1, vertical: context.space.s2),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    _sidebarArt(context, c),
                    if (showLabel) ...<Widget>[const SizedBox(height: sidebarGap), text],
                  ],
                ),
              );
        return DsFocusRing(
          visible: s.focused,
          borderRadius: radius,
          child: AnimatedContainer(
            duration: context.motion.of(transition),
            curve: Curves.ease,
            width: ribbon ? ribbonWidthFor(context, label, selected: selected) : null,
            height: ribbon ? ribbonSize.height : null,
            constraints: ribbon ? null : BoxConstraints(minHeight: showLabel ? sidebarMinHeight : 56),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: radius,
              border: Border.all(color: line, width: border),
            ),
            child: body,
          ),
        );
      },
    );
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: _a11y,
      excludeSemantics: true,
      // Действие «нажать» для TalkBack/Narrator (основная навигация экрана): жест DsInteractive из семантики исключён.
      onTap: onTap,
      // Число товаров — в подсказке (паритет функций ADR-114: пилюли нет); у свёрнутой плитки — и название.
      child: AppTooltip(message: _a11y, waitDuration: const Duration(milliseconds: 700), child: tile),
    );
  }

  /// Иконка-заглушка плитки колонки: иконка 22 по `iconKey`/названию в круге 40 `ribbonPlaceholderBg` (выбранная —
  /// `surface`, иконка `primaryText`), по центру поля 46×40.
  Widget _sidebarIcon(DsColors c) {
    final Color fg = onTap == null ? c.disabledText : (selected ? c.primaryText : c.textPrimary);
    return Center(
      key: const ValueKey<String>('category-tile-icon'),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(color: selected ? c.surface : c.ribbonPlaceholderBg, shape: BoxShape.circle),
        child: Icon(
          icon ?? CategoryIcons.resolve(key: iconKey, name: label),
          size: 22,
          color: fg,
        ),
      ),
    );
  }

  /// Картинка плитки колонки: изображение категории 46×40 `contain` без фона; без него и при ошибке — иконка в круге.
  Widget _sidebarArt(BuildContext context, DsColors c) => SizedBox.fromSize(
    size: sidebarArt,
    child: _hasImage
        ? CategoryImage(
            imageUrl: imageUrl,
            iconKey: iconKey,
            name: label,
            width: sidebarArt.width,
            height: sidebarArt.height,
            fallback: _sidebarIcon(c),
          )
        : _sidebarIcon(c),
  );

  /// Заглушка карточки ленты: круг 56 `ribbonPlaceholderBg` (и на выбранной, как в прототипе) с иконкой 26 —
  /// [icon], [placeholderIcon] или иконка явного `iconKey` сервера, иначе глиф «четыре квадрата» `ribbonGlyph`.
  Widget _ribbonPlaceholder(DsColors c) {
    final Color fg = onTap == null ? c.disabledText : c.ribbonGlyph;
    final IconData? known = CategoryIcons.of(iconKey) == Icons.category_rounded ? null : CategoryIcons.of(iconKey);
    final IconData? glyph = icon ?? placeholderIcon ?? known;
    return Container(
      key: const ValueKey<String>('category-tile-placeholder'),
      width: 56,
      height: 56,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.ribbonPlaceholderBg, shape: BoxShape.circle),
      child: glyph == null
          ? DsGlyph(kind: DsGlyphKind.gridOutline, size: 26, color: fg)
          : Icon(glyph, size: 26, color: fg),
    );
  }

  /// Поле картинки карточки ленты (высота [ribbonImageHeight]): изображение категории ≤ 96×88 `scaleDown` (без
  /// увеличения), без фона; без него и при ошибке — заглушка [_ribbonPlaceholder].
  Widget _ribbonArt(BuildContext context, DsColors c) {
    if (!_hasImage) {
      return _ribbonPlaceholder(c);
    }
    return CategoryImage(
      imageUrl: imageUrl,
      iconKey: iconKey,
      name: label,
      width: ribbonImageMax.width,
      height: ribbonImageMax.height,
      fit: BoxFit.scaleDown,
      fallback: Center(child: _ribbonPlaceholder(c)),
    );
  }
}

/// Подпись плитки колонки и карточки ленты: до 2 строк по центру, перенос — только между словами, кегль не меняется
/// (прототип: `line-clamp: 2`). Ширину, при которой самое длинное слово помещается, даёт вызывающий
/// ([CategoryTile.sidebarMinWidthFor], [CategoryTile.ribbonWidthFor]); если слово всё же шире строки (узкое окно,
/// крупный шрифт системы), оно не переносится посередине: строки раскладываются по словам, лишнее обрезается
/// многоточием. Вторая строка — только если помещается по высоте (крупный шрифт — одна строка с многоточием).
class _TileLabel extends StatelessWidget {
  const _TileLabel({required this.text, required this.style});

  /// Ключ подписи (первая строка при раскладке по словам).
  static const Key labelKey = ValueKey<String>('category-tile-label');

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints box) {
      final TextScaler scaler = MediaQuery.textScalerOf(context);
      final double lineHeight = scaler.scale(style.fontSize ?? 12) * (style.height ?? 1.2);
      final int maxLines = !box.hasBoundedHeight || box.maxHeight + 0.5 >= lineHeight * 2 ? 2 : 1;
      final List<String> words = text.split(RegExp(r'\s+')).where((String w) => w.isNotEmpty).toList();
      final double maxWidth = box.maxWidth;
      double widest = 0;
      for (final String word in words) {
        widest = math.max(widest, dsTextWidth(context, word, style));
      }
      if (!box.hasBoundedWidth || widest <= maxWidth) {
        // Все слова помещаются в строку — обычный перенос по словам.
        return Text(
          text,
          key: labelKey,
          maxLines: maxLines,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: style,
        );
      }
      // Слово шире строки: строки собираются по словам (≤ maxLines), каждая — в одну линию с многоточием.
      final double space = dsTextWidth(context, ' ', style);
      final List<String> lines = <String>[];
      String current = '';
      double width = 0;
      for (final String word in words) {
        final double w = dsTextWidth(context, word, style);
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
            ),
        ],
      );
    },
  );
}
