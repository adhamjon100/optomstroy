import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/ds_glyph.dart';
import 'package:optomstroy/design_system/components/ds_hairline.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Горизонтальная лента карточек `ScrollRibbon` (лента подкатегорий SCR-10/12, прототип, 03 §9.25, ADR-114).
///
/// Геометрия прототипа: видимая часть («полоса», область между полями [padding]) обрезана со скруглением `md`, внутри —
/// поле [innerPadding] 2 и зазор [gap] 10; высота ленты — высота карточки + 2 × 2 (152). Ширина карточки — по индексу
/// ([itemWidthOf]; карточка с длинным словом шире 118), иначе [itemSize].
///
/// Стрелки ‹ › — круг 38 `surface` с обводкой `border` 1 и тенью `elevation.ribbonArrow`, шеврон 18 `link` (линия 2,4)
/// в цели 48; левая выступает за край полосы на 12, правая — на 10, по вертикали — по центру. Цель 48 всегда внутри
/// ленты (за её краем нажатия не доходят): при поле слева меньше [ScrollRibbon.arrowTargetReach] (17) цель прижата к
/// краю ленты и сдвинута относительно круга, круг остаётся на месте прототипа (ревью RC-10). Нажатие листает на
/// [stepItems] карточки (3 × 128 = 384 у карточек 118) за 220 мс (`ease`), с выравниванием по началу карточки.
/// Стрелки видны только при настоящем переполнении (ADR-114: правило прототипа `n − 6` показало бы стрелку при 1920,
/// когда всё видно).
///
/// Сохранено (паритет функций): прокрутка жестом (сенсор, тачпад, перетаскивание мышью) и колесом мыши (вертикальное
/// колесо прокручивает ленту, пока ей есть куда; на краю — событие уходит странице); выбранная карточка
/// ([selectedIndex]) при показе прокручивается в видимую часть; фокус клавиатуры по карточкам прокручивает ленту сам
/// (`Scrollable.ensureVisible`); подписи стрелок [previousLabel] / [nextLabel].
class ScrollRibbon extends StatefulWidget {
  /// Создаёт ленту.
  const ScrollRibbon({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    required this.itemSize,
    required this.previousLabel,
    required this.nextLabel,
    this.selectedIndex,
    this.setId,
    this.gap = DsCatalogMetrics.ribbonGap,
    this.padding = EdgeInsets.zero,
    this.itemWidthOf,
    this.innerPadding = DsCatalogMetrics.ribbonPad,
    this.stepItems = DsCatalogMetrics.ribbonArrowStepCards,
  });

  /// Число карточек.
  final int itemCount;

  /// Карточка по индексу (размер — [itemWidthOf] × высота [itemSize]).
  final IndexedWidgetBuilder itemBuilder;

  /// Высота карточек и ширина по умолчанию.
  final Size itemSize;

  /// Ширина карточки по индексу; `null` — `itemSize.width` у всех.
  final double Function(int index)? itemWidthOf;

  /// Подписи стрелок для screen reader и тултипа.
  final String previousLabel;
  final String nextLabel;

  /// Выбранная карточка — прокручивается в видимую часть.
  final int? selectedIndex;

  /// Идентификатор набора карточек (например, родитель ленты подкатегорий): при смене набора лента начинается с
  /// начала, затем выбранная карточка — в видимую часть (прокрутка прежнего набора не переносится, даже если число
  /// карточек и выбранный индекс совпали).
  final Object? setId;

  /// Зазор между карточками.
  final double gap;

  /// Поля ленты по горизонтали (как у контента): полоса — между ними.
  final EdgeInsets padding;

  /// Поле внутри полосы со всех сторон (прототип: `padding: 2px`).
  final double innerPadding;

  /// На сколько карточек листает стрелка.
  final int stepItems;

  /// Ключи стрелок (тесты).
  static const Key previousKey = ValueKey<String>('ribbon-prev');
  static const Key nextKey = ValueKey<String>('ribbon-next');

  /// Диаметр круга стрелки.
  static const double arrowSize = 38;

  /// Насколько круг левой стрелки выступает за край полосы (прототип: `left: -12px`).
  static const double arrowOutset = 12;

  /// Насколько круг правой стрелки выступает за край полосы (прототип: `right: -10px`).
  static const double arrowOutsetEnd = 10;

  /// Сторона цели касания стрелки.
  static const double arrowTarget = 48;

  /// Поле [padding] слева, начиная с которого цель 48 левой стрелки стоит по центру круга (12 выступа + 5); при меньшем
  /// поле цель прижата к краю ленты. Круг целиком виден, если поле не меньше [arrowOutset] и родитель не обрезает
  /// ленту.
  static const double arrowTargetReach = arrowOutset + (arrowTarget - arrowSize) / 2;

  /// Длительность листания стрелкой (прототип: `transition: transform 220ms ease`).
  static const Duration pageDuration = Duration(milliseconds: 220);

  @override
  State<ScrollRibbon> createState() => _ScrollRibbonState();
}

class _ScrollRibbonState extends State<ScrollRibbon> {
  final ScrollController _scroll = ScrollController();
  bool _canBack = false;
  bool _canForward = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_syncArrows);
    _afterLayout(_revealSelected);
  }

  @override
  void didUpdateWidget(ScrollRibbon old) {
    super.didUpdateWidget(old);
    if (old.setId != widget.setId) {
      _afterLayout(() {
        if (_scroll.hasClients && _scroll.offset != 0) {
          _scroll.jumpTo(0);
        }
        _revealSelected();
      });
    } else if (old.selectedIndex != widget.selectedIndex || old.itemCount != widget.itemCount) {
      _afterLayout(_revealSelected);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _afterLayout(VoidCallback fn) => WidgetsBinding.instance.addPostFrameCallback((Duration _) {
    if (mounted) {
      fn();
    }
  });

  void _syncArrows() {
    if (!_scroll.hasClients) {
      return;
    }
    final ScrollPosition p = _scroll.position;
    final bool back = p.pixels > p.minScrollExtent + 0.5;
    final bool forward = p.pixels < p.maxScrollExtent - 0.5;
    if (back != _canBack || forward != _canForward) {
      setState(() {
        _canBack = back;
        _canForward = forward;
      });
    }
  }

  double _widthOf(int i) => widget.itemWidthOf?.call(i) ?? widget.itemSize.width;

  /// Смещение прокрутки, при котором карточка [i] стоит у левого края полосы (с полем [ScrollRibbon.innerPadding]).
  double _offsetOf(int i) {
    double x = 0;
    for (int j = 0; j < i; j++) {
      x += _widthOf(j) + widget.gap;
    }
    return x;
  }

  void _revealSelected() {
    final int? i = widget.selectedIndex;
    if (i != null && i >= 0 && i < widget.itemCount && _scroll.hasClients) {
      final ScrollPosition p = _scroll.position;
      final double lead = widget.padding.left + widget.innerPadding;
      final double start = lead + _offsetOf(i);
      final double end = start + _widthOf(i);
      final double viewStart = p.pixels + widget.padding.left + widget.innerPadding;
      final double viewEnd = p.pixels + p.viewportDimension - widget.padding.right - widget.innerPadding;
      double target = p.pixels;
      if (start < viewStart) {
        target = start - lead;
      } else if (end > viewEnd) {
        target = end - p.viewportDimension + widget.padding.right + widget.innerPadding;
      }
      target = target.clamp(p.minScrollExtent, p.maxScrollExtent);
      if (target != p.pixels) {
        _scroll.jumpTo(target);
      }
    }
    _syncArrows();
  }

  /// Стрелка: на [ScrollRibbon.stepItems] карточки от той, что сейчас у левого края, с выравниванием по её началу.
  void _page(int direction) {
    if (!_scroll.hasClients || widget.itemCount == 0) {
      return;
    }
    final ScrollPosition p = _scroll.position;
    int current = 0;
    for (int i = 1; i < widget.itemCount; i++) {
      if (_offsetOf(i) <= p.pixels + 0.5) {
        current = i;
      } else {
        break;
      }
    }
    final int next = (current + direction * widget.stepItems).clamp(0, widget.itemCount - 1);
    final double target = _offsetOf(next).clamp(p.minScrollExtent, p.maxScrollExtent);
    final Duration d = context.motion.of(ScrollRibbon.pageDuration);
    if (d == Duration.zero) {
      _scroll.jumpTo(target);
    } else {
      unawaited(_scroll.animateTo(target, duration: d, curve: Curves.ease));
    }
  }

  /// Вертикальное колесо мыши прокручивает ленту, пока ей есть куда (горизонтальный Scrollable сам берёт только dx).
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_scroll.hasClients) {
      return;
    }
    final double delta = event.scrollDelta.dy.abs() > event.scrollDelta.dx.abs()
        ? event.scrollDelta.dy
        : event.scrollDelta.dx;
    final ScrollPosition p = _scroll.position;
    final double target = (p.pixels + delta).clamp(p.minScrollExtent, p.maxScrollExtent);
    if (delta == 0 || target == p.pixels) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (PointerSignalEvent e) {
      if (_scroll.hasClients) {
        final ScrollPosition pos = _scroll.position;
        pos.jumpTo((pos.pixels + delta).clamp(pos.minScrollExtent, pos.maxScrollExtent));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final double pad = widget.innerPadding;
    // Кольцо фокуса карточек (DsFocusRing.outset 4) выходит за поле 2 полосы: список выше полосы на разницу сверху и
    // снизу, чтобы кольцо не обрезалось (по горизонтали полоса обрезает, как в прототипе).
    final double ring = math.max(0, DsFocusRing.outset - pad);
    // Стрелка: круг 38 в цели 48. Цель — внутри ленты: за её краем нажатия не доходят (hit test идёт только в границах
    // родителя, `Clip.none` влияет лишь на отрисовку; ревью RC-10). Круг — на месте прототипа, цель при узком поле
    // прижата к краю и сдвинута относительно круга.
    const double targetInset = (ScrollRibbon.arrowTarget - ScrollRibbon.arrowSize) / 2;
    final double backCircle = widget.padding.left - ScrollRibbon.arrowOutset;
    final double backTarget = math.max(0, backCircle - targetInset);
    final double forwardCircle = widget.padding.right - ScrollRibbon.arrowOutsetEnd;
    final double forwardTarget = math.max(0, forwardCircle - targetInset);
    return SizedBox(
      height: widget.itemSize.height + pad * 2,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned(
            left: 0,
            right: 0,
            top: -ring,
            bottom: -ring,
            child: ClipRRect(
              clipper: _VisibleAreaClipper(padding: widget.padding, radius: BorderRadius.all(context.radii.md)),
              child: NotificationListener<ScrollMetricsNotification>(
                onNotification: (ScrollMetricsNotification n) {
                  _afterLayout(_syncArrows);
                  return false;
                },
                child: Listener(
                  onPointerSignal: _onPointerSignal,
                  child: ScrollConfiguration(
                    behavior: ScrollConfiguration.of(context).copyWith(
                      scrollbars: false,
                      dragDevices: <PointerDeviceKind>{
                        PointerDeviceKind.touch,
                        PointerDeviceKind.mouse,
                        PointerDeviceKind.trackpad,
                        PointerDeviceKind.stylus,
                        PointerDeviceKind.invertedStylus,
                      },
                    ),
                    child: ListView.separated(
                      key: const ValueKey<String>('scroll-ribbon-list'),
                      controller: _scroll,
                      scrollDirection: Axis.horizontal,
                      padding: EdgeInsets.fromLTRB(
                        widget.padding.left + pad,
                        pad + ring,
                        widget.padding.right + pad,
                        pad + ring,
                      ),
                      itemCount: widget.itemCount,
                      separatorBuilder: (BuildContext context, int i) => SizedBox(width: widget.gap),
                      itemBuilder: (BuildContext context, int i) => SizedBox(
                        width: _widthOf(i),
                        height: widget.itemSize.height,
                        child: widget.itemBuilder(context, i),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_canBack)
            PositionedDirectional(
              start: backTarget,
              top: 0,
              bottom: 0,
              child: Center(
                child: _Arrow(
                  key: ScrollRibbon.previousKey,
                  glyph: DsGlyphKind.chevronLeft,
                  label: widget.previousLabel,
                  circleStart: backCircle - backTarget,
                  onTap: () => _page(-1),
                ),
              ),
            ),
          if (_canForward)
            PositionedDirectional(
              end: forwardTarget,
              top: 0,
              bottom: 0,
              child: Center(
                child: _Arrow(
                  key: ScrollRibbon.nextKey,
                  glyph: DsGlyphKind.chevronRight,
                  label: widget.nextLabel,
                  circleStart: ScrollRibbon.arrowTarget - ScrollRibbon.arrowSize - (forwardCircle - forwardTarget),
                  onTap: () => _page(1),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Видимая часть ленты: между полями [padding] по горизонтали, по вертикали — вся высота (поле и кольцо фокуса
/// карточек), скругление [radius]. Карточки за краем не видны и не принимают нажатия.
class _VisibleAreaClipper extends CustomClipper<RRect> {
  const _VisibleAreaClipper({required this.padding, required this.radius});

  final EdgeInsets padding;
  final BorderRadius radius;

  @override
  RRect getClip(Size size) {
    final double left = math.min(padding.left, size.width);
    final double right = math.max(left, size.width - padding.right);
    return radius.toRRect(Rect.fromLTRB(left, 0, right, size.height));
  }

  @override
  bool shouldReclip(_VisibleAreaClipper oldClipper) => oldClipper.padding != padding || oldClipper.radius != radius;
}

/// Круглая стрелка 38 (цель 48): `surface`, обводка `border` 1, `elevation.ribbonArrow`, шеврон 18 `link` (линия 2,4);
/// hover — `surfaceHover`, нажатие — `surfacePressed`. Круг — на [circleStart] от начала цели (5 — по центру; при цели,
/// прижатой к краю ленты, — меньше, круг может выступать за цель).
class _Arrow extends StatelessWidget {
  const _Arrow({super.key, required this.glyph, required this.label, required this.circleStart, required this.onTap});

  final DsGlyphKind glyph;
  final String label;
  final double circleStart;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      // Действие «нажать» для TalkBack/Narrator: жест DsInteractive из семантики исключён.
      onTap: onTap,
      child: AppTooltip(
        message: label,
        child: DsInteractive(
          onTap: onTap,
          // Стрелки дублируют прокрутку: клавиатура ходит по карточкам, а не по стрелкам.
          canRequestFocus: false,
          builder: (BuildContext context, DsInteractionState s) => SizedBox.square(
            dimension: ScrollRibbon.arrowTarget,
            child: Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                PositionedDirectional(
                  start: circleStart,
                  top: (ScrollRibbon.arrowTarget - ScrollRibbon.arrowSize) / 2,
                  child: Container(
                    width: ScrollRibbon.arrowSize,
                    height: ScrollRibbon.arrowSize,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: s.pressed ? c.surfacePressed : (s.hovered ? c.surfaceHover : c.surface),
                      shape: BoxShape.circle,
                      border: DsHairline.all(context, c.border),
                      boxShadow: context.elevation.ribbonArrow,
                    ),
                    // Шеврон — `link` #1F5FA8 прототипа (ADR-114, исключение DS-098: стрелка — навигация, не статус).
                    child: DsGlyph(kind: glyph, size: 18, color: c.link),
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
