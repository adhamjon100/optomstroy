import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_badge.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Вариант `CartPanel` (03 §9.27).
enum CartPanelVariant {
  /// expanded/large: постоянная третья колонка 320/340, `elevation.1`, граница слева.
  panel,

  /// medium: side sheet 320, `elevation.2`, радиус `lg` слева, крестик закрытия.
  overlay,

  /// compact: полноэкранный маршрут `/cart`.
  screen,
}

/// Корзина `CartPanel` (03 §9.27; 02 SCR-20.2): шапка 56 (заголовок `title 18/600` + бейдж `primary` числа позиций,
/// действия справа, на `overlay` — крестик) и строка счётчиков [counter] → [banner] → [top] (клиент и склад) →
/// [body] (список строк, прокрутка внутри) → закреплённые снизу [bottom] (скидка, итоги) и [footer] (подпись
/// причины, «Отложить заказ», «Создать заказ →») над `SafeArea`. Фон `surface`, разделители `border`.
///
/// Компонент — только раскладка; данные, действия и тексты передаёт экран.
class CartPanel extends StatelessWidget {
  /// Создаёт панель.
  const CartPanel({
    super.key,
    required this.title,
    required this.body,
    this.variant = CartPanelVariant.panel,
    this.count = 0,
    this.countLabel,
    this.counter,
    this.counterTrailing,
    this.actions = const <Widget>[],
    this.banner,
    this.top,
    this.bottom,
    this.footer,
    this.onClose,
    this.closeLabel,
    this.semanticLabel,
    this.overlay,
  });

  /// Высота области под шапкой, ниже которой строки, итоги и кнопки прокручиваются вместе.
  static const double compactHeight = 480; // money-double: allow — высота раскладки (lp), не деньги

  /// Высота списка строк в прокручиваемой раскладке низкого окна.
  static const double minBodyHeight = 200; // money-double: allow — высота раскладки (lp), не деньги

  /// Ключ прокручиваемой раскладки низкого окна (тесты).
  static const Key scrollKey = ValueKey<String>('cart-panel-compact-scroll');

  final CartPanelVariant variant;

  /// «Корзина».
  final String title;

  /// Число позиций для бейджа (скрыт при 0).
  final int count;

  /// «5 позиций» — подпись бейджа для screen reader.
  final String? countLabel;

  /// «5 поз. · 6 шт» (UI-20-021).
  final String? counter;

  /// Справа в строке счётчиков — индикатор сохранения (UI-20-023).
  final Widget? counterTrailing;

  /// Действия шапки («Отложенные (n)», «Очистить»).
  final List<Widget> actions;

  /// Баннер зоны C.
  final Widget? banner;

  /// Зона B — клиент и склад.
  final Widget? top;

  /// Зона D — строки (или пустое состояние, скелетон).
  final Widget body;

  /// Зоны E–F — скидка и итоги (закреплены над [footer]).
  final Widget? bottom;

  /// Зона G — действия.
  final Widget? footer;

  /// Крестик (`overlay`).
  final VoidCallback? onClose;
  final String? closeLabel;

  /// Регион «Корзина, 5 позиций, итого …».
  final String? semanticLabel;

  /// Зона H — оверлей поверх D–G (блокировка «Проверяем результат…»).
  final Widget? overlay;

  /// Ширина панели для ширины окна [windowWidth] (02 SCR-20.2: 320 — medium и expanded < 1280, 340 — шире).
  static double widthFor(double windowWidth) => windowWidth >= 1280 ? DsBreakpoints.cartWide : DsBreakpoints.cartNarrow;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final Widget header = Container(
      padding: EdgeInsetsDirectional.only(
        start: context.space.s5,
        end: context.space.s2,
        top: context.space.s2,
        bottom: context.space.s1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            height: 48,
            child: Row(
              children: <Widget>[
                Flexible(
                  child: Semantics(
                    header: true,
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.title.copyWith(fontWeight: FontWeight.w600, color: c.textPrimary),
                    ),
                  ),
                ),
                if (count > 0) ...<Widget>[
                  SizedBox(width: context.space.s2),
                  AppBadge(count: count, tone: AppBadgeTone.cart, semanticLabel: countLabel),
                ],
                const Spacer(),
                ...actions,
                if (onClose != null)
                  AppIconButton(icon: Icons.close_rounded, semanticLabel: closeLabel ?? '', onPressed: onClose),
              ],
            ),
          ),
          if (counter != null || counterTrailing != null)
            SizedBox(
              height: 20,
              child: Row(
                children: <Widget>[
                  if (counter != null)
                    Expanded(
                      child: Text(
                        counter!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.caption.copyWith(
                          color: c.textSecondary,
                          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                  ?counterTrailing,
                  SizedBox(width: context.space.s3),
                ],
              ),
            ),
        ],
      ),
    );
    final Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        header,
        Divider(height: 1, thickness: 1, color: c.border),
        ?banner,
        ?top,
        Expanded(
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints box) {
                    final List<Widget> pinned = <Widget>[
                      if (bottom != null) ...<Widget>[Divider(height: 1, thickness: 1, color: c.border), bottom!],
                      if (footer != null)
                        SafeArea(
                          top: false,
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              context.space.s5,
                              context.space.s2,
                              context.space.s5,
                              context.space.s4,
                            ),
                            child: footer,
                          ),
                        ),
                    ];
                    // Низкое окно (Windows-POS 1280×720 с баннером и строкой клиента): закреплённые итоги и кнопки
                    // не помещаются под списком — область прокручивается целиком, список строк — не ниже
                    // [minBodyHeight] (без переполнения, кнопка «Создать заказ» достижима).
                    if (box.maxHeight < compactHeight && pinned.isNotEmpty) {
                      return SingleChildScrollView(
                        key: scrollKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            SizedBox(height: minBodyHeight, child: body),
                            ...pinned,
                          ],
                        ),
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Expanded(child: body),
                        ...pinned,
                      ],
                    );
                  },
                ),
              ),
              if (overlay != null) Positioned.fill(child: overlay!),
            ],
          ),
        ),
      ],
    );
    final BoxDecoration decoration = switch (variant) {
      CartPanelVariant.panel => BoxDecoration(
        color: c.surface,
        border: Border(left: BorderSide(color: c.border)),
      ),
      CartPanelVariant.overlay => BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadiusDirectional.horizontal(start: context.radii.lg),
        boxShadow: context.elevation.e2,
      ),
      CartPanelVariant.screen => BoxDecoration(color: c.surface),
    };
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: semanticLabel,
      child: DecoratedBox(
        decoration: decoration,
        child: ClipRRect(
          borderRadius: variant == CartPanelVariant.overlay
              ? BorderRadiusDirectional.horizontal(start: context.radii.lg).resolve(Directionality.of(context))
              : BorderRadius.zero,
          child: content,
        ),
      ),
    );
  }
}
