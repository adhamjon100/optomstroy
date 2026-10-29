// SCR-02 «Подтверждение кода из SMS» (`/auth/otp`; 02 SCR-02; 09 §4.4, §5.3; D-10).
//
// Экран одинаков для существующего и нового номера (И4). Таймеры — от абсолютного времени
// (`expiresAt`, `resendAvailableAt`); числа попыток и `retryAfter` — только с сервера.
// Код не логируется и не показывается в снекбарах; после ответа сервера обнуляется.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/date_range_picker.dart' show DsBishkekTime;
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/otp_field.dart';
import 'package:optomstroy/design_system/formats/ds_phone_format.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';
import 'package:optomstroy/features/auth/auth_providers.dart';
import 'package:optomstroy/features/auth/domain/entities/otp_challenge.dart';
import 'package:optomstroy/features/auth/domain/entities/verify_outcome.dart';
import 'package:optomstroy/features/auth/presentation/auth_messages.dart';
import 'package:optomstroy/features/auth/presentation/mascot/mascot.dart';
import 'package:optomstroy/features/auth/presentation/mascot/mascot_controller.dart';
import 'package:optomstroy/features/auth/presentation/navigation/auth_paths.dart';
import 'package:optomstroy/features/auth/presentation/notifiers/auth_flow_notifier.dart';
import 'package:optomstroy/features/auth/presentation/widgets/auth_layout.dart';
import 'package:optomstroy/features/auth/presentation/widgets/secure_content.dart';

class OtpScreen extends ConsumerStatefulWidget {
  const OtpScreen({super.key, this.mascotRenderer, this.alwaysShowSubmit});

  static const Key screenKey = Key('scr-02-otp');
  static const Key fieldKey = Key('scr-02-otp-field');
  static const Key submitKey = Key('scr-02-submit');
  static const Key resendKey = Key('scr-02-resend');
  static const Key resendTimerKey = Key('scr-02-resend-timer');
  static const Key ttlKey = Key('scr-02-ttl');
  static const Key deliveryKey = Key('scr-02-delivery');
  static const Key lockedBannerKey = Key('scr-02-locked-banner');
  static const Key errorBannerKey = Key('scr-02-error-banner');
  static const Key backKey = Key('scr-02-back');
  static const Key noSmsKey = Key('scr-02-no-sms');
  static const Key devCodeKey = Key('scr-02-dev-code');

  /// Опрос статуса доставки: раз в 3 с не дольше 30 с (UI-02-016).
  static const Duration deliveryPollEvery = Duration(seconds: 3);
  static const int deliveryPollMaxTicks = 10;

  /// Пауза успеха до перехода (ANIM-005, ≤ 900 мс).
  static const Duration successHold = Duration(milliseconds: 900);

  final MascotRenderer? mascotRenderer;

  /// Кнопка «Подтвердить» видна всегда (Windows); по умолчанию — по платформе (09 §4.4).
  final bool? alwaysShowSubmit;

  @override
  ConsumerState<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends ConsumerState<OtpScreen> {
  final MascotController _mascot = MascotController();
  final FocusNode _focus = FocusNode(debugLabel: 'SCR-02 code');
  Timer? _ticker;
  Timer? _poll;
  Timer? _leaveTimer;
  String? _pollingFor;
  String _code = '';
  bool _leaving = false;

  /// Последний кадр экрана — показывается, пока идёт переход после входа (поток уже очищен).
  Widget? _last;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => _mascot.onFieldFocus(_focus.hasFocus));
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }
      ref.read(authFlowProvider.notifier).markExpiredIfNeeded();
      setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _poll?.cancel();
    _leaveTimer?.cancel();
    _focus.dispose();
    _mascot.dispose();
    super.dispose();
  }

  bool get _touch {
    if (widget.alwaysShowSubmit != null) {
      return !widget.alwaysShowSubmit!;
    }
    final TargetPlatform p = Theme.of(context).platform;
    return p == TargetPlatform.android || p == TargetPlatform.iOS;
  }

  void _ensurePolling(OtpChallenge challenge) {
    if (_pollingFor == challenge.challengeId) {
      return;
    }
    _poll?.cancel();
    _pollingFor = challenge.challengeId;
    _poll = Timer.periodic(OtpScreen.deliveryPollEvery, (Timer t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      final AuthFlowState s = ref.read(authFlowProvider);
      final bool done = s.delivery == OtpDeliveryState.sent || s.delivery == OtpDeliveryState.failed;
      if (done || t.tick > OtpScreen.deliveryPollMaxTicks || s.challenge?.challengeId != challenge.challengeId) {
        t.cancel();
        return;
      }
      unawaited(ref.read(authFlowProvider.notifier).pollDelivery());
    });
  }

  void _back() {
    if (ref.read(authFlowProvider).otpPhase == OtpPhase.verifying) {
      return;
    }
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AuthPaths.phone);
    }
  }

  void _leaveTo(String location) {
    if (_leaving || !mounted) {
      return;
    }
    _leaving = true;
    _leaveTimer?.cancel();
    context.go(location);
    ref.read(authFlowProvider.notifier).reset();
  }

  void _onEffect(AuthFlowEffect? prev, AuthFlowEffect? next) {
    if (next == null || next.id == prev?.id || !mounted) {
      return;
    }
    switch (next) {
      case VerifiedEffect(:final VerifyOutcome outcome):
        final String target = AuthPaths.afterVerify(outcome, returnTo: ref.read(authFlowProvider).returnTo);
        // Токены уже сохранены (И7): переход не позже 900 мс, тап — сразу.
        final Duration hold = context.motion.reduceMotion ? const Duration(milliseconds: 300) : OtpScreen.successHold;
        _leaveTimer = Timer(hold, () => _leaveTo(target));
      case BackToPhoneEffect(:final reason):
        _leaving = true;
        context.go(AuthPaths.phoneWith(reason: reason));
      case OpenOtpEffect():
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final AuthFlowState s = ref.watch(authFlowProvider);
    final DateTime now = ref.watch(clockProvider).nowUtc();
    final bool offline = ref.watch(authOfflineSignalProvider);

    ref
      ..listen<int>(authFlowProvider.select((AuthFlowState v) => v.mascotSeq), (int? _, int _) {
        final MascotSignal? signal = ref.read(authFlowProvider).mascot;
        if (signal != null) {
          _mascot.apply(signal);
        }
      })
      ..listen<AuthFlowEffect?>(authFlowProvider.select((AuthFlowState v) => v.effect), _onEffect)
      ..listen<int>(authFlowProvider.select((AuthFlowState v) => v.resentCount), (int? prev, int next) {
        if (prev != null && next > prev && mounted) {
          AppSnackbar.show(context, message: l10n.auth_otp_resent, variant: AppSnackbarVariant.success);
        }
      });

    final OtpChallenge? challenge = s.challenge;
    if (challenge == null) {
      if (_leaving && _last != null) {
        return _last!;
      }
      // Прямой переход без потока входа → SCR-01 (guard SCR-02.10).
      if (!_leaving) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_leaving && ref.read(authFlowProvider).challenge == null) {
            _leaving = true;
            context.go(AuthPaths.phone);
          }
        });
      }
      return const SizedBox.shrink(key: OtpScreen.screenKey);
    }
    _ensurePolling(challenge);

    final bool alive = challenge.isAliveAt(now);
    final bool lockedNow = s.otpPhase == OtpPhase.locked && s.otpLockedUntil != null && now.isBefore(s.otpLockedUntil!);
    final bool verifying = s.otpPhase == OtpPhase.verifying;
    final CodeFieldStatus fieldStatus = switch (s.otpPhase) {
      OtpPhase.verifying => CodeFieldStatus.loading,
      OtpPhase.success => CodeFieldStatus.success,
      OtpPhase.invalid => CodeFieldStatus.error,
      OtpPhase.expired || OtpPhase.locked || OtpPhase.forbidden => CodeFieldStatus.disabled,
      _ => alive ? CodeFieldStatus.idle : CodeFieldStatus.disabled,
    };

    String? error;
    switch (s.otpPhase) {
      case OtpPhase.invalid:
        error = l10n.auth_error_otp_invalid(s.attemptsLeft ?? 0);
      case OtpPhase.expired:
        error = l10n.auth_error_otp_expired;
      case OtpPhase.locked:
        error = null; // баннер UI-02-010 с таймером
      case OtpPhase.forbidden:
        error = l10n.auth_blocked_message;
      case OtpPhase.failed:
        error = s.otpFailure == null ? null : AuthMessages.failure(l10n, s.otpFailure!);
      case OtpPhase.idle || OtpPhase.verifying || OtpPhase.success:
        error = !alive ? l10n.auth_error_otp_expired : null;
    }
    if (error == null && s.usingPreviousChallenge && s.otpPhase == OtpPhase.idle) {
      error = l10n.auth_otp_fallback_previous;
    }

    // UI-02-007: повторная отправка.
    final bool resendLimited = s.resendBlockedUntil != null && now.isBefore(s.resendBlockedUntil!);
    final bool resendOpen =
        !lockedNow &&
        !resendLimited &&
        (challenge.canResendAt(now) ||
            !alive ||
            s.delivery == OtpDeliveryState.failed ||
            s.otpPhase == OtpPhase.locked ||
            s.otpPhase == OtpPhase.expired);

    final Widget resend = resendLimited
        ? Text(
            AuthMessages.rateLimited(l10n, s.resendBlockedUntil!.difference(now)),
            key: OtpScreen.resendTimerKey,
            textAlign: TextAlign.center,
            style: context.text.caption.copyWith(color: c.textSecondary),
          )
        : resendOpen
        ? AppButton(
            key: OtpScreen.resendKey,
            label: l10n.auth_otp_resend,
            variant: AppButtonVariant.text,
            loading: s.resending,
            onPressed: verifying || s.otpPhase == OtpPhase.forbidden
                ? null
                : () => unawaited(ref.read(authFlowProvider.notifier).resend()),
          )
        : Text(
            l10n.auth_otp_resend_in(AuthMessages.mmss(challenge.resendLeft(now))),
            key: OtpScreen.resendTimerKey,
            textAlign: TextAlign.center,
            style: context.text.caption.copyWith(color: c.textSecondary),
          );

    final bool showSubmit = !_touch || s.hadOtpError;
    final bool retryCode = s.otpPhase == OtpPhase.failed && s.pendingCode != null;
    final bool canSubmit =
        !offline &&
        alive &&
        !lockedNow &&
        !verifying &&
        (retryCode || VerifyCode.complete(_code, challenge.codeLength));

    final List<Widget> banners = <Widget>[
      if (offline) ErrorState.banner(message: l10n.auth_otp_offline, tone: ErrorStateTone.warning),
      if (s.otpPhase == OtpPhase.locked && s.otpLockedUntil != null)
        ErrorState.banner(
          key: OtpScreen.lockedBannerKey,
          message: l10n.auth_error_otp_locked(_seconds(s.otpLockedUntil!.difference(now))),
        ),
      if (s.resendFailure != null && !resendLimited)
        ErrorState.banner(
          key: OtpScreen.errorBannerKey,
          message: AuthMessages.failure(l10n, s.resendFailure!),
          onRetry: AuthMessages.retryable(s.resendFailure!)
              ? () => unawaited(ref.read(authFlowProvider.notifier).resend())
              : null,
          retrying: s.resending,
        ),
    ];

    final bool compact = context.windowClass == WindowClass.compact;
    final bool expanded = context.windowClass == WindowClass.expanded || context.windowClass == WindowClass.large;
    final TextAlign align = expanded ? TextAlign.start : TextAlign.center;
    final String phone = DsPhoneFormat.display(challenge.phoneE164);

    final Widget body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          l10n.auth_otp_title,
          textAlign: align,
          style: (compact ? context.text.h2 : context.text.h1).copyWith(color: c.textPrimary),
        ),
        SizedBox(height: context.space.s2),
        Wrap(
          alignment: expanded ? WrapAlignment.start : WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Text(l10n.auth_otp_sent_to(phone), style: context.text.body.copyWith(color: c.textSecondary)),
            AppButton(
              label: l10n.auth_otp_change_phone,
              variant: AppButtonVariant.text,
              size: AppButtonSize.s,
              onPressed: verifying ? null : _back,
            ),
          ],
        ),
        SizedBox(height: context.space.s6),
        Center(
          child: OtpField(
            key: ValueKey<String>('otp-${challenge.challengeId}'),
            semanticLabel: l10n.auth_otp_code_a11y,
            length: challenge.codeLength,
            status: fieldStatus,
            errorText: error,
            focusNode: _focus,
            onChanged: (String v) {
              final bool grew = v.length > _code.length;
              _code = v;
              if (grew) {
                _mascot
                  ..onInput()
                  ..onCaret(v.length / challenge.codeLength * 2 - 1);
              }
              ref.read(authFlowProvider.notifier).codeEdited();
              setState(() {});
            },
            onCompleted: (String v) {
              if (!offline) {
                unawaited(ref.read(authFlowProvider.notifier).verify(v));
              }
            },
          ),
        ),
        SizedBox(height: context.space.s2),
        if (error == null && s.otpPhase != OtpPhase.locked)
          Text(
            verifying
                ? l10n.auth_otp_checking
                : s.otpPhase == OtpPhase.success
                ? l10n.auth_otp_verified
                : l10n.auth_otp_ttl_timer(AuthMessages.mmssPadded(challenge.ttlLeft(now))),
            key: OtpScreen.ttlKey,
            textAlign: TextAlign.center,
            style: context.text.caption.copyWith(
              color: s.otpPhase == OtpPhase.success
                  ? c.success
                  : challenge.ttlLeft(now) <= const Duration(minutes: 1)
                  ? c.warning
                  : c.textSecondary,
            ),
          ),
        if (s.delivery != null) ...<Widget>[
          SizedBox(height: context.space.s4),
          _Delivery(state: s.delivery!, l10n: l10n),
        ],
        if (showSubmit) ...<Widget>[
          SizedBox(height: context.space.s6),
          AppButton(
            key: OtpScreen.submitKey,
            label: retryCode ? l10n.ds_button_retry : l10n.auth_otp_submit,
            size: AppButtonSize.l,
            expand: true,
            loading: verifying,
            onPressed: canSubmit
                ? () => unawaited(
                    retryCode
                        ? ref.read(authFlowProvider.notifier).retryVerify()
                        : ref.read(authFlowProvider.notifier).verify(_code),
                  )
                : null,
          ),
        ],
        SizedBox(height: context.space.s4),
        Center(child: resend),
        SizedBox(height: context.space.s2),
        Center(
          child: AppButton(
            key: OtpScreen.noSmsKey,
            label: l10n.auth_otp_no_sms,
            variant: AppButtonVariant.text,
            size: AppButtonSize.s,
            onPressed: () => unawaited(_showNoSms(l10n)),
          ),
        ),
        // UI-02-017: подсказка тестового режима — только не-release сборка и не prod (AU-03, AC-UI-02-018).
        if (ref.watch(authDevCodeHintProvider) && challenge.devCode != null) ...<Widget>[
          SizedBox(height: context.space.s2),
          Text(
            l10n.auth_otp_dev_code(challenge.devCode!),
            key: OtpScreen.devCodeKey,
            textAlign: TextAlign.center,
            style: context.text.caption.copyWith(color: c.info, fontFeatures: DsTypography.numeric),
          ),
        ],
      ],
    );

    final Widget leading = compact
        ? AppIconButton(
            key: OtpScreen.backKey,
            icon: Icons.arrow_back_rounded,
            semanticLabel: l10n.auth_otp_change_phone,
            onPressed: verifying ? null : _back,
          )
        : AppButton(
            key: OtpScreen.backKey,
            label: l10n.auth_otp_change_phone,
            icon: Icons.arrow_back_rounded,
            variant: AppButtonVariant.text,
            size: AppButtonSize.s,
            onPressed: verifying ? null : _back,
          );

    final Widget layout = SecureContent(
      child: AuthLayout(
        key: OtpScreen.screenKey,
        leading: leading,
        banners: banners,
        keyboardMascotSize: 72,
        footerYear: DsBishkekTime.wall(now).year,
        mascot: (BuildContext context, double /* money-double: allow — геометрия UI */ size) => Mascot(
          controller: _mascot,
          size: size,
          renderer: widget.mascotRenderer ?? const PlaceholderMascotRenderer(),
        ),
        body: body,
      ),
    );
    return _last = CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{const SingleActivator(LogicalKeyboardKey.escape): _back},
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        // Тап во время показа успеха — переход немедленно (И7).
        onTap: s.otpPhase == OtpPhase.success && _leaveTimer != null
            ? () {
                final AuthFlowState st = ref.read(authFlowProvider);
                final AuthFlowEffect? e = st.effect;
                if (e is VerifiedEffect) {
                  _leaveTo(AuthPaths.afterVerify(e.outcome, returnTo: st.returnTo));
                }
              }
            : null,
        child: layout,
      ),
    );
  }

  static int _seconds(Duration d) => d.isNegative ? 0 : (d.inMilliseconds / 1000).ceil();

  Future<void> _showNoSms(AppLocalizations l10n) => AppBottomSheet.show<void>(
    context,
    title: l10n.auth_otp_no_sms,
    body: Padding(
      padding: EdgeInsets.all(context.space.s4),
      child: Text(l10n.auth_otp_no_sms_body, style: context.text.body),
    ),
    footer: Padding(
      padding: EdgeInsets.all(context.space.s4),
      child: AppButton(
        label: l10n.auth_otp_change_phone,
        variant: AppButtonVariant.outlined,
        expand: true,
        onPressed: () {
          Navigator.of(context).pop();
          _back();
        },
      ),
    ),
  );
}

/// Строка статуса доставки SMS (UI-02-016).
class _Delivery extends StatelessWidget {
  const _Delivery({required this.state, required this.l10n});

  final OtpDeliveryState state;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final (String text, Color color, Widget icon) = switch (state) {
      OtpDeliveryState.queued => (
        l10n.auth_otp_delivery_queued,
        c.textSecondary,
        const SizedBox.square(dimension: 12, child: AppProgress.circular(size: 12)),
      ),
      OtpDeliveryState.sent => (
        l10n.auth_otp_delivery_sent,
        c.success,
        Icon(Icons.check_circle_rounded, size: 16, color: c.success),
      ),
      OtpDeliveryState.failed => (
        l10n.auth_otp_delivery_failed,
        c.error,
        Icon(Icons.error_outline_rounded, size: 16, color: c.error),
      ),
    };
    return Row(
      key: OtpScreen.deliveryKey,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        icon,
        SizedBox(width: context.space.s2),
        Flexible(
          child: Text(text, style: context.text.caption.copyWith(color: color)),
        ),
      ],
    );
  }
}

/// Полнота кода для кнопки «Подтвердить».
abstract final class VerifyCode {
  static bool complete(String code, int length) => code.length == length;
}
