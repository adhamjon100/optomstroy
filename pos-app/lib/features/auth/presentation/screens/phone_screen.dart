// SCR-01 «Вход по номеру телефона» (`/auth/phone`; 02 SCR-01; 09 §3–§4; D-09, D-10).
//
// Нейтральный ответ: экран не сообщает, зарегистрирован ли номер. Номер — только память
// (AuthFlowNotifier). Ошибки — ARB (`auth_phone_error_*`, `auth_error_*`). Персонаж реагирует
// на события процесса (MascotController), результат — только после ответа сервера.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/phone_field.dart';
import 'package:optomstroy/design_system/formats/ds_phone_format.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/auth/auth_providers.dart';
import 'package:optomstroy/features/auth/domain/entities/auth_entry_reason.dart';
import 'package:optomstroy/features/auth/domain/usecases/validate_phone.dart';
import 'package:optomstroy/features/auth/presentation/auth_messages.dart';
import 'package:optomstroy/features/auth/presentation/mascot/mascot.dart';
import 'package:optomstroy/features/auth/presentation/mascot/mascot_controller.dart';
import 'package:optomstroy/features/auth/presentation/navigation/auth_paths.dart';
import 'package:optomstroy/features/auth/presentation/notifiers/auth_flow_notifier.dart';
import 'package:optomstroy/features/auth/presentation/widgets/auth_layout.dart';

class PhoneScreen extends ConsumerStatefulWidget {
  const PhoneScreen({super.key, this.entryReason, this.returnTo, this.mascotRenderer});

  static const Key screenKey = Key('scr-01-phone');
  static const Key fieldKey = Key('scr-01-phone-field');
  static const Key submitKey = Key('scr-01-submit');
  static const Key hintKey = Key('scr-01-hint');
  static const Key entryBannerKey = Key('scr-01-entry-banner');
  static const Key offlineBannerKey = Key('scr-01-offline-banner');
  static const Key requestBannerKey = Key('scr-01-request-banner');
  static const Key sendingKey = Key('scr-01-sending');

  /// Предупреждение о неотправленных изменениях прежнего сотрудника (FLOW-002.A3 / FLOW-009.E1).
  static const Key pendingChangesKey = Key('scr-01-pending-changes');

  /// Маркеры `GET /health` (RM-C-014; ключи сохраняет `NoSessionScreen`).
  static const Key healthPendingKey = Key('scr-01-health-pending');
  static const Key healthOkKey = Key('scr-01-health-ok');
  static const Key healthDownKey = Key('scr-01-health-down');

  /// Причина возврата на вход (UI-01-017), query `reason`.
  final AuthEntryReason? entryReason;

  /// Адрес возврата после входа (authGuard, query `returnTo`).
  final String? returnTo;

  /// Рендерер персонажа (заглушка до `.riv`, Q-035).
  final MascotRenderer? mascotRenderer;

  @override
  ConsumerState<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends ConsumerState<PhoneScreen> {
  final MascotController _mascot = MascotController();
  final FocusNode _focus = FocusNode(debugLabel: 'SCR-01 phone');
  late final TextEditingController _phone;
  Timer? _ticker;
  Timer? _slowTimer;
  bool _slow = false;

  /// Сигнал маски `PhoneField` (AU-04) и текст поля, к которому он относится: подсказка видна до следующей правки.
  PhoneInputSignal? _inputSignal;
  String? _inputSignalText;

  @override
  void initState() {
    super.initState();
    final AuthFlowState flow = ref.read(authFlowProvider);
    // Возврат с SCR-02 «Изменить номер» — прежний номер, курсор в конце (SRC-B-095).
    _phone = TextEditingController(text: DsPhoneFormat.groupNational(flow.phoneDigits));
    _phone.addListener(_onText);
    _focus.addListener(_onFocus);
    final AuthEntryReason? reason = widget.entryReason;
    final String? returnTo = widget.returnTo;
    if (reason != null || returnTo != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(authFlowProvider.notifier).open(reason: reason, returnTo: returnTo);
        }
      });
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _slowTimer?.cancel();
    _phone
      ..removeListener(_onText)
      ..dispose();
    _focus
      ..removeListener(_onFocus)
      ..dispose();
    _mascot.dispose();
    super.dispose();
  }

  void _onText() {
    final String text = _phone.text;
    // Ведущий «0» (национальный префикс КР) удаляется автоматически (SCR-01.4 п.4).
    if (text.startsWith('0')) {
      final String digits = text.replaceAll(RegExp(r'\D'), '').replaceFirst(RegExp('^0+'), '');
      final String grouped = DsPhoneFormat.groupNational(digits);
      _phone.value = TextEditingValue(
        text: grouped,
        selection: TextSelection.collapsed(offset: grouped.length),
      );
      return;
    }
    final AuthFlowNotifier flow = ref.read(authFlowProvider.notifier);
    final int before = ref.read(authFlowProvider).phoneDigits.length;
    flow.phoneChanged(text);
    final int digits = ref.read(authFlowProvider).phoneDigits.length;
    if (digits != before) {
      _mascot
        ..onInput()
        ..onCaret(digits / 9 * 2 - 1);
    }
  }

  void _onFocus() {
    _mascot.onFieldFocus(_focus.hasFocus);
    if (!_focus.hasFocus) {
      ref.read(authFlowProvider.notifier).phoneBlurred();
    }
  }

  Future<void> _submit() async {
    final AuthFlowState s = ref.read(authFlowProvider);
    if (s.requesting) {
      return;
    }
    await ref.read(authFlowProvider.notifier).requestOtp();
  }

  void _syncTimers(AuthFlowState s, DateTime now) {
    final bool countdown = s.isRequestBlocked(now);
    if (countdown && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() {});
        }
      });
    } else if (!countdown && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
    }
  }

  void _onRequesting(bool requesting) {
    _slowTimer?.cancel();
    _slow = false;
    if (requesting) {
      // «Отправляем код…» — через 1 с без ответа (UI-01-008 п.3).
      _slowTimer = Timer(const Duration(seconds: 1), () {
        if (mounted) {
          setState(() => _slow = true);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final AuthFlowState s = ref.watch(authFlowProvider);
    final DateTime now = ref.watch(clockProvider).nowUtc();
    final bool offline = ref.watch(authOfflineSignalProvider) || s.offline;
    _syncTimers(s, now);

    ref
      ..listen<int>(authFlowProvider.select((AuthFlowState v) => v.mascotSeq), (int? _, int _) {
        final MascotSignal? signal = ref.read(authFlowProvider).mascot;
        if (signal != null) {
          _mascot.apply(signal);
        }
      })
      ..listen<bool>(authFlowProvider.select((AuthFlowState v) => v.requesting), (bool? _, bool next) {
        _onRequesting(next);
      })
      ..listen<AuthFlowEffect?>(authFlowProvider.select((AuthFlowState v) => v.effect), (
        AuthFlowEffect? prev,
        AuthFlowEffect? next,
      ) {
        if (next is OpenOtpEffect && next.id != prev?.id && mounted) {
          unawaited(context.push(AuthPaths.otp));
        }
      });

    final PhoneCheck check = ref.watch(validatePhoneProvider).call(s.phoneDigits);
    final bool blocked = s.isRequestBlocked(now);
    final Duration blockedLeft = blocked ? s.requestBlockedUntil!.difference(now) : Duration.zero;
    final bool canSubmit = check.isValid && !offline && !blocked && !s.requesting;

    String? error;
    if (s.serverRejectedPhone) {
      error = l10n.auth_phone_error_server_invalid;
    } else if (s.phoneIssue != null) {
      error = AuthMessages.phoneIssue(l10n, s.phoneIssue!);
    } else if (_inputSignal != null && _inputSignalText == _phone.text) {
      // 02 SCR-01.8: вставка «8 (…)» → формат; больше 9 цифр → лишние отброшены.
      error = switch (_inputSignal!) {
        PhoneInputSignal.tooLong => l10n.auth_phone_error_long,
        PhoneInputSignal.unsupportedFormat => l10n.auth_phone_error_format,
      };
    }
    String? helper;
    if (error == null) {
      if (offline) {
        helper = l10n.auth_phone_offline_hint;
      } else if (s.phoneDigits.isEmpty) {
        helper = l10n.auth_phone_hint;
      } else if (check.remaining > 0) {
        helper = l10n.auth_phone_hint_remaining(check.remaining);
      }
    }

    final List<Widget> banners = <Widget>[
      if (s.entryReason != null)
        ErrorState.banner(
          key: PhoneScreen.entryBannerKey,
          message: AuthMessages.entryReason(l10n, s.entryReason!),
          tone: s.entryReason!.isWarning ? ErrorStateTone.warning : ErrorStateTone.info,
          onClose: ref.read(authFlowProvider.notifier).dismissEntryReason,
        ),
      if (offline)
        ErrorState.banner(
          key: PhoneScreen.offlineBannerKey,
          message: l10n.auth_phone_offline_hint,
          tone: ErrorStateTone.warning,
          onRetry: s.offline ? () => unawaited(ref.read(authFlowProvider.notifier).retryRequest()) : null,
          retrying: s.requesting,
        ),
      _health(context, l10n),
      if (ref.watch(authPendingChangesNoticeProvider).value case final PendingChangesNotice notice)
        ErrorState.banner(
          key: PhoneScreen.pendingChangesKey,
          message: notice.ownerName == null
              ? l10n.profile_logout_unsynced_cart
              : l10n.auth_pending_changes_other_user(notice.ownerName!),
          tone: ErrorStateTone.warning,
        ),
      if (s.requestFailure != null && !offline && s.requestFailure is! ValidationFailure)
        ErrorState.banner(
          key: PhoneScreen.requestBannerKey,
          message: blocked
              ? AuthMessages.rateLimited(l10n, blockedLeft)
              : AuthMessages.failure(l10n, s.requestFailure!),
          tone: blocked ? ErrorStateTone.warning : ErrorStateTone.error,
          onRetry: !blocked && AuthMessages.retryable(s.requestFailure!)
              ? () => unawaited(ref.read(authFlowProvider.notifier).retryRequest())
              : null,
          retrying: s.requesting,
        ),
    ];

    final bool compact = context.windowClass == WindowClass.compact;
    final TextAlign align = context.windowClass == WindowClass.expanded || context.windowClass == WindowClass.large
        ? TextAlign.start
        : TextAlign.center;
    final Widget body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          l10n.auth_phone_title,
          textAlign: align,
          style: (compact ? context.text.h2 : context.text.h1).copyWith(color: context.colors.textPrimary),
        ),
        SizedBox(height: context.space.s2),
        Text(
          l10n.auth_phone_subtitle,
          textAlign: align,
          style: context.text.body.copyWith(color: context.colors.textSecondary),
        ),
        SizedBox(height: context.space.s6),
        PhoneField(
          key: PhoneScreen.fieldKey,
          controller: _phone,
          focusNode: _focus,
          variant: PhoneFieldVariant.auth,
          label: l10n.auth_phone_label,
          semanticLabel: l10n.auth_phone_a11y,
          helper: helper,
          errorText: error,
          enabled: !s.requesting,
          loading: s.requesting,
          onInputSignal: (PhoneInputSignal signal) {
            if (mounted) {
              setState(() {
                _inputSignal = signal;
                _inputSignalText = _phone.text;
              });
            }
          },
          onSubmitted: (_) {
            if (canSubmit || !check.isValid) {
              unawaited(_submit());
            }
          },
        ),
        SizedBox(height: context.space.s6),
        AppButton(
          key: PhoneScreen.submitKey,
          label: blocked ? l10n.auth_phone_submit_wait(AuthMessages.mmss(blockedLeft)) : l10n.auth_phone_submit,
          size: AppButtonSize.l,
          expand: true,
          loading: s.requesting,
          onPressed: canSubmit ? () => unawaited(_submit()) : null,
        ),
        if (s.requesting && _slow) ...<Widget>[
          SizedBox(height: context.space.s2),
          Text(
            l10n.auth_phone_sending,
            key: PhoneScreen.sendingKey,
            textAlign: TextAlign.center,
            style: context.text.caption.copyWith(color: context.colors.textSecondary),
          ),
        ],
        SizedBox(height: context.space.s4),
        _SmsNotice(l10n: l10n),
      ],
    );

    return AuthLayout(
      key: PhoneScreen.screenKey,
      banners: banners,
      footerYear: now.toLocal().year,
      mascot:
          (BuildContext context, double size) => // money-double: allow — геометрия UI (lp)
          Mascot(
            controller: _mascot,
            size: size,
            renderer: widget.mascotRenderer ?? const PlaceholderMascotRenderer(),
          ),
      body: body,
    );
  }

  /// `GET /health` (RM-C-014): «Сервер недоступен», если `/health` не ответил 200.
  Widget _health(BuildContext context, AppLocalizations l10n) {
    final AsyncValue<BackendHealthStatus> health = ref.watch(backendHealthProvider);
    return switch (health) {
      AsyncData(value: BackendHealthStatus.ok) => const SizedBox.shrink(key: PhoneScreen.healthOkKey),
      AsyncData() || AsyncError() => ErrorState.banner(
        key: PhoneScreen.healthDownKey,
        message: l10n.ds_server_down,
        tone: ErrorStateTone.warning,
        onRetry: () => ref.invalidate(backendHealthReportProvider),
      ),
      _ => const SizedBox.shrink(key: PhoneScreen.healthPendingKey),
    };
  }
}

/// Текст о SMS и «Подробнее» (UI-01-009; 11 §10.3 Шаблон 2).
class _SmsNotice extends StatelessWidget {
  const _SmsNotice({required this.l10n});

  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final TextStyle style = context.text.caption.copyWith(color: context.colors.textSecondary);
    return Column(
      children: <Widget>[
        Text(l10n.auth_phone_sms_notice, textAlign: TextAlign.center, style: style),
        AppButton(
          label: l10n.auth_phone_sms_notice_more,
          variant: AppButtonVariant.text,
          size: AppButtonSize.s,
          onPressed: () => unawaited(
            AppBottomSheet.show<void>(
              context,
              title: l10n.auth_phone_sms_notice_more,
              body: Padding(
                padding: EdgeInsets.all(context.space.s4),
                child: Text(l10n.auth_phone_sms_notice, style: context.text.body),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
