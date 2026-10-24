import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';

/// Заголовок секции `AppSectionHeader` (03 §9.66): `label 600 textSecondary` + действие справа
/// (`AppButton.text S`) — «Недавние товары · Очистить».
class AppSectionHeader extends StatelessWidget {
  /// Создаёт заголовок.
  const AppSectionHeader({super.key, required this.title, this.actionLabel, this.onAction, this.padding});

  /// Текст.
  final String title;

  /// Действие («Очистить»).
  final String? actionLabel;

  /// Действие.
  final VoidCallback? onAction;

  /// Отступы (по умолчанию 16 по горизонтали).
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding ?? const EdgeInsets.symmetric(horizontal: 16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.label.copyWith(fontWeight: FontWeight.w600, color: context.colors.textSecondary),
                ),
              ),
            ),
            if (actionLabel != null)
              AppButton(
                label: actionLabel!,
                onPressed: onAction,
                variant: AppButtonVariant.text,
                size: AppButtonSize.s,
              ),
          ],
        ),
      ),
    );
  }
}
