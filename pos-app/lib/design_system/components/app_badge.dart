import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Тон бейджа: `cart` — `primary`/`onPrimary` (тёмный текст на оранжевом, 03 §5.8),
/// `alert` — `error`/`onError` (уведомления, ошибка синхронизации),
/// `onPrimary` — `surface`/`primaryText` с обводкой `primary`: счётчик поверх кнопки с заливкой `primary`
/// (`CartFab`), где бейдж `cart` сливался бы с кнопкой (ревью E, E-flutter-ui-13).
enum AppBadgeTone { cart, alert, onPrimary }

/// Числовой бейдж `AppBadge` (03 §9.66, анатомия из `NotificationBell`): круг/пилюля
/// высотой 18, число `micro 11/600` (только 1–2 цифры, A11Y-008), > 99 → «99+».
/// [count] = `null` — точка 8 px (новые уведомления без числа).
class AppBadge extends StatelessWidget {
  /// Создаёт бейдж.
  const AppBadge({super.key, required this.count, this.tone = AppBadgeTone.alert, this.semanticLabel});

  /// Точка без числа.
  const AppBadge.dot({super.key, this.tone = AppBadgeTone.alert, this.semanticLabel}) : count = null;

  /// Число; `null` — точка.
  final int? count;

  /// Тон.
  final AppBadgeTone tone;

  /// Подпись для screen reader («5 позиций»).
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final (Color bg, Color fg) = switch (tone) {
      AppBadgeTone.cart => (colors.primary, colors.onPrimary),
      AppBadgeTone.alert => (colors.error, colors.onError),
      AppBadgeTone.onPrimary => (colors.surface, colors.primaryText),
    };
    final Border? ring = tone == AppBadgeTone.onPrimary ? Border.all(color: colors.primary, width: 1.5) : null;
    final Widget badge;
    if (count == null) {
      badge = Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: bg, shape: BoxShape.circle, border: ring),
      );
    } else {
      final String text = count! > 99 ? '99+' : '$count';
      badge = Container(
        constraints: const BoxConstraints(minWidth: 18),
        height: 18,
        padding: const EdgeInsets.symmetric(horizontal: 5),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.all(context.radii.full), border: ring),
        child: Text(
          text,
          maxLines: 1,
          textScaler: TextScaler.noScaling,
          style: context.text.micro.copyWith(color: fg, fontFeatures: DsTypography.numeric, height: 1),
        ),
      );
    }
    return Semantics(label: semanticLabel, excludeSemantics: semanticLabel != null, child: badge);
  }
}
