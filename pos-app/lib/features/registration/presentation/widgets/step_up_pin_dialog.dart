// Step-up по PIN для `POST /me/biometrics` после `201` (02 SCR-04.4 п. 2; SCR-90 B `StepUpDialog` в R1 —
// без кнопки биометрии). Общий `StepUpDialog` — зона RM-D-009; здесь — минимальный диалог шага регистрации.
// Остаток попыток — только `attemptsLeft` из ответа сервера.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/secure_content.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/otp_field.dart';
import 'package:optomstroy/design_system/components/pin_field.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/registration/presentation/controllers/registration_flow_controller.dart';

class StepUpPinDialog extends ConsumerWidget {
  const StepUpPinDialog({super.key});

  static const Key dialogKey = ValueKey<String>('scr04.stepUp');
  static const Key cancelKey = ValueKey<String>('scr04.stepUp.cancel');

  static Future<void> show(BuildContext context) =>
      showDialog<void>(context: context, barrierDismissible: false, builder: (_) => const StepUpPinDialog());

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final s = ref.watch(registrationFlowProvider);
    ref.listen(registrationFlowProvider.select((v) => v.phase), (prev, next) {
      if (next != SecurityPhase.stepUp && Navigator.of(context).canPop()) Navigator.of(context).pop();
    });
    final error = s.stepUpError && s.stepUpAttemptsLeft != null
        ? l10n.auth_pin_error_invalid(s.stepUpAttemptsLeft!)
        : null;
    return Dialog(
      key: dialogKey,
      child: Padding(
        padding: EdgeInsets.all(context.space.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(l10n.ds_step_up_title, style: context.text.h3),
            SizedBox(height: context.space.s2),
            Text(
              l10n.auth_bio_enable_stepup_hint,
              textAlign: TextAlign.center,
              style: context.text.body.copyWith(color: context.colors.textSecondary),
            ),
            SizedBox(height: context.space.s6),
            SecureContent(
              child: PinField(
                key: ValueKey<String>('stepUp.${s.stepUpAttemptsLeft}'),
                length: s.pinPolicy.length,
                semanticLabel: (n, len) => l10n.reg_pin_a11y('$len', n),
                backspaceLabel: l10n.qty_key_backspace_a11y,
                status: s.stepUpError ? CodeFieldStatus.error : CodeFieldStatus.idle,
                errorText: error,
                onCompleted: (pin) => unawaited(ref.read(registrationFlowProvider.notifier).submitStepUpPin(pin)),
              ),
            ),
            SizedBox(height: context.space.s4),
            AppButton(
              key: cancelKey,
              label: l10n.ds_button_cancel,
              variant: AppButtonVariant.text,
              onPressed: ref.read(registrationFlowProvider.notifier).cancelStepUp,
            ),
          ],
        ),
      ),
    );
  }
}
