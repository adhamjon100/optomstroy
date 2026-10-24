import 'dart:async';

import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/category_chip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';

/// Элемент полосы [StatusCountChips].
@immutable
class StatusCountChipItem<T> {
  /// Создаёт элемент.
  const StatusCountChipItem({required this.value, required this.label, this.count});

  /// Значение (группа статусов).
  final T value;

  /// Подпись группы («В работе»).
  final String label;

  /// Счётчик группы (`statusCounts`); `null` — счётчики ещё не получены или недоступны (чип без числа).
  final int? count;
}

/// Полоса чипов групп статусов со счётчиками (02 SCR-25 UI-25-003; ядро §19.2): `CategoryChip.choice`
/// с одним активным чипом, горизонтальная прокрутка, промежуток 8; выбранный чип подводится в видимую область
/// (ANIM-017, `ensureVisible`). Подпись со счётчиком строит [countLabel] («В работе · 12» —
/// `orders_chip_count`); без [countLabel] число рисуется справа от подписи (`caption tnum`).
class StatusCountChips<T> extends StatefulWidget {
  /// Создаёт полосу.
  const StatusCountChips({
    super.key,
    required this.items,
    required this.selected,
    required this.onSelected,
    this.countLabel,
    this.enabled = true,
    this.padding,
  });

  /// Чипы по порядку.
  final List<StatusCountChipItem<T>> items;

  /// Выбранное значение (`null` — ни один чип не активен: набор статусов из маршрута не совпал с группой).
  final T? selected;

  /// Выбор чипа.
  final ValueChanged<T> onSelected;

  /// Подпись со счётчиком.
  final String Function(String label, int count)? countLabel;

  /// Доступна (офлайн — нет).
  final bool enabled;

  /// Внутренний отступ полосы.
  final EdgeInsetsGeometry? padding;

  @override
  State<StatusCountChips<T>> createState() => _StatusCountChipsState<T>();
}

class _StatusCountChipsState<T> extends State<StatusCountChips<T>> {
  final Map<T, GlobalKey> _keys = <T, GlobalKey>{};

  GlobalKey _keyOf(T value) => _keys.putIfAbsent(value, GlobalKey.new);

  @override
  void didUpdateWidget(covariant StatusCountChips<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected && widget.selected != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final BuildContext? ctx = _keys[widget.selected]?.currentContext;
        if (ctx == null || !ctx.mounted) return;
        unawaited(
          Scrollable.ensureVisible(
            ctx,
            alignment: 0.5,
            duration: context.motion.of(context.motion.base),
            curve: context.motion.standard,
          ),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final String Function(String label, int count)? fmt = widget.countLabel;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: widget.padding,
      child: Row(
        children: <Widget>[
          for (int i = 0; i < widget.items.length; i++) ...<Widget>[
            if (i > 0) SizedBox(width: context.space.s2),
            KeyedSubtree(key: _keyOf(widget.items[i].value), child: _chip(widget.items[i], fmt)),
          ],
        ],
      ),
    );
  }

  Widget _chip(StatusCountChipItem<T> item, String Function(String label, int count)? fmt) {
    final int? count = item.count;
    return CategoryChip(
      label: count != null && fmt != null ? fmt(item.label, count) : item.label,
      count: fmt == null ? count : null,
      selected: item.value == widget.selected,
      enabled: widget.enabled,
      onTap: () => widget.onSelected(item.value),
    );
  }
}
