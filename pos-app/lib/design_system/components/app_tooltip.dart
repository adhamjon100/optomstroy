import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';

/// Подсказка `AppTooltip` (03 §9.64; ядро §17.5): плашка `inverseSurface` с текстом
/// `caption 12/500` `onInverseSurface`, ширина ≤ 280, показ через 500 мс (указатель),
/// долгое нажатие — на тач; скрытие через 100 мс / 1,5 с. Содержимое дублируется
/// в семантике элемента (screen reader читает без наведения).
class AppTooltip extends StatelessWidget {
  /// Текстовая подсказка.
  const AppTooltip({super.key, required this.message, required this.child, this.waitDuration}) : title = null;

  /// Подсказка с заголовком `label 600` (права роли, остатки по складам).
  const AppTooltip.rich({
    super.key,
    required this.title,
    required this.message,
    required this.child,
    this.waitDuration,
  });

  /// Заголовок (`rich`).
  final String? title;

  /// Текст (≤ 3 строк). Пустой текст — подсказка не показывается.
  final String message;

  /// Элемент.
  final Widget child;

  /// Задержка показа (по умолчанию 500 мс; 700 мс — названия в карточках).
  final Duration? waitDuration;

  @override
  Widget build(BuildContext context) {
    if (message.isEmpty) {
      return child;
    }
    final colors = context.colors;
    final TextStyle body = context.text.captionMedium.copyWith(color: colors.onInverseSurface);
    return Tooltip(
      message: title == null ? message : null,
      richMessage: title == null
          ? null
          : TextSpan(
              children: <InlineSpan>[
                TextSpan(
                  text: '$title\n',
                  style: context.text.label.copyWith(fontWeight: FontWeight.w600, color: colors.onInverseSurface),
                ),
                TextSpan(text: message, style: body),
              ],
            ),
      textStyle: body,
      constraints: const BoxConstraints(maxWidth: 280),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      verticalOffset: 28,
      decoration: BoxDecoration(
        color: colors.inverseSurface,
        borderRadius: BorderRadius.all(context.radii.sm),
        boxShadow: context.elevation.e2,
      ),
      waitDuration: waitDuration ?? const Duration(milliseconds: 500),
      exitDuration: const Duration(milliseconds: 100),
      showDuration: const Duration(milliseconds: 1500),
      triggerMode: TooltipTriggerMode.longPress,
      enableTapToDismiss: true,
      child: child,
    );
  }
}
