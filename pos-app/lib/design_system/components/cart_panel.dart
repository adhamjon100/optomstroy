import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:optomstroy/design_system/components/app_badge.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Вариант `CartPanel` (03 §9.27).
enum CartPanelVariant {
  /// expanded/large: постоянная третья колонка 320/340, `elevation.1`, граница слева.
  panel,

  /// medium и шире (редакция 1.10, ADR-112): drawer 420 справа на всю высоту окна (`DsBreakpoints.cartDrawer`),
  /// `elevation.3`, без радиуса, крестик закрытия; заголовок «Корзина · N поз.» ([CartPanel.titleSuffix]), низ
  /// (итоги и кнопки) — подвал [CartPanel.footerColor] с верхней границей. До редакции 1.10 — side sheet 320 на medium.
  overlay,

  /// compact: полноэкранный маршрут `/cart`.
  screen,
}

/// Корзина `CartPanel` (03 §9.27; 02 SCR-20.2): шапка 56 (заголовок `title 18/600` + бейдж `primary` числа позиций,
/// действия справа, на `overlay` — крестик) и строка счётчиков [counter] → [banner] → [top] (клиент и склад) →
/// [body] (список строк, прокрутка внутри) → закреплённые снизу [bottom] (скидка, итоги) и [footer] (подпись
/// причины, «Отложить заказ», «Создать заказ →») над `SafeArea`. Фон `surface`, разделители `border`.
///
/// `overlay` — drawer корзины (прототип 2026-10-29): шапка с полями 16 / 20 и нижней границей, заголовок
/// `h3 20/700` и приглушённый [titleSuffix] «· N поз.» (`bodyLg 600 textTertiary`; бейдж при суффиксе скрыт),
/// закреплённый низ — один подвал [footerColor] с верхней границей `border` и полями зоны G 20; высоту низа панель
/// сообщает ближайшей [AppSnackbarRegion] — снекбар узкого окна стоит над ним, а не на кнопках.
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
    this.titleSuffix,
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

  /// Приглушённый суффикс заголовка («· 5 поз.», drawer); при нём бейдж числа позиций не показывается.
  final String? titleSuffix;

  /// Ключ крестика закрытия (drawer корзины; тесты).
  static const Key closeKey = ValueKey<String>('cart-drawer-close');

  /// Ключ подвала drawer (итоги и кнопки; тесты).
  static const Key footerKey = ValueKey<String>('cart-drawer-footer');

  /// Фон подвала drawer: `surface`, смешанный пополам с `surfaceHover` (≈ #FBFCFE прототипа).
  static Color footerColor(DsColors c) => Color.lerp(c.surface, c.surfaceHover, .5)!;

  /// Ширина панели для ширины окна [windowWidth] (02 SCR-20.2: 320 — medium и expanded < 1280, 340 — шире).
  static double widthFor(double windowWidth) => windowWidth >= 1280 ? DsBreakpoints.cartWide : DsBreakpoints.cartNarrow;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool drawer = variant == CartPanelVariant.overlay;
    final String? suffix = titleSuffix;
    final TextStyle titleStyle = drawer
        ? context.text.h3.copyWith(fontWeight: FontWeight.w700, color: c.textPrimary)
        : context.text.title.copyWith(fontWeight: FontWeight.w600, color: c.textPrimary);
    final Widget titleText = suffix == null
        ? Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: titleStyle)
        : Text.rich(
            TextSpan(
              children: <InlineSpan>[
                TextSpan(text: title),
                TextSpan(
                  text: ' $suffix',
                  style: context.text.bodyLg.copyWith(fontWeight: FontWeight.w600, color: c.textTertiary),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: titleStyle,
          );
    final Widget header = Container(
      padding: EdgeInsetsDirectional.only(
        start: context.space.s5,
        end: drawer ? context.space.s3 : context.space.s2,
        top: drawer ? context.space.s4 : context.space.s2,
        bottom: drawer ? context.space.s3 : context.space.s1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            height: 48,
            child: Row(
              children: <Widget>[
                // Заголовок занимает всё свободное место до действий (суффикс «· N поз.» не обрезается), бейдж —
                // сразу за заголовком.
                Expanded(
                  child: Row(
                    children: <Widget>[
                      Flexible(child: Semantics(header: true, child: titleText)),
                      if (count > 0 && suffix == null) ...<Widget>[
                        SizedBox(width: context.space.s2),
                        AppBadge(count: count, tone: AppBadgeTone.cart, semanticLabel: countLabel),
                      ],
                    ],
                  ),
                ),
                ...actions,
                if (onClose != null)
                  AppIconButton(
                    key: closeKey,
                    icon: Icons.close_rounded,
                    semanticLabel: closeLabel ?? '',
                    onPressed: onClose,
                  ),
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
    final ValueNotifier<double>? reportBottom = drawer ? AppSnackbarRegion.maybeOf(context)?.bottomInset : null;
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
                    final Widget? footerBox = footer == null
                        ? null
                        : SafeArea(
                            top: false,
                            child: Padding(
                              padding: drawer
                                  ? EdgeInsets.fromLTRB(
                                      context.space.s5,
                                      context.space.s1,
                                      context.space.s5,
                                      context.space.s5,
                                    )
                                  : EdgeInsets.fromLTRB(
                                      context.space.s5,
                                      context.space.s2,
                                      context.space.s5,
                                      context.space.s4,
                                    ),
                              child: footer,
                            ),
                          );
                    // Drawer (прототип): итоги и кнопки — один подвал [footerColor] с верхней границей `border`.
                    final List<Widget> pinned = drawer
                        ? <Widget>[
                            if (bottom != null || footerBox != null)
                              DecoratedBox(
                                key: footerKey,
                                decoration: BoxDecoration(
                                  color: footerColor(c),
                                  border: Border(top: BorderSide(color: c.border)),
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: <Widget>[?bottom, ?footerBox],
                                ),
                              ),
                          ]
                        : <Widget>[
                            if (bottom != null) ...<Widget>[Divider(height: 1, thickness: 1, color: c.border), bottom!],
                            ?footerBox,
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
                    final Widget pinnedColumn = Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: pinned,
                    );
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Expanded(child: body),
                        if (pinned.isNotEmpty)
                          reportBottom == null
                              ? pinnedColumn
                              : _HeightReporter(notifier: reportBottom, child: pinnedColumn),
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
      CartPanelVariant.overlay => BoxDecoration(color: c.surface, boxShadow: context.elevation.e3),
      CartPanelVariant.screen => BoxDecoration(color: c.surface),
    };
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: semanticLabel,
      child: DecoratedBox(
        decoration: decoration,
        child: ClipRect(child: content),
      ),
    );
  }
}

/// Сообщает высоту закреплённого низа drawer в [AppSnackbarRegion.bottomInset] (после кадра, без перестройки).
class _HeightReporter extends SingleChildRenderObjectWidget {
  const _HeightReporter({required this.notifier, required super.child});

  final ValueNotifier<double> notifier;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderHeightReporter(notifier);

  @override
  void updateRenderObject(BuildContext context, _RenderHeightReporter renderObject) {
    renderObject.notifier = notifier;
  }
}

class _RenderHeightReporter extends RenderProxyBox {
  _RenderHeightReporter(this.notifier);

  ValueNotifier<double> notifier;

  @override
  void performLayout() {
    super.performLayout();
    final double height = size.height;
    if (notifier.value != height) {
      final ValueNotifier<double> target = notifier;
      SchedulerBinding.instance.addPostFrameCallback((_) => target.value = height);
    }
  }
}
