// Глобальный слой сессии поверх навигации (02 SCR-90 зоны B, C, C3; SCR-08 overlay; 09 §8.8; RM-D-009).
// Ставится в `MaterialApp.builder` (как AppVersionGate) и делает:
// - SCR-08 overlay при блокировке (холодный старт, idle 30 мин, фон > 5 мин, `Ctrl+L`, `UNLOCK_REQUIRED`):
//   рабочий экран остаётся смонтированным (корзина, формы, прокрутка сохраняются), но не получает ввод,
//   фокус и семантику и размыт (blur 12 + scrim; при reduce-motion — только заливка);
// - StepUpDialog для `403 STEP_UP_REQUIRED` (презентер StepUpCoordinator): compact — нижний лист, иначе диалог;
// - SCR-90 C «Сессия завершена» и C3 «Требуется обновление» (426 — навигация заморожена, G-12);
// - учёт активности (касания, клавиатура, сканер-HID) для idle-таймера и жизненного цикла для блокировки из фона.
// «Назад» (Android) при открытом слое не уходит в навигатор; `Esc` и тап по scrim слой не закрывают.
import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/session_api.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/session/session_overlay.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/core/session/step_up_coordinator.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/session_ui/presentation/widgets/session_ended_dialog.dart';
import 'package:optomstroy/features/session_ui/presentation/widgets/session_lock_overlay.dart';
import 'package:optomstroy/features/session_ui/presentation/widgets/step_up_flow.dart';
import 'package:optomstroy/features/session_ui/presentation/widgets/update_required_view.dart';

/// Экран блокировки, подставляемый вместо PIN-слоя по умолчанию (SCR-08 фичи auth с биометрией).
typedef SessionLockScreenBuilder = Widget Function(BuildContext context, SessionLockReason reason);

class SessionGate extends ConsumerStatefulWidget {
  const SessionGate({
    super.key,
    required this.child,
    this.lockScreenBuilder,
    this.coverColdStart = true,
    this.openStoreUrl,
    this.manualLockShortcut = true,
  });

  static const Key childKey = Key('session-gate-child');
  static const Key scrimKey = Key('session-gate-scrim');

  /// Приложение (навигатор).
  final Widget child;

  /// SCR-08 фичи auth (биометрия + PIN); `null` — [SessionLockOverlay] (PIN).
  final SessionLockScreenBuilder? lockScreenBuilder;

  /// Закрывать холодный старт слоем; `false` — SCR-08 `cold` показывает маршрут `/auth/unlock` (app/router).
  final bool coverColdStart;

  /// Открытие `storeUrl` (SCR-90 C3); `null` — без кнопки «Обновить».
  final Future<void> Function(Uri url)? openStoreUrl;

  /// `Ctrl+L` — ручная блокировка (Windows-POS, 02 §3.5).
  final bool manualLockShortcut;

  @override
  ConsumerState<SessionGate> createState() => _SessionGateState();
}

final class _PendingStepUp {
  _PendingStepUp(this.challenge);

  final StepUpChallenge challenge;
  final Completer<StepUpGrant?> completer = Completer<StepUpGrant?>();
}

final class _ControllerStepUpActions implements StepUpActions {
  _ControllerStepUpActions(this._controller, this._operation);

  final SessionController _controller;
  final String _operation;

  @override
  Future<StepUpResponse> submitPin(String pin) => _controller.stepUpWithPin(_operation, pin);

  @override
  Future<StepUpResponse> requestOtp() => _controller.requestStepUpOtp(_operation);

  @override
  Future<StepUpResponse> submitOtp(String challengeId, String code) =>
      _controller.stepUpWithOtp(_operation, challengeId, code);
}

class _SessionGateState extends ConsumerState<SessionGate> with WidgetsBindingObserver {
  late final StepUpCoordinator _coordinator;
  _PendingStepUp? _stepUp;
  bool _layerShown = false;

  SessionController get _controller => ref.read(sessionControllerProvider.notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_onKey);
    _coordinator = ref.read(stepUpCoordinatorProvider)..attach(_presentStepUp);
  }

  @override
  void dispose() {
    _coordinator.detach(_presentStepUp);
    HardwareKeyboard.instance.removeHandler(_onKey);
    WidgetsBinding.instance.removeObserver(this);
    _completeStepUp(null, rebuild: false);
    super.dispose();
  }

  Future<StepUpGrant?> _presentStepUp(StepUpChallenge challenge) {
    final pending = _stepUp;
    if (pending != null) {
      // Диалог уже открыт для другой операции — второй ждёт закрытия первого (по одной операции).
      return pending.completer.future.then((_) => _presentStepUp(challenge));
    }
    if (!mounted) return Future<StepUpGrant?>.value();
    final next = _PendingStepUp(challenge);
    setState(() => _stepUp = next);
    return next.completer.future;
  }

  void _completeStepUp(StepUpGrant? grant, {bool rebuild = true}) {
    final pending = _stepUp;
    if (pending == null) return;
    if (rebuild && mounted) {
      setState(() => _stepUp = null);
    } else {
      _stepUp = null;
    }
    if (!pending.completer.isCompleted) pending.completer.complete(grant);
  }

  bool _onKey(KeyEvent event) {
    _controller.recordActivity();
    if (!widget.manualLockShortcut || event is! KeyDownEvent) return false;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyL) {
      final session = ref.read(sessionControllerProvider);
      if (session.isAuthenticated && !session.isLocked) {
        _controller.lock(SessionLockReason.manual);
        return true;
      }
    }
    return false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        _controller.appBackgrounded();
      case AppLifecycleState.resumed:
        _controller.appForegrounded();
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  /// Системный «Назад» при открытом слое поглощается (SCR-08: overlay не закрывается, навигатор под ним не меняется).
  @override
  Future<bool> didPopRoute() async => _layerShown;

  @override
  Widget build(BuildContext context) {
    // UI-41-014 (02 SCR-41, ядро §19.4): выход без ответа сервера — локальная очистка выполнена, отзыв сессии
    // отложен (`pending_logout`) → снекбар «Вы вышли. Сессия будет завершена на сервере при подключении» на SCR-01.
    ref.listen<bool>(sessionControllerProvider.select((s) => s.serverLogoutPending), (bool? previous, bool next) {
      if (!next || previous == true) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || ScaffoldMessenger.maybeOf(context) == null) return;
        AppSnackbar.show(context, message: AppLocalizations.of(context).profile_logout_offline_done);
      });
    });
    final overlay = ref.watch(sessionOverlayProvider);
    final coldHidden =
        overlay.kind == SessionOverlayKind.locked &&
        overlay.lockReason == SessionLockReason.coldStart &&
        !widget.coverColdStart;
    final kind = coldHidden ? SessionOverlayKind.none : overlay.kind;
    if (kind != SessionOverlayKind.none && _stepUp != null) {
      // Блокировка / завершение / обновление отменяют открытый step-up (операция остаётся в исходном состоянии).
      final pending = _stepUp!;
      _stepUp = null;
      scheduleMicrotask(() {
        if (!pending.completer.isCompleted) pending.completer.complete(null);
      });
    }
    final layer = _layer(context, kind, overlay);
    _layerShown = layer != null;
    final obscured = kind == SessionOverlayKind.locked || kind == SessionOverlayKind.updateRequired;
    final reduceMotion = context.motion.reduceMotion;
    final app = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _controller.recordActivity(),
      onPointerSignal: (_) => _controller.recordActivity(),
      child: IgnorePointer(
        ignoring: layer != null,
        child: ExcludeFocus(
          excluding: layer != null,
          child: ExcludeSemantics(
            excluding: obscured,
            child: ImageFiltered(
              enabled: obscured && !reduceMotion,
              imageFilter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: KeyedSubtree(key: SessionGate.childKey, child: widget.child),
            ),
          ),
        ),
      ),
    );
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        app,
        if (layer != null) Positioned.fill(child: Overlay.wrap(child: layer)),
      ],
    );
  }

  Widget? _layer(BuildContext context, SessionOverlayKind kind, SessionOverlay overlay) {
    switch (kind) {
      case SessionOverlayKind.updateRequired:
        return UpdateRequiredView(
          minVersion: overlay.minVersion,
          storeUrl: overlay.storeUrl,
          openStoreUrl: widget.openStoreUrl,
        );
      case SessionOverlayKind.sessionEnded:
        return _scrim(
          context,
          SessionEndedDialog(reason: overlay.endReason, onLoginAgain: _controller.acknowledgeEnded),
        );
      case SessionOverlayKind.locked:
        final reason = overlay.lockReason ?? SessionLockReason.manual;
        final builder = widget.lockScreenBuilder;
        return _scrim(context, builder != null ? builder(context, reason) : _defaultLock(reason));
      case SessionOverlayKind.none:
        final pending = _stepUp;
        if (pending == null) return null;
        return _scrim(
          context,
          StepUpFlow(
            key: ObjectKey(pending),
            actions: _ControllerStepUpActions(_controller, pending.challenge.operation),
            allowedMethods: pending.challenge.allowedMethods,
            pinLength: _pinLength(),
            onDone: _completeStepUp,
          ),
        );
    }
  }

  Widget _defaultLock(SessionLockReason reason) => SessionLockOverlay(
    reason: reason,
    pinLength: _pinLength(),
    idleDuration: ref.read(sessionPolicyProvider).idleLock,
    onUnlockWithPin: _controller.unlockWithPin,
    onLeaveToPhoneLogin: (r) => _controller.leaveToPhoneLogin(reason: r),
    onSwitchAccount: _controller.logout,
  );

  /// Длина PIN по политике роли: customer — 4, staff/неизвестно — 6 (09 §9.6; `security.pinLength` — Q).
  int _pinLength() => ref.read(sessionControllerProvider).userKind == UserKind.customer ? 4 : 6;

  Widget _scrim(BuildContext context, Widget child) => Stack(
    fit: StackFit.expand,
    children: <Widget>[
      // Тап по scrim ничего не делает (слой закрывается только своими кнопками).
      ModalBarrier(key: SessionGate.scrimKey, color: context.colors.overlay, dismissible: false),
      child,
    ],
  );
}
