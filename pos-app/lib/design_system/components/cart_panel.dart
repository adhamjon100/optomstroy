import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:optomstroy/design_system/components/app_badge.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/ds_glyph.dart';
import 'package:optomstroy/design_system/components/ds_hairline.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Вариант `CartPanel` (03 §9.27).
enum CartPanelVariant {
  /// expanded/large: постоянная третья колонка 320/340, `elevation.1`, граница слева.
  panel,

  /// medium и шире (редакция 1.10, ADR-112; вид — прототип без округления, ADR-114 п. 6): drawer 420 справа на всю
  /// высоту окна (`DsBreakpoints.cartDrawer`), тень `elevation.drawer` (−12 0 40 rgba(14,20,86,.18)), без радиуса,
  /// крестик закрытия 40; заголовок «Корзина · N поз.» ([CartPanel.titleSuffix]), низ (итоги и кнопки) — подвал
  /// `drawerFooterBg` #FBFCFE с верхней границей. До редакции 1.10 — side sheet 320 на medium.
  overlay,

  /// compact: полноэкранный маршрут `/cart`.
  screen,
}

/// Корзина `CartPanel` (03 §9.27; 02 SCR-20.2): шапка 56 (заголовок `title 18/600` + бейдж `primary` числа позиций,
/// действия справа, на `overlay` — крестик) и строка счётчиков [counter] → [banner] → [top] (клиент и склад) →
/// [body] (список строк, прокрутка внутри) → закреплённые снизу [bottom] (скидка, итоги) и [footer] (подпись
/// причины, «Отложить заказ», «Создать заказ →») над `SafeArea`. Фон `surface`, разделители `border`.
///
/// `overlay` — drawer корзины по прототипу (ADR-114 п. 6, design-spec §13): шапка 77 (поля 18 / 20, нижняя граница
/// `border`), заголовок `drawerTitle` 20/800 и приглушённый [titleSuffix] «· N поз.» 16/600 `catalogMeta` #6B7487
/// (бейдж при суффиксе скрыт), крестик — квадрат 40 с радиусом `control` 10 и крестом 20 линией 2,2 (цель 48);
/// действия [actions] и строка счётчиков — паритет функций (SCR-20 A, 02 П.4); закреплённый низ — один подвал
/// `drawerFooterBg` с верхней границей `border` и полями 16 / 20 / 20; высоту низа панель сообщает ближайшей
/// [AppSnackbarRegion] — снекбар узкого окна стоит над ним, а не на кнопках.
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

  /// Поля зоны G (кнопки) в подвале drawer: прототип — зазор 12 над кнопками и нижнее поле 20; кнопки `drawer`
  /// видимой высоты 46 стоят в цели 48 (по 1 сверху и снизу), поэтому 11 и 19.
  static const EdgeInsets drawerFooterPadding = EdgeInsets.fromLTRB(20, 11, 20, 19);

  /// Поля списка строк drawer (прототип: `padding: 6px 20px`; 6 — вне шкалы отступов, значение прототипа без
  /// округления, ADR-114 п. 6). Поля 20 по бокам у строк — у самих строк (`CartLine.emphasized`).
  static const EdgeInsets drawerBodyPadding = EdgeInsets.symmetric(horizontal: 20, vertical: 6);

  /// Высота строки «Клиент» drawer с нижней границей (прототип: 14 + 18 + 14 и граница 1).
  static const double drawerClientRowHeight = 47;

  /// Зазор в строке «Клиент» drawer (прототип: `gap: 10px`).
  static const double drawerClientGap = 10;

  /// Зазор кнопок зоны G drawer (прототип: `gap: 10px`).
  static const double drawerButtonGap = 10;

  /// Ширина левой кнопки зоны G drawer («Отложить · F8») в строке шириной [row]: как CSS `flex: 1` против `flex: 1.4`
  /// с основой 0 — свободное место делится 1 : 1,4 после собственных полей кнопок (у «Отложить» — 6 + рамка 1 с
  /// каждой стороны, у «Создать заказ» — 6 + 6); при ширине 380 — 157,3 и 212,7.
  static double drawerParkWidth(double row) {
    const double parkOwn = 14;
    const double createOwn = 12;
    final double free = row - drawerButtonGap - parkOwn - createOwn;
    return free <= 0 ? 0 : free / 2.4 + parkOwn;
  }

  /// Ширина панели для ширины окна [windowWidth] (02 SCR-20.2: 320 — medium и expanded < 1280, 340 — шире).
  static double widthFor(double windowWidth) => windowWidth >= 1280 ? DsBreakpoints.cartWide : DsBreakpoints.cartNarrow;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool drawer = variant == CartPanelVariant.overlay;
    final String? suffix = titleSuffix;
    final TextStyle titleStyle = drawer
        ? context.text.drawerTitle.copyWith(color: c.textPrimary)
        : context.text.title.copyWith(fontWeight: FontWeight.w600, color: c.textPrimary);
    final Widget titleText = suffix == null
        ? Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: titleStyle)
        : Text.rich(
            TextSpan(
              children: <InlineSpan>[
                TextSpan(text: title),
                TextSpan(
                  text: ' $suffix',
                  // 16/600 #6B7487 на `surface` — 4,69:1 (CP-093).
                  style: context.text.bodyLg.copyWith(fontWeight: FontWeight.w600, color: c.catalogMeta),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: titleStyle,
          );
    final bool counterRow = counter != null || counterTrailing != null;
    // Drawer (прототип): шапка 77 = 18 + крестик 40 + 18 и граница; строка 48 (цели касания) — поля 14. Крестик 40
    // стоит в цели 48, поэтому правое поле 16 (видимый край — в 20 от края, как в прототипе). Строка счётчиков
    // (паритет функций) — под заголовком, нижнее поле тогда 8.
    final Widget header = Container(
      padding: EdgeInsetsDirectional.only(
        start: context.space.s5,
        end: drawer ? context.space.s4 : context.space.s2,
        top: drawer ? 14 : context.space.s2,
        bottom: drawer ? (counterRow ? context.space.s2 : 14) : context.space.s1,
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
                  drawer
                      ? _DrawerCloseButton(label: closeLabel ?? '', onPressed: onClose)
                      : AppIconButton(
                          key: closeKey,
                          icon: Icons.close_rounded,
                          semanticLabel: closeLabel ?? '',
                          onPressed: onClose,
                        ),
              ],
            ),
          ),
          if (counterRow)
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
                                  ? drawerFooterPadding
                                  : EdgeInsets.fromLTRB(
                                      context.space.s5,
                                      context.space.s2,
                                      context.space.s5,
                                      context.space.s4,
                                    ),
                              child: footer,
                            ),
                          );
                    // Drawer (прототип): итоги и кнопки — один подвал `drawerFooterBg` с верхней границей `border`.
                    final List<Widget> pinned = drawer
                        ? <Widget>[
                            if (bottom != null || footerBox != null)
                              DecoratedBox(
                                key: footerKey,
                                decoration: BoxDecoration(
                                  color: c.drawerFooterBg,
                                  border: Border(top: DsHairline.side(context, c.border)),
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
      CartPanelVariant.overlay => BoxDecoration(color: c.surface, boxShadow: context.elevation.drawer),
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

/// Крестик закрытия drawer корзины (прототип): квадрат 40 с радиусом `control` 10, прозрачный (наведение —
/// `surfaceHover`, нажатие — `iconButtonPressed`), крест 20 `textPrimary` линией 2,2; цель касания 48, фокус — кольцо
/// `focus`, тултип — подпись ([CartPanel.closeKey]).
class _DrawerCloseButton extends StatelessWidget {
  const _DrawerCloseButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  /// Сторона видимого квадрата.
  static const double size = 40;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final BorderRadius radius = BorderRadius.all(context.radii.control);
    final Widget button = Semantics(
      button: true,
      enabled: onPressed != null,
      label: label,
      excludeSemantics: true,
      onTap: onPressed,
      child: DsInteractive(
        key: CartPanel.closeKey,
        enabled: onPressed != null,
        onTap: onPressed,
        builder: (BuildContext context, DsInteractionState s) => DsTapTarget(
          child: DsFocusRing(
            visible: s.focused,
            borderRadius: radius,
            child: Container(
              width: size,
              height: size,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: s.pressed ? c.iconButtonPressed : (s.hovered ? c.surfaceHover : Colors.transparent),
                borderRadius: radius,
              ),
              child: DsGlyph(kind: DsGlyphKind.cross, size: 20, color: s.enabled ? c.textPrimary : c.disabledText),
            ),
          ),
        ),
      ),
    );
    return label.isEmpty ? button : AppTooltip(message: label, child: button);
  }
}
