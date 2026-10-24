import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Пункт `AppDropdown`.
@immutable
class AppDropdownItem<T> {
  /// Создаёт пункт.
  const AppDropdownItem({required this.value, required this.label, this.icon, this.enabled = true});

  /// Значение.
  final T value;

  /// Подпись.
  final String label;

  /// Иконка 20.
  final IconData? icon;

  /// Доступен.
  final bool enabled;
}

/// Выпадающий выбор `AppDropdown` (03 §9.66): поле со стилем `AppTextField` (подпись над полем,
/// обводка `borderStrong`, высота 48) и меню в стиле `SortMenu` (`surface`, `elevation.2`,
/// выбранный пункт — `primaryContainer` + галочка `primaryText`).
class AppDropdown<T> extends StatefulWidget {
  /// Создаёт выпадающий список.
  const AppDropdown({
    super.key,
    required this.items,
    required this.value,
    required this.onChanged,
    this.label,
    this.hint,
    this.errorText,
    this.semanticLabel,
  });

  /// Пункты.
  final List<AppDropdownItem<T>> items;

  /// Выбранное значение.
  final T? value;

  /// Выбор; `null` — недоступен.
  final ValueChanged<T>? onChanged;

  /// Подпись над полем.
  final String? label;

  /// Плейсхолдер.
  final String? hint;

  /// Ошибка.
  final String? errorText;

  /// Подпись для screen reader.
  final String? semanticLabel;

  @override
  State<AppDropdown<T>> createState() => _AppDropdownState<T>();
}

class _AppDropdownState<T> extends State<AppDropdown<T>> {
  final MenuController _menu = MenuController();
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final bool enabled = widget.onChanged != null;
    final AppDropdownItem<T>? selected = widget.items
        .where((AppDropdownItem<T> i) => i.value == widget.value)
        .firstOrNull;
    final bool hasError = widget.errorText != null;
    final BorderRadius radius = BorderRadius.all(context.radii.sm);

    final Widget anchor = MenuAnchor(
      controller: _menu,
      onOpen: () => setState(() => _open = true),
      onClose: () => setState(() => _open = false),
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll<Color>(c.surface),
        surfaceTintColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
        elevation: const WidgetStatePropertyAll<double>(2),
        shadowColor: WidgetStatePropertyAll<Color>(c.inverseSurface.withValues(alpha: 0.3)),
        shape: WidgetStatePropertyAll<OutlinedBorder>(RoundedRectangleBorder(borderRadius: radius)),
        padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(EdgeInsets.symmetric(vertical: 4)),
      ),
      menuChildren: <Widget>[
        for (final AppDropdownItem<T> item in widget.items)
          MenuItemButton(
            onPressed: item.enabled ? () => widget.onChanged?.call(item.value) : null,
            leadingIcon: item.icon == null ? null : Icon(item.icon, size: 20),
            trailingIcon: item.value == widget.value ? Icon(Icons.check_rounded, size: 20, color: c.primaryText) : null,
            style: ButtonStyle(
              minimumSize: const WidgetStatePropertyAll<Size>(Size(160, 48)),
              backgroundColor: WidgetStateProperty.resolveWith<Color?>(
                (Set<WidgetState> s) => item.value == widget.value
                    ? c.primaryContainer
                    : s.contains(WidgetState.pressed)
                    ? c.surfacePressed
                    : s.contains(WidgetState.hovered) || s.contains(WidgetState.focused)
                    ? c.surfaceHover
                    : null,
              ),
              foregroundColor: WidgetStateProperty.resolveWith<Color?>(
                (Set<WidgetState> s) => s.contains(WidgetState.disabled) ? c.disabledText : c.textPrimary,
              ),
              textStyle: WidgetStatePropertyAll<TextStyle>(context.text.body),
              overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
            ),
            child: Text(item.label),
          ),
      ],
      builder: (BuildContext context, MenuController controller, Widget? child) => DsInteractive(
        enabled: enabled,
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
        builder: (BuildContext context, DsInteractionState s) {
          final (Color border, double width) = !enabled
              ? (c.disabledText, 1.0)
              : hasError
              ? (c.error, 2.0)
              : _open
              ? (c.primaryText, 2.0)
              : (s.hovered ? c.textSecondary : c.borderStrong, 1.0);
          return DsFocusRing(
            visible: s.focused,
            borderRadius: radius,
            child: Container(
              height: 48,
              padding: const EdgeInsetsDirectional.only(start: 16, end: 12),
              decoration: BoxDecoration(
                color: enabled ? c.surface : c.disabledBg,
                borderRadius: radius,
                border: Border.all(color: border, width: width),
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      selected?.label ?? widget.hint ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.bodyLg.copyWith(
                        color: !enabled ? c.disabledText : (selected == null ? c.textTertiary : c.textPrimary),
                      ),
                    ),
                  ),
                  Icon(
                    _open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    size: 20,
                    color: enabled ? c.textSecondary : c.disabledText,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel ?? widget.label,
      value: selected?.label,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (widget.label != null) ...<Widget>[
            ExcludeSemantics(
              child: Text(
                widget.label!,
                style: context.text.label.copyWith(
                  color: !enabled ? c.textSecondary : (hasError ? c.error : (_open ? c.primaryText : c.textSecondary)),
                ),
              ),
            ),
            const SizedBox(height: 4),
          ],
          anchor,
          if (hasError) ...<Widget>[
            const SizedBox(height: 4),
            Semantics(
              liveRegion: true,
              child: Text(widget.errorText!, style: context.text.caption.copyWith(color: c.error)),
            ),
          ],
        ],
      ),
    );
  }
}
