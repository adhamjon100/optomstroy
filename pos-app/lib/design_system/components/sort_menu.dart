import 'dart:async';

import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Пункт `SortMenu`.
@immutable
class SortMenuOption<T> {
  /// Создаёт пункт.
  const SortMenuOption({required this.value, required this.label});

  /// Значение (сортировка API).
  final T value;

  /// Подпись («По возрастанию цены»).
  final String label;
}

/// Выбор сортировки `SortMenu` (03 §9.24): кнопка `outlined` с `swap_vert` 20 и текущим пунктом
/// (на compact — только иконка) → меню 240 (`elevation.2`, пункты 44, активный —
/// `primaryContainer` + `check`); на compact — `AppBottomSheet`. Повторный выбор текущего пункта
/// закрывает меню без [onSelected] (02 SCR-10.11).
class SortMenu<T> extends StatelessWidget {
  /// Создаёт меню.
  const SortMenu({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
    required this.semanticLabel,
    this.iconOnly = false,
    this.sheetTitle,
  });

  /// Пункты (≤ 8).
  final List<SortMenuOption<T>> options;

  /// Текущая сортировка.
  final T selected;

  /// Выбор нового пункта.
  final ValueChanged<T> onSelected;

  /// Подпись кнопки для screen reader («Сортировка: по названию»).
  final String semanticLabel;

  /// Только иконка (compact) — выбор в нижнем листе.
  final bool iconOnly;

  /// Заголовок листа (compact).
  final String? sheetTitle;

  String get _currentLabel {
    for (final SortMenuOption<T> o in options) {
      if (o.value == selected) {
        return o.label;
      }
    }
    return options.isEmpty ? '' : options.first.label;
  }

  Future<void> _open(BuildContext context) async {
    final Future<T?> pending = iconOnly ? _openSheet(context) : _openMenu(context);
    final T? picked = await pending;
    if (picked != null && picked != selected) {
      onSelected(picked);
    }
  }

  Future<T?> _openMenu(BuildContext context) {
    final RenderBox box = context.findRenderObject()! as RenderBox;
    final RenderBox overlay = Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final Offset topLeft = box.localToGlobal(Offset(0, box.size.height + 4), ancestor: overlay);
    final DsColors c = context.colors;
    return showMenu<T>(
      context: context,
      color: c.surface,
      elevation: 0,
      constraints: const BoxConstraints(minWidth: 240, maxWidth: 240),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(context.radii.sm),
        side: BorderSide(color: c.border),
      ),
      position: RelativeRect.fromLTRB(topLeft.dx, topLeft.dy, overlay.size.width - topLeft.dx - box.size.width, 0),
      items: <PopupMenuEntry<T>>[
        for (final SortMenuOption<T> o in options)
          PopupMenuItem<T>(
            value: o.value,
            height: 44,
            padding: EdgeInsets.zero,
            child: _OptionRow(label: o.label, selected: o.value == selected),
          ),
      ],
    );
  }

  Future<T?> _openSheet(BuildContext context) => AppBottomSheet.show<T>(
    context,
    title: sheetTitle,
    body: Builder(
      builder: (BuildContext sheet) => Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final SortMenuOption<T> o in options)
            DsInteractive(
              onTap: () => Navigator.of(sheet).pop(o.value),
              builder: (BuildContext context, DsInteractionState s) => SizedBox(
                height: 48,
                child: _OptionRow(label: o.label, selected: o.value == selected, hovered: s.hovered),
              ),
            ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Semantics(
      button: true,
      label: semanticLabel,
      excludeSemantics: true,
      child: DsInteractive(
        onTap: () => unawaited(_open(context)),
        builder: (BuildContext context, DsInteractionState s) {
          final Color bg = s.pressed ? c.primaryContainerPressed : (s.hovered ? c.primaryContainer : c.surface);
          return DsFocusRing(
            visible: s.focused,
            borderRadius: BorderRadius.all(context.radii.sm),
            child: SizedBox(
              height: 48,
              child: Center(
                child: Container(
                  height: 36,
                  constraints: const BoxConstraints(minWidth: 44),
                  padding: EdgeInsets.symmetric(horizontal: iconOnly ? context.space.s2 : context.space.s3),
                  decoration: BoxDecoration(
                    color: bg,
                    border: Border.all(color: c.borderStrong),
                    borderRadius: BorderRadius.all(context.radii.sm),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(Icons.swap_vert_rounded, size: 20, color: c.textPrimary),
                      if (!iconOnly) ...<Widget>[
                        SizedBox(width: context.space.s2),
                        Text(
                          _currentLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.label.copyWith(fontWeight: FontWeight.w500, color: c.textPrimary),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.label, required this.selected, this.hovered = false});

  final String label;
  final bool selected;
  final bool hovered;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Semantics(
      selected: selected,
      child: Container(
        color: selected ? c.primaryContainer : (hovered ? c.surfaceHover : Colors.transparent),
        padding: EdgeInsets.symmetric(horizontal: context.space.s4),
        alignment: AlignmentDirectional.centerStart,
        child: Row(
          children: <Widget>[
            SizedBox(width: 24, child: selected ? Icon(Icons.check_rounded, size: 20, color: c.primaryText) : null),
            SizedBox(width: context.space.s2),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.body.copyWith(
                  color: selected ? c.primaryText : c.textPrimary,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
