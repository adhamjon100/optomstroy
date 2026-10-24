// UnlockNotifier — SCR-08 «Быстрый вход и разблокировка» (02 SCR-08; 08 §4.1.8; D-13, D-48).
//
// PIN проверяется только сервером (`POST /auth/unlock`); PIN в состоянии не хранится —
// передаётся в use case и забывается. На `PIN_INVALID` `/auth/refresh` не вызывается
// (ядро §18.2 п.5). Офлайн-разблокировки нет (Q-241).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/auth/auth_providers.dart';
import 'package:optomstroy/features/auth/domain/entities/auth_entry_reason.dart';
import 'package:optomstroy/features/auth/domain/entities/session_profile.dart';
import 'package:optomstroy/features/auth/domain/entities/unlock.dart';
import 'package:optomstroy/features/auth/domain/ports/biometric_unlock.dart';
import 'package:optomstroy/features/auth/domain/usecases/unlock_session.dart';
import 'package:optomstroy/features/auth/presentation/mascot/mascot_controller.dart';

/// Фаза ввода PIN.
enum UnlockPhase {
  idle,
  verifying,
  success,

  /// `PIN_INVALID` — точки `error`, `attemptsLeft`.
  invalid,

  /// `PIN_LOCKED` — нампад disabled, «Войти по SMS» (UI-08-011).
  locked,

  /// Сеть/таймаут/5xx — «Повторить», PIN вводится заново.
  failed,

  /// Нет сети — разблокировка недоступна (UI-08-013).
  offline,
}

/// Навигация SCR-08.
sealed class UnlockEffect {
  const UnlockEffect(this.id);

  final int id;
}

/// `200` — `cold`: `go(from | главный экран роли)`; `idle`: снять overlay.
final class UnlockedEffect extends UnlockEffect {
  const UnlockedEffect(super.id, this.profile);

  final SessionProfile profile;
}

/// На SCR-01 (с причиной для UI-01-017 или без).
final class ToPhoneEffect extends UnlockEffect {
  const ToPhoneEffect(super.id, [this.reason]);

  final AuthEntryReason? reason;
}

/// `SESSION_REVOKED` — SCR-90 C «Сессия завершена» → SCR-01.
final class SessionEndedEffect extends UnlockEffect {
  const SessionEndedEffect(super.id);
}

final class UnlockState {
  const UnlockState({
    this.mode = UnlockMode.cold,
    this.profile = SessionProfile.unknown,
    this.profileLoaded = false,
    this.bioKind = BiometricUnlockKind.none,
    this.bioBusy = false,
    this.bioLockedOut = false,
    this.autoPromptDone = false,
    this.helloVerified = false,
    this.biometricInvalidated = false,
    this.phase = UnlockPhase.idle,
    this.attemptsLeft,
    this.failure,
    this.mascot,
    this.mascotSeq = 0,
    this.effect,
  });

  final UnlockMode mode;
  final SessionProfile profile;
  final bool profileLoaded;
  final BiometricUnlockKind bioKind;
  final bool bioBusy;
  final bool bioLockedOut;
  final bool autoPromptDone;

  /// Windows Hello подтвердил присутствие (PIN всё равно обязателен, D-13).
  final bool helloVerified;

  /// Ключ биометрии недоступен — следующий `/auth/unlock` по PIN с `biometricInvalidated=true`.
  final bool biometricInvalidated;
  final UnlockPhase phase;
  final int? attemptsLeft;
  final Failure? failure;
  final MascotSignal? mascot;
  final int mascotSeq;
  final UnlockEffect? effect;

  bool get pinInputEnabled => phase == UnlockPhase.idle || phase == UnlockPhase.invalid;

  bool get showBiometricButton => bioKind == BiometricUnlockKind.cryptoBound;

  bool get showHelloButton => bioKind == BiometricUnlockKind.windowsHelloGate;

  UnlockState copyWith({
    UnlockMode? mode,
    SessionProfile? profile,
    bool? profileLoaded,
    BiometricUnlockKind? bioKind,
    bool? bioBusy,
    bool? bioLockedOut,
    bool? autoPromptDone,
    bool? helloVerified,
    bool? biometricInvalidated,
    UnlockPhase? phase,
    int? Function()? attemptsLeft,
    Failure? Function()? failure,
    MascotSignal? mascot,
    int? mascotSeq,
    UnlockEffect? effect,
  }) => UnlockState(
    mode: mode ?? this.mode,
    profile: profile ?? this.profile,
    profileLoaded: profileLoaded ?? this.profileLoaded,
    bioKind: bioKind ?? this.bioKind,
    bioBusy: bioBusy ?? this.bioBusy,
    bioLockedOut: bioLockedOut ?? this.bioLockedOut,
    autoPromptDone: autoPromptDone ?? this.autoPromptDone,
    helloVerified: helloVerified ?? this.helloVerified,
    biometricInvalidated: biometricInvalidated ?? this.biometricInvalidated,
    phase: phase ?? this.phase,
    attemptsLeft: attemptsLeft == null ? this.attemptsLeft : attemptsLeft(),
    failure: failure == null ? this.failure : failure(),
    mascot: mascot ?? this.mascot,
    mascotSeq: mascotSeq ?? this.mascotSeq,
    effect: effect ?? this.effect,
  );

  @override
  String toString() => 'UnlockState(${mode.value}, ${phase.name})';
}

/// Состояние одного показа SCR-08 (autoDispose: новый показ — новый авто-промпт).
final unlockProvider = NotifierProvider.autoDispose<UnlockNotifier, UnlockState>(UnlockNotifier.new);

final class UnlockNotifier extends Notifier<UnlockState> {
  int _seq = 0;

  @override
  UnlockState build() => const UnlockState();

  UnlockState _signal(UnlockState s, MascotSignal signal) => s.copyWith(mascot: signal, mascotSeq: s.mascotSeq + 1);

  int _nextId() => ++_seq;

  /// Показ экрана: профиль (без телефона) и доступная биометрия.
  Future<void> open(UnlockMode mode) async {
    state = state.copyWith(mode: mode);
    final AuthSessionState session = ref.read(authSessionProvider);
    final SessionProfile profile = session.profile.kind != null
        ? session.profile
        : await ref.read(authRepositoryProvider).cachedProfile();
    final BiometricUnlockKind kind = await ref.read(biometricUnlockProvider).kind();
    if (!ref.mounted) {
      return;
    }
    state = state.copyWith(profile: profile, profileLoaded: true, bioKind: kind);
  }

  /// Сеть пропала/появилась (сигнал `authOfflineSignalProvider` или исход запроса).
  void setOffline(bool offline) {
    if (offline && state.phase != UnlockPhase.verifying && state.phase != UnlockPhase.success) {
      state = _signal(state.copyWith(phase: UnlockPhase.offline), MascotSignal.idle);
    } else if (!offline && state.phase == UnlockPhase.offline) {
      state = state.copyWith(phase: UnlockPhase.idle);
    }
  }

  /// Авто-промпт биометрии через 300 мс после показа — один раз за показ (SCR-08.4 п.2).
  Future<void> autoPrompt() async {
    if (state.autoPromptDone || !state.showBiometricButton) {
      return;
    }
    state = state.copyWith(autoPromptDone: true);
    await biometric();
  }

  /// «Войти по биометрии» / клавиша нампада.
  Future<void> biometric() async {
    if (state.bioBusy || state.bioLockedOut || !state.showBiometricButton || state.phase == UnlockPhase.verifying) {
      return;
    }
    if (state.phase == UnlockPhase.offline || state.phase == UnlockPhase.locked) {
      return;
    }
    state = _signal(state.copyWith(bioBusy: true, autoPromptDone: true), MascotSignal.requestStarted);
    final BiometricUnlockOutcome outcome = await ref.read(unlockWithBiometricProvider).call();
    if (!ref.mounted) {
      return;
    }
    state = state.copyWith(bioBusy: false);
    switch (outcome) {
      case BiometricUnlocked(:final UnlockSuccess result):
        _succeed(result);
      case BiometricUnlockCancelled():
        state = _signal(state, MascotSignal.idle);
      case BiometricUnlockLockedOut():
        state = _signal(state.copyWith(bioLockedOut: true), MascotSignal.idle);
      case BiometricUnlockUnavailable():
        state = _signal(state.copyWith(bioKind: BiometricUnlockKind.none), MascotSignal.idle);
      case BiometricUnlockInvalidated():
        state = _signal(
          state.copyWith(
            bioKind: BiometricUnlockKind.none,
            biometricInvalidated: true,
            effect: ToPhoneEffect(_nextId(), AuthEntryReason.bioInvalidated),
          ),
          MascotSignal.errorBlocking,
        );
      case BiometricUnlockFailed(:final Failure failure):
        _fail(failure);
    }
  }

  /// Windows Hello — UX-гейт: фокус в PIN с подписью «Подтверждено Windows Hello».
  Future<void> helloGate() async {
    if (state.bioBusy || !state.showHelloButton) {
      return;
    }
    state = state.copyWith(bioBusy: true);
    final bool ok = await ref.read(biometricUnlockProvider).confirmPresence();
    if (!ref.mounted) {
      return;
    }
    state = state.copyWith(bioBusy: false, helloVerified: ok);
  }

  /// N-я цифра PIN → `POST /auth/unlock {method: pin}`.
  Future<void> submitPin(String pin) async {
    if (!state.pinInputEnabled) {
      return;
    }
    state = _signal(state.copyWith(phase: UnlockPhase.verifying, failure: () => null), MascotSignal.requestStarted);
    final Result<UnlockSuccess> result = await ref
        .read(unlockWithPinProvider)
        .call(pin, biometricInvalidated: state.biometricInvalidated);
    if (!ref.mounted) {
      return;
    }
    switch (result) {
      case Success<UnlockSuccess>(value: final UnlockSuccess ok):
        state = state.copyWith(biometricInvalidated: false);
        _succeed(ok);
      case FailureResult<UnlockSuccess>(:final Failure failure):
        _fail(failure);
    }
  }

  /// Пользователь снова вводит PIN после ошибки.
  void pinEdited() {
    if (state.phase == UnlockPhase.invalid) {
      state = _signal(state, MascotSignal.idle);
    }
  }

  /// «Повторить» после сетевой ошибки / при появлении сети.
  void retry() {
    if (state.phase == UnlockPhase.failed || state.phase == UnlockPhase.offline) {
      state = _signal(state.copyWith(phase: UnlockPhase.idle, failure: () => null), MascotSignal.retry);
    }
  }

  /// «Забыли PIN?» (после подтверждения) / «Войти по SMS» (`PIN_LOCKED`).
  void toSmsLogin(AuthEntryReason reason) => state = state.copyWith(effect: ToPhoneEffect(_nextId(), reason));

  /// «Войти по номеру телефона» — без выхода: токены живут до успешного входа (UI-08-016).
  void toPhoneLogin() => state = state.copyWith(effect: ToPhoneEffect(_nextId()));

  /// «Сменить аккаунт»: локальная очистка сессии (кроме `deviceId`) и `biometric_refresh`.
  /// Серверный `POST /auth/logout` — RM-D-009 (SessionController).
  Future<void> switchAccount() async {
    await ref.read(authRepositoryProvider).clearLocalSession();
    await ref.read(biometricUnlockProvider).clear();
    if (!ref.mounted) {
      return;
    }
    ref.read(authSessionProvider.notifier).signedOut();
    state = state.copyWith(effect: ToPhoneEffect(_nextId()));
  }

  void _succeed(UnlockSuccess ok) {
    final SessionProfile profile = ok.profile.kind != null ? ok.profile : state.profile;
    ref.read(authSessionProvider.notifier).signedIn(profile);
    state = _signal(
      state.copyWith(phase: UnlockPhase.success, attemptsLeft: () => null, effect: UnlockedEffect(_nextId(), profile)),
      MascotSignal.success,
    );
  }

  void _fail(Failure failure) {
    if (failure is AuthFailure) {
      switch (failure.reason) {
        case AuthReason.pinInvalid:
          state = _signal(
            state.copyWith(
              phase: UnlockPhase.invalid,
              attemptsLeft: () => failure.attemptsLeft,
              failure: () => failure,
            ),
            MascotSignal.errorRecoverable,
          );
          return;
        case AuthReason.pinLocked:
          state = _signal(
            state.copyWith(phase: UnlockPhase.locked, failure: () => failure),
            MascotSignal.errorBlocking,
          );
          return;
        case AuthReason.sessionRevoked || AuthReason.deviceMismatch || AuthReason.unauthenticated:
          ref.read(authSessionProvider.notifier).signedOut();
          state = _signal(
            state.copyWith(phase: UnlockPhase.failed, failure: () => failure, effect: SessionEndedEffect(_nextId())),
            MascotSignal.errorBlocking,
          );
          return;
        default:
          break;
      }
    }
    if (failure is PermissionFailure && failure.serverReason == 'pin_not_set') {
      // PIN не задан: установка PIN возможна только после OTP-входа (SCR-08.4 п.7).
      state = _signal(
        state.copyWith(phase: UnlockPhase.failed, failure: () => failure, effect: ToPhoneEffect(_nextId())),
        MascotSignal.errorBlocking,
      );
      return;
    }
    final bool offline = failure is NetworkFailure && failure.kind == NetworkFailureKind.offline;
    state = _signal(
      state.copyWith(phase: offline ? UnlockPhase.offline : UnlockPhase.failed, failure: () => failure),
      offline ? MascotSignal.idle : MascotSignal.errorBlocking,
    );
  }
}
