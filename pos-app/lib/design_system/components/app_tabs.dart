import 'dart:async';
import 'dart:ui' show SemanticsRole;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Вариант `AppTabs` (03 §9.49).
enum AppTabsVariant {
  /// 2–4 вкладки равной ширины; подчёркивание `primaryText` 2 px скользит к активной (ANIM-017).
  fixed,

  /// > 4 вкладок: горизонтальная прокрутка, мин. ширина вкладки 96, активная подводится в видимую область.
  scrollable,

  /// Сегментный трек `surfaceVariant`, выбранный сегмент `surface` + `elevation.1` — фильтры-сегменты экранов
  /// («Мои / Все» SCR-23/SCR-25 в строке фильтров, «Все · Непрочитанные» SCR-44) и диалоги.
  segmented,
}

/// Вкладка `AppTabs`.
@immutable
class AppTab<T> {
  /// Создаёт вкладку.
  const AppTab({
    required this.value,
    required this.label,
    this.count,
    this.icon,
    this.enabled = true,
    this.disabledReason,
    this.key,
  });

  /// Значение вкладки.
  final T value;

  /// Подпись.
  final String label;

  /// Счётчик в пилюле `surfaceVariant` (`label tnum`): «Заказы 12».
  final int? count;

  /// Иконка 20 слева от подписи.
  final IconData? icon;

  /// Доступна (нет данных или права — `disabledText` и тултип [disabledReason]).
  final bool enabled;

  /// Причина недоступности (тултип и подсказка диктора).
  final String? disabledReason;

  /// Ключ области вкладки (тесты).
  final Key? key;
}

/// Вкладки внутри экрана `AppTabs` (03 §9.49): полоса высотой 48 (фон `surface`, нижняя граница `border` 1 px);
/// подпись `body 14/500 textSecondary`, активная — `textPrimary 600` + индикатор `primaryText` 2 px (не только цвет —
/// A11Y-004). Тап, ←/→, Home/End — переключение (повторный выбор активной не сообщается). Тач-цель — высота 48.
/// Доступность: группа `tabBar`, вкладка `tab` с `selected` и подписью «Заказы, 12».
class AppTabs<T> extends StatelessWidget {
  /// Создаёт вкладки.
  const AppTabs({
    super.key,
    required this.tabs,
    required this.value,
    required this.onChanged,
    this.variant = AppTabsVariant.fixed,
    this.enabled = true,
  });

  /// Вкладки.
  final List<AppTab<T>> tabs;

  /// Активная вкладка.
  final T value;

  /// Выбор другой вкладки.
  final ValueChanged<T> onChanged;

  /// Вариант.
  final AppTabsVariant variant;

  /// Доступна ли вся полоса (например, без сети) — вкладки `disabled`, активная остаётся отмеченной.
  final bool enabled;

  /// Высота полосы и тач-цели вкладки.
  static const double height = 48;

  /// Мин. ширина вкладки `scrollable`.
  static const double scrollableMinWidth = 96;

  /// Толщина индикатора.
  static const double indicator = 2;

  bool _enabled(AppTab<T> t) => enabled && t.enabled;

  int get _index => tabs.indexWhere((AppTab<T> t) => t.value == value);

  void _select(AppTab<T> t) {
    if (_enabled(t) && t.value != value) onChanged(t.value);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final List<AppTab<T>> available = <AppTab<T>>[
      for (final AppTab<T> t in tabs)
        if (_enabled(t)) t,
    ];
    if (available.isEmpty) return KeyEventResult.ignored;
    final int at = available.indexWhere((AppTab<T> t) => t.value == value);
    final LogicalKeyboardKey k = event.logicalKey;
    final BuildContext? ctx = node.context;
    final bool rtl = ctx != null && Directionality.maybeOf(ctx) == TextDirection.rtl;
    final LogicalKeyboardKey next = rtl ? LogicalKeyboardKey.arrowLeft : LogicalKeyboardKey.arrowRight;
    final LogicalKeyboardKey prev = rtl ? LogicalKeyboardKey.arrowRight : LogicalKeyboardKey.arrowLeft;
    AppTab<T>? target;
    if (k == next) {
      target = at < available.length - 1 ? available[at + 1] : null;
    } else if (k == prev) {
      target = at > 0 ? available[at - 1] : (at < 0 ? available.last : null);
    } else if (k == LogicalKeyboardKey.home) {
      target = available.first;
    } else if (k == LogicalKeyboardKey.end) {
      target = available.last;
    } else {
      return KeyEventResult.ignored;
    }
    if (target != null) _select(target);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    // Группа `tabBar` не может быть пустой (проверка ролей семантики Flutter).
    if (tabs.isEmpty) return const SizedBox(height: height);
    final List<Widget> items = <Widget>[
      for (final AppTab<T> t in tabs)
        _TabItem<T>(
          key: t.key,
          tab: t,
          variant: variant,
          selected: t.value == value,
          enabled: _enabled(t),
          onTap: () => _select(t),
        ),
    ];
    final Widget bar = switch (variant) {
      AppTabsVariant.fixed => _FixedBar(index: _index, count: tabs.length, children: items),
      AppTabsVariant.scrollable => _ScrollableBar(children: items),
      // Доля ширины сегмента при нехватке места — по длине подписи (короткое «Все» не забирает половину строки).
      AppTabsVariant.segmented => _SegmentedTrack(
        flexes: <int>[for (final AppTab<T> t in tabs) t.label.length + (t.count == null ? 0 : 4) + 4],
        children: items,
      ),
    };
    return Focus(canRequestFocus: false, skipTraversal: true, onKeyEvent: _onKey, child: bar);
  }
}

/// Группа `tabBar` вокруг строки вкладок (дочерние узлы — только вкладки).
Widget _tabBarSemantics(Widget row) =>
    Semantics(role: SemanticsRole.tabBar, container: true, explicitChildNodes: true, child: row);

class _FixedBar extends StatelessWidget {
  const _FixedBar({required this.index, required this.count, required this.children});

  final int index;
  final int count;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return _BarSurface(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final double w = box.maxWidth / count;
          final bool rtl = Directionality.of(context) == TextDirection.rtl;
          final int at = index < 0 ? 0 : index;
          return Stack(
            children: <Widget>[
              _tabBarSemantics(Row(children: <Widget>[for (final Widget child in children) Expanded(child: child)])),
              if (index >= 0)
                AnimatedPositioned(
                  key: const ValueKey<String>('app-tabs-indicator'),
                  duration: context.motion.of(context.motion.base),
                  curve: context.motion.standard,
                  left: rtl ? null : at * w,
                  right: rtl ? at * w : null,
                  bottom: 0,
                  width: w,
                  height: AppTabs.indicator,
                  child: IgnorePointer(child: ColoredBox(color: c.primaryText)),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ScrollableBar extends StatelessWidget {
  const _ScrollableBar({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => _BarSurface(
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: _tabBarSemantics(Row(children: children)),
    ),
  );
}

/// Полоса 48: фон `surface`, нижняя граница `border` 1 px под вкладками (граница не уменьшает тач-цель вкладки).
class _BarSurface extends StatelessWidget {
  const _BarSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return SizedBox(
      height: AppTabs.height,
      child: ColoredBox(
        color: c.surface,
        child: Stack(
          fit: StackFit.passthrough,
          children: <Widget>[
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 1,
              child: IgnorePointer(child: ColoredBox(color: c.border)),
            ),
            child,
          ],
        ),
      ),
    );
  }
}

class _SegmentedTrack extends StatelessWidget {
  const _SegmentedTrack({required this.children, required this.flexes});

  final List<Widget> children;
  final List<int> flexes;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Container(
      height: AppTabs.height,
      decoration: BoxDecoration(color: c.surfaceVariant, borderRadius: BorderRadius.all(context.radii.md)),
      child: _tabBarSemantics(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final (int i, Widget child) in children.indexed) Flexible(flex: flexes[i], child: child),
          ],
        ),
      ),
    );
  }
}

class _TabItem<T> extends StatefulWidget {
  const _TabItem({
    super.key,
    required this.tab,
    required this.variant,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final AppTab<T> tab;
  final AppTabsVariant variant;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<_TabItem<T>> createState() => _TabItemState<T>();
}

class _TabItemState<T> extends State<_TabItem<T>> {
  @override
  void initState() {
    super.initState();
    if (widget.selected && widget.variant == AppTabsVariant.scrollable) _ensureVisible(animate: false);
  }

  @override
  void didUpdateWidget(_TabItem<T> old) {
    super.didUpdateWidget(old);
    if (widget.selected && !old.selected && widget.variant == AppTabsVariant.scrollable) _ensureVisible(animate: true);
  }

  /// Активная вкладка `scrollable` подводится в видимую область (ANIM-017, 200 мс).
  void _ensureVisible({required bool animate}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        Scrollable.ensureVisible(
          context,
          alignment: 0.5,
          duration: animate ? context.motion.of(context.motion.base) : Duration.zero,
          curve: context.motion.standard,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final AppTab<T> t = widget.tab;
    final bool selected = widget.selected;
    final bool segmented = widget.variant == AppTabsVariant.segmented;
    final Color text = !widget.enabled && !selected ? c.disabledText : (selected ? c.textPrimary : c.textSecondary);
    final String semanticLabel = t.count == null ? t.label : '${t.label}, ${t.count}';
    final String? reason = widget.enabled ? null : t.disabledReason;

    Widget content(DsInteractionState s) {
      // Узкая вкладка (`fixed` на compact): иконка скрывается, подпись и счётчик сжимаются с многоточием —
      // переполнения нет.
      final Widget label = LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final bool narrow = box.maxWidth < AppTabs.scrollableMinWidth;
          return Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (t.icon != null && !narrow) ...<Widget>[
                Icon(t.icon, size: 20, color: selected ? c.primaryText : text),
                SizedBox(width: context.space.s2),
              ],
              Flexible(
                child: Text(
                  t.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.body.copyWith(
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: text,
                  ),
                ),
              ),
              if (t.count != null && box.maxWidth >= AppTabs.height) ...<Widget>[
                SizedBox(width: context.space.s1),
                Container(
                  padding: EdgeInsets.symmetric(horizontal: context.space.s2),
                  decoration: BoxDecoration(
                    color: segmented && !selected ? c.surface : c.surfaceVariant,
                    borderRadius: BorderRadius.all(context.radii.full),
                  ),
                  child: Text(
                    '${t.count}',
                    maxLines: 1,
                    style: context.text.label.copyWith(
                      color: text,
                      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      );
      final Color overlay = !s.enabled
          ? Colors.transparent
          : (s.pressed ? c.surfacePressed : (s.hovered ? c.surfaceHover : Colors.transparent));
      final Decoration? ring = s.focused
          ? BoxDecoration(
              border: Border.all(color: c.focus, width: 2),
              borderRadius: segmented ? BorderRadius.all(context.radii.sm) : null,
            )
          : null;
      if (segmented) {
        return Padding(
          padding: EdgeInsets.all(context.space.s1),
          child: AnimatedContainer(
            duration: context.motion.of(context.motion.base),
            curve: context.motion.standard,
            constraints: const BoxConstraints(minWidth: AppTabs.height - 8),
            padding: EdgeInsets.symmetric(horizontal: context.space.s4),
            decoration: BoxDecoration(
              color: selected ? c.surface : overlay,
              borderRadius: BorderRadius.all(context.radii.sm),
              boxShadow: selected ? context.elevation.e1 : null,
            ),
            foregroundDecoration: ring,
            // Сегмент — по содержимому (не растягивается на всю строку фильтров), подпись по центру по вертикали.
            child: Center(widthFactor: 1, child: label),
          ),
        );
      }
      return AnimatedContainer(
        duration: context.motion.of(context.motion.fast),
        constraints: widget.variant == AppTabsVariant.scrollable
            ? const BoxConstraints(minWidth: AppTabs.scrollableMinWidth)
            : null,
        padding: EdgeInsets.symmetric(horizontal: context.space.s4),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: overlay,
          // `scrollable`: индикатор под активной вкладкой (у `fixed` — общий скользящий индикатор полосы).
          border: widget.variant == AppTabsVariant.scrollable
              ? Border(
                  bottom: BorderSide(color: selected ? c.primaryText : Colors.transparent, width: AppTabs.indicator),
                )
              : null,
        ),
        foregroundDecoration: ring,
        child: label,
      );
    }

    Widget item = DsInteractive(
      enabled: widget.enabled,
      onTap: widget.onTap,
      builder: (BuildContext context, DsInteractionState s) => SizedBox(height: AppTabs.height, child: content(s)),
    );
    if (reason != null) item = Tooltip(message: reason, child: item);
    return Semantics(
      role: SemanticsRole.tab,
      container: true,
      selected: selected,
      enabled: widget.enabled,
      button: false,
      label: semanticLabel,
      hint: reason,
      onTap: widget.enabled ? widget.onTap : null,
      excludeSemantics: true,
      child: item,
    );
  }
}
