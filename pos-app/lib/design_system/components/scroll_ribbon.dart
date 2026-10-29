import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Горизонтальная лента карточек одинакового размера `ScrollRibbon` (лента подкатегорий SCR-10/12, прототип
/// 2026-10-29, 03 §9.25): прокрутка жестом (сенсор, тачпад, перетаскивание мышью) и колесом мыши (вертикальное
/// колесо прокручивает ленту, пока ей есть куда; на краю — событие уходит странице), стрелки ‹ › у краёв
/// прокручивают на ширину видимой части и скрываются на краях; выбранная карточка ([selectedIndex]) при показе
/// прокручивается в видимую часть. Фокус клавиатуры по карточкам прокручивает ленту сам (`Scrollable.ensureVisible`).
///
/// Видимая часть — область между полями [padding] — обрезана со скруглением `md` (карточки уходят под край, а не
/// под поля страницы); стрелки — круг 38 `surface` с обводкой `border` и тенью `elevation.2`, шеврон 18 `focus`
/// (синий, не оранжевый: стрелка — навигация, не статус), цель 48; круг вынесен на 12 за край видимой части.
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
    this.gap = 12,
    this.padding = EdgeInsets.zero,
  });

  /// Число карточек.
  final int itemCount;

  /// Карточка по индексу (размер — [itemSize]).
  final IndexedWidgetBuilder itemBuilder;

  /// Размер каждой карточки.
  final Size itemSize;

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

  /// Поля ленты по горизонтали (как у контента).
  final EdgeInsets padding;

  /// Ключи стрелок (тесты).
  static const Key previousKey = ValueKey<String>('ribbon-prev');
  static const Key nextKey = ValueKey<String>('ribbon-next');

  /// Диаметр круга стрелки.
  static const double arrowSize = 38;

  /// Насколько круг стрелки вынесен за край видимой части.
  static const double arrowOutset = 12;

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

  double get _stride => widget.itemSize.width + widget.gap;

  void _revealSelected() {
    final int? i = widget.selectedIndex;
    if (i != null && _scroll.hasClients) {
      final ScrollPosition p = _scroll.position;
      final double start = widget.padding.left + i * _stride;
      final double end = start + widget.itemSize.width;
      double target = p.pixels;
      if (start < p.pixels + widget.padding.left) {
        target = start - widget.padding.left;
      } else if (end > p.pixels + p.viewportDimension - widget.padding.right) {
        target = end - p.viewportDimension + widget.padding.right;
      }
      target = target.clamp(p.minScrollExtent, p.maxScrollExtent);
      if (target != p.pixels) {
        _scroll.jumpTo(target);
      }
    }
    _syncArrows();
  }

  /// Стрелка: на ширину видимой части (без полей), с выравниванием по началу карточки.
  void _page(int direction) {
    if (!_scroll.hasClients) {
      return;
    }
    final ScrollPosition p = _scroll.position;
    final double visible = math.max(_stride, p.viewportDimension - widget.padding.horizontal);
    final double raw = p.pixels + direction * visible;
    final double snapped = (raw / _stride).round() * _stride;
    final double target = snapped.clamp(p.minScrollExtent, p.maxScrollExtent);
    final Duration d = context.motion.of(context.motion.base);
    if (d == Duration.zero) {
      _scroll.jumpTo(target);
    } else {
      unawaited(_scroll.animateTo(target, duration: d, curve: context.motion.standard));
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
    // Поле для кольца фокуса карточек (2 + 2 lp) сверху и снизу.
    const double ring = 4;
    // Стрелка: круг 38 в цели 48 — от края видимой части наружу на [ScrollRibbon.arrowOutset].
    const double targetInset = (48 - ScrollRibbon.arrowSize) / 2;
    return SizedBox(
      height: widget.itemSize.height + ring * 2,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
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
                      padding: widget.padding.copyWith(top: ring, bottom: ring),
                      itemCount: widget.itemCount,
                      separatorBuilder: (BuildContext context, int i) => SizedBox(width: widget.gap),
                      itemBuilder: (BuildContext context, int i) => SizedBox(
                        width: widget.itemSize.width,
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
              start: math.max(0, widget.padding.left - ScrollRibbon.arrowOutset - targetInset),
              top: 0,
              bottom: 0,
              child: Center(
                child: _Arrow(
                  key: ScrollRibbon.previousKey,
                  icon: Icons.chevron_left_rounded,
                  label: widget.previousLabel,
                  onTap: () => _page(-1),
                ),
              ),
            ),
          if (_canForward)
            PositionedDirectional(
              end: math.max(0, widget.padding.right - ScrollRibbon.arrowOutset - targetInset),
              top: 0,
              bottom: 0,
              child: Center(
                child: _Arrow(
                  key: ScrollRibbon.nextKey,
                  icon: Icons.chevron_right_rounded,
                  label: widget.nextLabel,
                  onTap: () => _page(1),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Видимая часть ленты: между полями [padding] по горизонтали, по вертикали — вся высота (кольцо фокуса карточек),
/// скругление [radius]. Карточки за краем не видны и не принимают нажатия.
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

/// Круглая стрелка 38 (цель 48): `surface`, обводка `border`, `elevation.2`, шеврон 18 `focus`; hover/pressed/фокус.
class _Arrow extends StatelessWidget {
  const _Arrow({super.key, required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
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
            dimension: 48,
            child: Center(
              child: Container(
                width: ScrollRibbon.arrowSize,
                height: ScrollRibbon.arrowSize,
                decoration: BoxDecoration(
                  color: s.pressed ? c.surfacePressed : (s.hovered ? c.surfaceHover : c.surface),
                  shape: BoxShape.circle,
                  border: Border.all(color: c.border),
                  boxShadow: context.elevation.e2,
                ),
                // Шеврон — `textSecondary` (≥ 3:1 на `surface`): синий `focus` — только индикатор фокуса и info
                // (ядро §24.1), а стрелки фокус не получают.
                child: Icon(icon, size: 18, color: c.textSecondary),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
