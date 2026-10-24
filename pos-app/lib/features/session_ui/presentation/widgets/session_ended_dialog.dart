// SCR-90 зона C «Сессия завершена» (02 §3.3, UI-08-012; 09 §8.3): `SESSION_REVOKED`, `DEVICE_MISMATCH`,
// `reuse_detected` — диалог с одной кнопкой «Войти снова» → SCR-01; черновик корзины сохраняется
// для того же пользователя (07 §11.4). Причина — без технических деталей.
import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/session_ui/presentation/session_texts.dart';

class SessionEndedDialog extends StatelessWidget {
  const SessionEndedDialog({super.key, required this.reason, required this.onLoginAgain});

  static const Key dialogKey = Key('scr-90-session-ended');
  static const Key actionKey = Key('scr-90-session-ended-login');

  final SessionEndReason? reason;
  final VoidCallback onLoginAgain;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final c = context.colors;
    final compact = context.windowClass == WindowClass.compact;
    final width = compact ? (MediaQuery.sizeOf(context).width - 32).clamp(280.0, 480.0) : 420.0;
    return Center(
      child: Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: l10n.global_session_ended_title,
        child: Material(
          key: dialogKey,
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
              autofocus: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  ExcludeSemantics(
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(color: c.warningContainer, shape: BoxShape.circle),
                      child: Icon(Icons.logout_rounded, size: 32, color: c.warning),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Semantics(
                    header: true,
                    child: Text(l10n.global_session_ended_title, style: context.text.h3.copyWith(color: c.textPrimary)),
                  ),
                  const SizedBox(height: 8),
                  Text(SessionTexts.endReason(l10n, reason), style: context.text.body.copyWith(color: c.textSecondary)),
                  const SizedBox(height: 24),
                  AppButton(
                    key: actionKey,
                    label: l10n.global_session_login_again,
                    expand: true,
                    autofocus: true,
                    onPressed: onLoginAgain,
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
