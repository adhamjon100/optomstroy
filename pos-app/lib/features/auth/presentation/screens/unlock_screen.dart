// SCR-08 «Быстрый вход и разблокировка» (`/auth/unlock?mode=cold|idle&from=`; 02 SCR-08;
// ядро §17.2; D-13, D-48). Два режима: `cold` — полноэкранный при холодном старте;
// `idle` — overlay поверх рабочего экрана ([showUnlockOverlay]) с сохранением его состояния.
// PIN проверяется только сервером; телефон не показывается (09 §9.3).
import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/otp_field.dart';
import 'package:optomstroy/design_system/components/pin_field.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/auth/auth_providers.dart';
import 'package:optomstroy/features/auth/domain/entities/auth_entry_reason.dart';
import 'package:optomstroy/features/auth/domain/entities/session_profile.dart';
import 'package:optomstroy/features/auth/domain/entities/unlock.dart';
import 'package:optomstroy/features/auth/presentation/auth_messages.dart';
import 'package:optomstroy/features/auth/presentation/mascot/mascot.dart';
import 'package:optomstroy/features/auth/presentation/mascot/mascot_controller.dart';
import 'package:optomstroy/features/auth/presentation/navigation/auth_paths.dart';
import 'package:optomstroy/features/auth/presentation/notifiers/unlock_notifier.dart';
import 'package:optomstroy/features/auth/presentation/widgets/auth_layout.dart';
import 'package:optomstroy/features/auth/presentation/widgets/secure_content.dart';

/// Полноэкранный SCR-08 (`cold`) на маршруте `/auth/unlock`.
class UnlockScreen extends StatelessWidget {
  const UnlockScreen({super.key, this.mode = UnlockMode.cold, this.from, this.mascotRenderer});

  /// Из query текущего маршрута (`mode`, `from`).
  factory UnlockScreen.fromRoute(BuildContext context) {
    final Map<String, String> q = GoRouter.maybeOf(context)?.state.uri.queryParameters ?? const <String, String>{};
    return UnlockScreen(mode: UnlockMode.parse(q[AuthPaths.modeParam]), from: q[AuthPaths.fromParam]);
  }

  static const Key screenKey = Key('scr-08-unlock');

  final UnlockMode mode;
  final String? from;
  final MascotRenderer? mascotRenderer;

  @override
  Widget build(BuildContext context) => SecureContent(
    child: UnlockView(
      key: screenKey,
      mode: mode,
      from: from,
      mascotRenderer: mascotRenderer,
      onUnlocked: (SessionProfile profile) => context.go(AuthPaths.safeReturnTo(from) ?? AuthPaths.homeFor(profile)),
    ),
  );
}

/// Overlay SCR-08 `idle` (UI-08-015): «Назад»/`Esc`/тап по scrim не закрывают; под слоем —
/// размытие 12 + `overlay` (reduce-motion — заливка без blur). Возвращает `true` после разблокировки.
Future<bool> showUnlockOverlay(
  BuildContext context, {
  int idleMinutes = 30,
  bool manual = false,
  MascotRenderer? mascotRenderer,
}) async {
  final DsColors c = context.colors;
  final bool reduce = context.motion.reduceMotion;
  final bool? result = await showGeneralDialog<bool>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: false,
    barrierColor: Colors.transparent,
    transitionDuration: reduce ? context.motion.reducedCrossfade : const Duration(milliseconds: 250),
    pageBuilder: (BuildContext ctx, _, _) => PopScope(
      canPop: false,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: reduce
                ? ColoredBox(color: c.overlay)
                : BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                    child: ColoredBox(color: c.overlay),
                  ),
          ),
          _OverlayContainer(
            child: SecureContent(
              child: UnlockView(
                key: UnlockView.overlayKey,
                mode: UnlockMode.idle,
                idleMinutes: idleMinutes,
                manual: manual,
                mascotRenderer: mascotRenderer,
                onUnlocked: (_) => Navigator.of(ctx).pop(true),
              ),
            ),
          ),
        ],
      ),
    ),
    transitionBuilder: (BuildContext ctx, a, _, Widget child) => FadeTransition(opacity: a, child: child),
  );
  return result ?? false;
}

/// compact — полноэкранный лист; medium+ — диалог 480 (`ds.radius.xl`, `elevation.3`).
class _OverlayContainer extends StatelessWidget {
  const _OverlayContainer({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    if (context.windowClass == WindowClass.compact) {
      return Material(
        color: c.surface,
        child: SafeArea(child: child),
      );
    }
    return Center(
      child: Container(
        width: AuthLayout.cardWidth,
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height - 48),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.all(context.radii.xl),
          boxShadow: context.elevation.e3,
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(color: c.surface, child: child),
      ),
    );
  }
}

/// Содержимое SCR-08 для обоих режимов.
class UnlockView extends ConsumerStatefulWidget {
  const UnlockView({
    super.key,
    required this.mode,
    required this.onUnlocked,
    this.from,
    this.idleMinutes = 30,
    this.manual = false,
    this.mascotRenderer,
  });

  static const Key overlayKey = Key('scr-08-overlay');
  static const Key pinKey = Key('scr-08-pin');
  static const Key bioKey = Key('scr-08-bio');
  static const Key helloKey = Key('scr-08-hello');
  static const Key lockedKey = Key('scr-08-locked');
  static const Key smsLoginKey = Key('scr-08-sms-login');
  static const Key retryKey = Key('scr-08-retry');
  static const Key forgotKey = Key('scr-08-forgot');
  static const Key phoneLoginKey = Key('scr-08-phone-login');
  static const Key switchKey = Key('scr-08-switch');
  static const Key nameKey = Key('scr-08-name');

  /// Авто-промпт биометрии через 300 мс после показа (UI-08-004).
  static const Duration autoPromptDelay = Duration(milliseconds: 300);

  /// Пауза успеха до перехода (ANIM-005, ≤ 900 мс).
  static const Duration successHold = Duration(milliseconds: 900);

  final UnlockMode mode;
  final String? from;
  final int idleMinutes;
  final bool manual;
  final MascotRenderer? mascotRenderer;
  final ValueChanged<SessionProfile> onUnlocked;

  @override
  ConsumerState<UnlockView> createState() => _UnlockViewState();
}

class _UnlockViewState extends ConsumerState<UnlockView> {
  final MascotController _mascot = MascotController();
  Timer? _autoPrompt;
  Timer? _leave;
  int _pinEpoch = 0;
  bool _left = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_open()));
  }

  Future<void> _open() async {
    if (!mounted) {
      return;
    }
    final UnlockNotifier n = ref.read(unlockProvider.notifier);
    await n.open(widget.mode);
    if (!mounted) {
      return;
    }
    n.setOffline(ref.read(authOfflineSignalProvider));
    if (ref.read(unlockProvider).showBiometricButton) {
      _autoPrompt = Timer(UnlockView.autoPromptDelay, () {
        if (mounted) {
          unawaited(ref.read(unlockProvider.notifier).autoPrompt());
        }
      });
    }
  }

  @override
  void dispose() {
    _autoPrompt?.cancel();
    _leave?.cancel();
    _mascot.dispose();
    super.dispose();
  }

  void _finish(SessionProfile profile) {
    if (_left || !mounted) {
      return;
    }
    _left = true;
    _leave?.cancel();
    widget.onUnlocked(profile);
  }

  void _onEffect(UnlockEffect? prev, UnlockEffect? next) {
    if (next == null || next.id == prev?.id || !mounted) {
      return;
    }
    switch (next) {
      case UnlockedEffect(:final SessionProfile profile):
        final Duration hold = context.motion.reduceMotion ? const Duration(milliseconds: 300) : UnlockView.successHold;
        _leave = Timer(hold, () => _finish(profile));
      case ToPhoneEffect(:final AuthEntryReason? reason):
        _goPhone(reason);
      case SessionEndedEffect():
        unawaited(_sessionEnded());
    }
  }

  void _goPhone(AuthEntryReason? reason) {
    final GoRouter? router = GoRouter.maybeOf(context);
    if (widget.mode == UnlockMode.idle) {
      Navigator.of(context, rootNavigator: true).pop(false);
    }
    router?.go(AuthPaths.phoneWith(reason: reason));
  }

  /// SCR-90 C «Сессия завершена» → SCR-01.
  Future<void> _sessionEnded() async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    await ConfirmDialog.show(
      context,
      title: l10n.global_session_ended_title,
      message: l10n.auth_error_revoked,
      confirmLabel: l10n.global_session_login_again,
    );
    if (mounted) {
      _goPhone(AuthEntryReason.sessionRevoked);
    }
  }

  Future<void> _forgot(AppLocalizations l10n) async {
    final bool ok = await ConfirmDialog.show(
      context,
      title: l10n.unlock_reset_title,
      message: l10n.unlock_reset_body,
      confirmLabel: l10n.unlock_reset_confirm,
      cancelLabel: l10n.ds_button_cancel,
    );
    if (ok && mounted) {
      ref.read(unlockProvider.notifier).toSmsLogin(AuthEntryReason.pinReset);
    }
  }

  Future<void> _switch(AppLocalizations l10n) async {
    final bool ok = await ConfirmDialog.show(
      context,
      title: l10n.unlock_switch_title,
      message: l10n.unlock_switch_body,
      confirmLabel: l10n.unlock_switch_confirm,
      cancelLabel: l10n.ds_button_cancel,
    );
    if (ok && mounted) {
      await ref.read(unlockProvider.notifier).switchAccount();
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final UnlockState s = ref.watch(unlockProvider);
    final DateTime now = ref.watch(clockProvider).nowUtc();

    ref
      ..listen<int>(unlockProvider.select((UnlockState v) => v.mascotSeq), (int? _, int _) {
        final UnlockState st = ref.read(unlockProvider);
        final MascotSignal? signal = st.mascot;
        if (signal != null) {
          _mascot.apply(signal);
        }
        if (st.phase == UnlockPhase.failed || st.phase == UnlockPhase.offline) {
          // Введённый PIN очищается (не хранится), повтор — вводом заново (SCR-08.4 п.8).
          setState(() => _pinEpoch++);
        }
      })
      ..listen<UnlockEffect?>(unlockProvider.select((UnlockState v) => v.effect), _onEffect)
      ..listen<bool>(authOfflineSignalProvider, (bool? _, bool offline) {
        ref.read(unlockProvider.notifier).setOffline(offline);
      });

    final bool locked = s.phase == UnlockPhase.locked;
    final CodeFieldStatus status = switch (s.phase) {
      UnlockPhase.verifying => CodeFieldStatus.loading,
      UnlockPhase.success => CodeFieldStatus.success,
      UnlockPhase.invalid => CodeFieldStatus.error,
      UnlockPhase.locked || UnlockPhase.offline => CodeFieldStatus.disabled,
      UnlockPhase.idle || UnlockPhase.failed => s.bioBusy ? CodeFieldStatus.disabled : CodeFieldStatus.idle,
    };
    String? error = switch (s.phase) {
      UnlockPhase.invalid => l10n.auth_pin_error_invalid(s.attemptsLeft ?? 0),
      UnlockPhase.failed => s.failure == null ? null : AuthMessages.failure(l10n, s.failure!),
      UnlockPhase.offline => l10n.unlock_offline,
      _ => null,
    };
    if (error == null && s.bioLockedOut) {
      error = l10n.auth_bio_lockout;
    }
    final bool canBio = s.phase != UnlockPhase.offline && !locked && !s.bioLockedOut;

    final List<Widget> children = <Widget>[
      if (widget.mode == UnlockMode.idle) ...<Widget>[
        Text(l10n.unlock_locked_title, textAlign: TextAlign.center, style: context.text.title),
        SizedBox(height: context.space.s1),
        Text(
          widget.manual ? l10n.unlock_locked_manual : l10n.unlock_locked_idle(widget.idleMinutes),
          textAlign: TextAlign.center,
          style: context.text.caption.copyWith(color: c.textSecondary),
        ),
        SizedBox(height: context.space.s4),
      ],
      _Identity(profile: s.profile, loaded: s.profileLoaded),
      SizedBox(height: context.space.s6),
      if (s.showBiometricButton) ...<Widget>[
        AppButton(
          key: UnlockView.bioKey,
          label: l10n.unlock_bio_button,
          icon: Icons.fingerprint_rounded,
          variant: AppButtonVariant.tonal,
          expand: context.windowClass == WindowClass.compact,
          loading: s.bioBusy,
          onPressed: canBio ? () => unawaited(ref.read(unlockProvider.notifier).biometric()) : null,
        ),
        SizedBox(height: context.space.s4),
        _OrDivider(label: l10n.unlock_or_pin),
        SizedBox(height: context.space.s4),
      ],
      if (s.showHelloButton) ...<Widget>[
        AppButton(
          key: UnlockView.helloKey,
          label: l10n.unlock_hello_button,
          icon: Icons.face_unlock_outlined,
          variant: AppButtonVariant.tonal,
          loading: s.bioBusy,
          onPressed: s.phase == UnlockPhase.offline || locked
              ? null
              : () => unawaited(ref.read(unlockProvider.notifier).helloGate()),
        ),
        SizedBox(height: context.space.s4),
        _OrDivider(label: l10n.unlock_or_pin),
        SizedBox(height: context.space.s4),
      ],
      if (locked) ...<Widget>[
        KeyedSubtree(
          key: UnlockView.lockedKey,
          child: ErrorState.inline(message: l10n.auth_pin_locked),
        ),
        SizedBox(height: context.space.s4),
        AppButton(
          key: UnlockView.smsLoginKey,
          label: l10n.unlock_sms_login,
          size: AppButtonSize.l,
          expand: true,
          onPressed: () => ref.read(unlockProvider.notifier).toSmsLogin(AuthEntryReason.pinLocked),
        ),
      ] else ...<Widget>[
        Text(
          s.helloVerified ? l10n.unlock_hello_verified : l10n.unlock_pin_hint,
          textAlign: TextAlign.center,
          style: context.text.caption.copyWith(color: c.textSecondary),
        ),
        SizedBox(height: context.space.s4),
        Center(
          child: PinField(
            key: ValueKey<String>('scr-08-pin-$_pinEpoch-${s.profile.effectivePinLength}'),
            length: s.profile.effectivePinLength,
            status: status,
            errorText: error,
            semanticLabel: (int n, int length) => l10n.reg_pin_a11y('$length', n),
            backspaceLabel: l10n.qty_key_backspace_a11y,
            biometricLabel: l10n.unlock_bio_button,
            onBiometric: s.showBiometricButton && canBio
                ? () => unawaited(ref.read(unlockProvider.notifier).biometric())
                : null,
            onCompleted: (String pin) {
              _mascot.onInput();
              unawaited(ref.read(unlockProvider.notifier).submitPin(pin));
            },
          ),
        ),
        if (s.phase == UnlockPhase.failed || s.phase == UnlockPhase.offline) ...<Widget>[
          SizedBox(height: context.space.s2),
          Center(
            child: AppButton(
              key: UnlockView.retryKey,
              label: l10n.ds_button_retry,
              variant: AppButtonVariant.text,
              onPressed: ref.read(unlockProvider.notifier).retry,
            ),
          ),
        ],
      ],
      SizedBox(height: context.space.s4),
      if (s.profile.isStaff || s.profile.pinSet != false)
        Center(
          child: AppButton(
            key: UnlockView.forgotKey,
            label: l10n.unlock_forgot_pin,
            variant: AppButtonVariant.text,
            size: AppButtonSize.s,
            onPressed: () => unawaited(_forgot(l10n)),
          ),
        ),
      Center(
        child: AppButton(
          key: UnlockView.phoneLoginKey,
          label: l10n.unlock_phone_login,
          variant: AppButtonVariant.text,
          size: AppButtonSize.s,
          onPressed: ref.read(unlockProvider.notifier).toPhoneLogin,
        ),
      ),
      Center(
        child: TextButton(
          key: UnlockView.switchKey,
          onPressed: () => unawaited(_switch(l10n)),
          child: Text(l10n.unlock_switch_account, style: context.text.label.copyWith(color: c.textSecondary)),
        ),
      ),
    ];

    final Widget body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
    Widget mascot(BuildContext context, double size) => // money-double: allow — геометрия UI (lp)
        Mascot(controller: _mascot, size: size, renderer: widget.mascotRenderer ?? const PlaceholderMascotRenderer());
    if (widget.mode == UnlockMode.idle) {
      return SingleChildScrollView(
        padding: EdgeInsets.all(context.space.s6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (s.phase != UnlockPhase.offline || MediaQuery.sizeOf(context).height >= 640)
              Center(child: mascot(context, 96)),
            SizedBox(height: context.space.s4),
            body,
          ],
        ),
      );
    }
    return AuthLayout(
      footerYear: now.toLocal().year,
      compactMascotSize: 96,
      mediumMascotSize: 160,
      banners: <Widget>[
        if (s.phase == UnlockPhase.offline)
          ErrorState.banner(message: l10n.unlock_offline, tone: ErrorStateTone.warning),
      ],
      mascot: mascot,
      body: body,
    );
  }
}

/// Аватар (инициалы), ФИО и роль — без телефона (UI-08-003).
class _Identity extends StatelessWidget {
  const _Identity({required this.profile, required this.loaded});

  final SessionProfile profile;
  final bool loaded;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final String? name = profile.displayName;
    final RoleCode? role = profile.primaryRole;
    final String initials = name == null || name.trim().isEmpty
        ? ''
        : name.trim().split(RegExp(r'\s+')).take(2).map((String p) => p.characters.first.toUpperCase()).join();
    return Column(
      children: <Widget>[
        CircleAvatar(
          radius: context.windowClass == WindowClass.compact ? 32 : 40,
          backgroundColor: c.primaryContainer,
          child: initials.isEmpty
              ? Icon(Icons.person_rounded, color: c.primaryText)
              : Text(initials, style: context.text.title.copyWith(color: c.primaryText)),
        ),
        if (name != null && name.isNotEmpty) ...<Widget>[
          SizedBox(height: context.space.s2),
          Text(name, key: UnlockView.nameKey, textAlign: TextAlign.center, style: context.text.title),
        ],
        if (role != null) ...<Widget>[
          SizedBox(height: context.space.s1),
          Text(
            _roleLabel(l10n, role),
            textAlign: TextAlign.center,
            style: context.text.caption.copyWith(color: c.textSecondary),
          ),
        ],
      ],
    );
  }

  static String _roleLabel(AppLocalizations l10n, RoleCode role) => switch (role) {
    RoleCode.seller => l10n.role_seller,
    RoleCode.cashier => l10n.role_cashier,
    RoleCode.seniorSeller => l10n.role_senior_seller,
    RoleCode.admin => l10n.role_admin,
    RoleCode.owner => l10n.role_owner,
    RoleCode.customer => l10n.role_customer,
    RoleCode.integration => l10n.role_integration,
  };
}

class _OrDivider extends StatelessWidget {
  const _OrDivider({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Row(
      children: <Widget>[
        Expanded(child: Divider(color: c.border)),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: context.space.s2),
          child: Text(label, style: context.text.caption.copyWith(color: c.textSecondary)),
        ),
        Expanded(child: Divider(color: c.border)),
      ],
    );
  }
}
