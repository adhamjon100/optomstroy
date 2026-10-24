import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';

/// Разделитель `AppDivider` (03 §9.66): `border` 1 px, отступы `space.4` (16).
class AppDivider extends StatelessWidget {
  /// Горизонтальный разделитель.
  const AppDivider({super.key, this.indent = 0, this.spacing = 16}) : vertical = false;

  /// Вертикальный разделитель.
  const AppDivider.vertical({super.key, this.indent = 0, this.spacing = 16}) : vertical = true;

  /// Вертикальный.
  final bool vertical;

  /// Отступ линии от краёв.
  final double indent;

  /// Отступ вокруг линии (по умолчанию `space.4`).
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final Color color = context.colors.border;
    return ExcludeSemantics(
      child: vertical
          ? Padding(
              padding: EdgeInsets.symmetric(horizontal: spacing / 2),
              child: VerticalDivider(width: 1, thickness: 1, indent: indent, endIndent: indent, color: color),
            )
          : Padding(
              padding: EdgeInsets.symmetric(vertical: spacing / 2),
              child: Divider(height: 1, thickness: 1, indent: indent, endIndent: indent, color: color),
            ),
    );
  }
}
