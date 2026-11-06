// Диалог автосброса «Вы ещё здесь?» SCR-51 / SCR-52 (02 ч. F UI-51-016, AC-UI-51-014; 03 §9.45 вариант `countdown`,
// DS-103, A11Y-023; 04 FLOW-045.S1–S3; Р-09 (а); 13 TAB-2-05).
//
// Вид и метрики — как у `ConfirmDialog` (радиус `lg`, `elevation.3`, затемнение `overlay`, отступ 24, появление —
// fade + scale 0.96 → 1), ширина 480, без иконки; заголовок `kiosk_idle_title`, текст `kiosk_idle_body` с отсчётом
// (`tnum`, обновление раз в секунду); кнопки L: `AppButton.text` «Начать заново» и `AppButton.primary` «Продолжить»
// (фокус по умолчанию — безопасное действие, корзина сохраняется). Таймер диалог не хранит: длительность и оставшиеся
// секунды передаёт монитор бездействия (`kiosk_idle_monitor.dart`), он же закрывает диалог в конце отсчёта.
//
// Итог маршрута: `true` — «Продолжить»; `null` — Esc, «Назад», тап по затемнению (то же «Продолжить», WCAG 2.2.1 —
// продление одним действием); `false` — «Начать заново» и конец отсчёта. Диктор: при открытии — заголовок (имя
// маршрута) и «Через {n} с корзина очистится» (`liveRegion`), дальше отсчёт объявляется только на 5 с и 0.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/motion/ds_animations.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Диалог «Вы ещё здесь?» (UI-51-016).
class KioskIdleDialog extends StatelessWidget {
  const KioskIdleDialog({required this.seconds, required this.remaining, super.key});

  static const Key dialogKey = ValueKey<String>('kiosk-idle-dialog');
  static const Key bodyKey = ValueKey<String>('kiosk-idle-body');
  static const Key announcementKey = ValueKey<String>('kiosk-idle-announcement');
  static const Key continueKey = ValueKey<String>('kiosk-idle-continue');
  static const Key startOverKey = ValueKey<String>('kiosk-idle-start-over');

  /// Ширина диалога, lp (02 UI-51-016).
  static const double width = 480; // money-double: allow — ширина диалога в lp, не деньги

  /// С какой секунды отсчёт снова объявляется диктором (A11Y-023).
  static const int announceAt = 5;

  /// Длительность отсчёта, с (`kiosk_idle_warning_seconds`).
  final int seconds;

  /// Сколько секунд осталось (ведёт монитор).
  final ValueListenable<int> remaining;

  /// Число секунд, которое объявляет диктор при [left] оставшихся: в начале — [seconds], с 5 с — 5, в конце — 0.
  static int announced(int seconds, int left) {
    if (left <= 0) return 0;
    if (left <= announceAt) return seconds < announceAt ? seconds : announceAt;
    return seconds;
  }

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Center(
      child: Semantics(
        key: dialogKey,
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: l10n.kiosk_idle_title,
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            width: width,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.all(context.radii.lg),
              boxShadow: context.elevation.e3,
            ),
            child: FocusScope(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  ExcludeSemantics(
                    child: Text(l10n.kiosk_idle_title, style: context.text.h3.copyWith(color: c.textPrimary)),
                  ),
                  const SizedBox(height: 8),
                  ValueListenableBuilder<int>(
                    valueListenable: remaining,
                    builder: (BuildContext context, int left, Widget? _) {
                      final int shown = left < 0 ? 0 : left;
                      return Semantics(
                        key: announcementKey,
                        liveRegion: true,
                        label: l10n.kiosk_idle_body(announced(seconds, shown)),
                        child: ExcludeSemantics(
                          child: Text(
                            l10n.kiosk_idle_body(shown),
                            key: bodyKey,
                            style: context.text.body.copyWith(
                              color: c.textSecondary,
                              fontFeatures: DsTypography.numeric,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 24),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        AppButton(
                          key: startOverKey,
                          label: l10n.kiosk_start_over,
                          variant: AppButtonVariant.text,
                          size: AppButtonSize.l,
                          onPressed: () => Navigator.of(context).pop(false),
                        ),
                        AppButton(
                          key: continueKey,
                          label: l10n.kiosk_idle_continue,
                          size: AppButtonSize.l,
                          autofocus: true,
                          onPressed: () => Navigator.of(context).pop(true),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Маршрут диалога для [Navigator.push] (корневой навигатор): затемнение `overlay`, Esc, «Назад» и тап по
/// затемнению закрывают с `null` («Продолжить»).
RawDialogRoute<bool> kioskIdleDialogRoute(
  BuildContext context, {
  required int seconds,
  required ValueListenable<int> remaining,
}) {
  final DsColors c = context.colors;
  return RawDialogRoute<bool>(
    barrierDismissible: true,
    barrierLabel: AppLocalizations.of(context).kiosk_idle_continue,
    barrierColor: c.overlay,
    transitionDuration: context.motion.of(DsAnimations.dialog.duration),
    pageBuilder: (BuildContext context, _, _) => KioskIdleDialog(seconds: seconds, remaining: remaining),
    transitionBuilder: (BuildContext context, animation, _, Widget child) {
      final CurvedAnimation curve = CurvedAnimation(parent: animation, curve: DsAnimations.dialog.curve);
      return FadeTransition(
        opacity: curve,
        child: ScaleTransition(scale: curve.drive(_scaleIn), child: child),
      );
    },
  );
}

/// Появление диалога: scale 0.96 → 1 (как `ConfirmDialog`).
final Tween<double> _scaleIn = Tween<double>(begin: 0.96, end: 1); // money-double: allow — масштаб диалога, не деньги
