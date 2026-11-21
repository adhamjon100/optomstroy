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

/// Строка результата UI-08-018 (02 SCR-08.3 п. 18; 15 ADR-116; 09 §9.3): на месте подсказки PIN `unlock_pin_hint`,
/// держится до успешного PIN или нового нажатия кнопки входа UI-08-004; пока видна ошибка PIN (UI-08-007), строки
/// нет. Каждое значение ведёт к вводу PIN (фокус в поле PIN). Цвет `error` — только у [helloFailed], остальные —
/// `textSecondary` (02 SCR-08.3, столбец «Состояния»).
enum UnlockNotice {
  /// Windows Hello подтвердил присутствие (W1): «Подтверждено Windows Hello · введите PIN» — сессию не открывает
  /// (D-13, BIO-005).
  helloVerified,

  /// Отмена, ошибка или отказ Windows Hello (W1); W2 — отмена диалога и `UNLOCK_REQUIRED hello_key_invalid`
  /// (09 BIO-034, BIO-039).
  helloFailed,

  /// W2: `UNLOCK_REQUIRED hello_key_unavailable` — ключ отозван или запрещён сервером.
  helloKeyUnavailable,

  /// W2: ключ Windows Hello пропал в Windows — PIN с `helloKeyInvalidated: true`.
  helloKeyLost,

  /// Уровень W: `UNLOCK_REQUIRED bio_weak_pin_due` — раз в сутки нужен PIN (09 BIO-031).
  bioPinDue,

  /// Уровень W: `UNLOCK_REQUIRED bio_weak_disabled` — вход по лицу выключен (09 BIO-032).
  bioWeakDisabled;

  /// Неудача — цвет `error` (02 UI-08-018).
  bool get isError => this == UnlockNotice.helloFailed;
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
    this.bioPinDue = false,
    this.notice,
    this.biometricInvalidated = false,
    this.helloKeyInvalidated = false,
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

  /// Уровень W: сервер ответил `UNLOCK_REQUIRED bio_weak_pin_due` (09 BIO-031) — кнопка лица, клавиша «Биометрия» и
  /// автодиалог скрыты до успешного PIN этого показа (без цикла автодиалога; 02 SCR-08.4 п. 10). Секрет сохранён.
  final bool bioPinDue;

  /// Строка результата UI-08-018; `null` — подсказка «Введите PIN-код приложения».
  final UnlockNotice? notice;

  /// Ключ биометрии недоступен — следующий `/auth/unlock` по PIN с `biometricInvalidated=true`.
  final bool biometricInvalidated;

  /// Ключ Windows Hello пропал в Windows — следующий `/auth/unlock` по PIN с `helloKeyInvalidated=true` (W2; 09 §9.2
  /// W2 п. 4): сервер отзывает ключ устройства.
  final bool helloKeyInvalidated;
  final UnlockPhase phase;
  final int? attemptsLeft;
  final Failure? failure;
  final MascotSignal? mascot;
  final int mascotSeq;
  final UnlockEffect? effect;

  bool get pinInputEnabled => phase == UnlockPhase.idle || phase == UnlockPhase.invalid;

  /// «Войти по биометрии» (уровень S) / «Войти по лицу или отпечатку» (уровень W; 09 BIO-036) и клавиша нампада;
  /// после `bio_weak_pin_due` — скрыты до успешного PIN.
  bool get showBiometricButton =>
      (bioKind == BiometricUnlockKind.cryptoBound || bioKind == BiometricUnlockKind.weakBound) && !bioPinDue;

  bool get showHelloButton => bioKind == BiometricUnlockKind.windowsHelloGate;

  /// «Войти через Windows Hello» — ключ Windows Hello (W2), вход без PIN.
  bool get showHelloKeyButton => bioKind == BiometricUnlockKind.windowsHelloKey;

  UnlockState copyWith({
    UnlockMode? mode,
    SessionProfile? profile,
    bool? profileLoaded,
    BiometricUnlockKind? bioKind,
    bool? bioBusy,
    bool? bioLockedOut,
    bool? autoPromptDone,
    bool? bioPinDue,
    UnlockNotice? Function()? notice,
    bool? biometricInvalidated,
    bool? helloKeyInvalidated,
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
    bioPinDue: bioPinDue ?? this.bioPinDue,
    notice: notice == null ? this.notice : notice(),
    biometricInvalidated: biometricInvalidated ?? this.biometricInvalidated,
    helloKeyInvalidated: helloKeyInvalidated ?? this.helloKeyInvalidated,
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

  /// Авто-промпт биометрии через 300 мс после показа — один раз за показ (SCR-08.4 п.2); уровни S и W (п. 10). После
  /// `bio_weak_pin_due` кнопка скрыта — повторного автодиалога нет до успешного PIN.
  Future<void> autoPrompt() async {
    if (state.autoPromptDone || !state.showBiometricButton) {
      return;
    }
    state = state.copyWith(autoPromptDone: true);
    await biometric();
  }

  /// «Войти по биометрии» / «Войти по лицу или отпечатку» / клавиша нампада.
  Future<void> biometric() async {
    if (state.bioBusy ||
        state.bioLockedOut ||
        !state.showBiometricButton ||
        state.phase == UnlockPhase.verifying ||
        state.phase == UnlockPhase.success) {
      return;
    }
    if (state.phase == UnlockPhase.offline || state.phase == UnlockPhase.locked) {
      return;
    }
    // Новое нажатие UI-08-004 снимает прежнюю строку результата UI-08-018.
    state = _signal(
      state.copyWith(bioBusy: true, autoPromptDone: true, notice: () => null),
      MascotSignal.requestStarted,
    );
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
      case BiometricUnlockPinDue():
        // Уровень W, раз в сутки нужен PIN (09 BIO-031): секрет сохранён, кнопка лица и автодиалог скрыты до успешного
        // PIN этого показа; строка UI-08-018, фокус в PIN.
        state = _signal(state.copyWith(bioPinDue: true, notice: () => UnlockNotice.bioPinDue), MascotSignal.idle);
      case BiometricUnlockWeakDisabled():
        // Уровень W выключен сервером (09 BIO-032): секрет удалён use case — кнопки нет, строка UI-08-018, поле PIN.
        state = _signal(
          state.copyWith(bioKind: BiometricUnlockKind.none, notice: () => UnlockNotice.bioWeakDisabled),
          MascotSignal.idle,
        );
      case BiometricUnlockFailed(:final Failure failure):
        _fail(failure);
    }
  }

  /// Windows Hello — UX-гейт перед PIN (W1; D-13, 09 BIO-005, BIO-034; 02 SCR-08.4): диалог только по нажатию
  /// (автовызова нет), во время диалога персонаж `verifying`. Исход — строка UI-08-018: `Verified` →
  /// [UnlockNotice.helloVerified], отмена, ошибка или отказ → [UnlockNotice.helloFailed]; экран ставит фокус в PIN.
  /// Сам по себе `Verified` сессию не открывает: `/auth/unlock` без PIN не вызывается.
  Future<void> helloGate() async {
    if (state.bioBusy || !state.showHelloButton) {
      return;
    }
    if (state.phase == UnlockPhase.verifying ||
        state.phase == UnlockPhase.success ||
        state.phase == UnlockPhase.offline ||
        state.phase == UnlockPhase.locked) {
      return;
    }
    // Новое нажатие: прежняя строка снимается; ошибка прошлого PIN (UI-08-007) уступает место исходу Windows Hello,
    // ввод PIN снова доступен (как «Повторить»).
    final bool pinErrorShown = state.phase == UnlockPhase.invalid || state.phase == UnlockPhase.failed;
    state = _signal(
      state.copyWith(
        bioBusy: true,
        notice: () => null,
        phase: pinErrorShown ? UnlockPhase.idle : null,
        attemptsLeft: pinErrorShown ? () => null : null,
        failure: pinErrorShown ? () => null : null,
      ),
      MascotSignal.requestStarted,
    );
    final bool ok = await ref.read(biometricUnlockProvider).confirmPresence();
    if (!ref.mounted) {
      return;
    }
    state = _signal(
      state.copyWith(bioBusy: false, notice: () => ok ? UnlockNotice.helloVerified : UnlockNotice.helloFailed),
      MascotSignal.idle,
    );
  }

  /// «Войти через Windows Hello» — ключ Windows Hello, вход без PIN (W2; 15 ADR-116 п. 3; 09 BIO-039; 02 SCR-08.4
  /// «Windows Hello»): только по нажатию (автовызова нет — окно должно быть в фокусе), кнопка `loading` и персонаж
  /// `verifying` до ответа `POST /auth/unlock {method: hello_key}`. Успех — переход без PIN. Иначе строка UI-08-018 и
  /// поле PIN: отмена диалога и `hello_key_invalid` — [UnlockNotice.helloFailed]; `hello_key_unavailable` —
  /// [UnlockNotice.helloKeyUnavailable], признак ключа снят, кнопка — по новому виду (гейт W1, если включён); ключ
  /// пропал в Windows — [UnlockNotice.helloKeyLost], следующий PIN — с `helloKeyInvalidated`. Ошибка сети или
  /// сессии — как у PIN.
  Future<void> helloKey() async {
    if (state.bioBusy || !state.showHelloKeyButton) {
      return;
    }
    if (state.phase == UnlockPhase.verifying ||
        state.phase == UnlockPhase.success ||
        state.phase == UnlockPhase.offline ||
        state.phase == UnlockPhase.locked) {
      return;
    }
    // Как у гейта: прежняя строка и ошибка прошлого PIN снимаются.
    final bool pinErrorShown = state.phase == UnlockPhase.invalid || state.phase == UnlockPhase.failed;
    state = _signal(
      state.copyWith(
        bioBusy: true,
        notice: () => null,
        phase: pinErrorShown ? UnlockPhase.idle : null,
        attemptsLeft: pinErrorShown ? () => null : null,
        failure: pinErrorShown ? () => null : null,
      ),
      MascotSignal.requestStarted,
    );
    final HelloKeyUnlockOutcome outcome = await ref.read(unlockWithHelloKeyProvider).call();
    if (!ref.mounted) {
      return;
    }
    state = state.copyWith(bioBusy: false);
    switch (outcome) {
      case HelloKeyUnlocked(:final UnlockSuccess result):
        _succeed(result);
      case HelloKeyUnlockRejected():
        state = _signal(state.copyWith(notice: () => UnlockNotice.helloFailed), MascotSignal.idle);
      case HelloKeyUnlockUnavailable():
        await _afterKeyRemoved(UnlockNotice.helloKeyUnavailable);
      case HelloKeyUnlockKeyLost():
        state = state.copyWith(helloKeyInvalidated: true);
        await _afterKeyRemoved(UnlockNotice.helloKeyLost);
      case HelloKeyUnlockFailed(:final Failure failure):
        _fail(failure);
    }
  }

  /// Признак ключа снят — кнопка по новому виду порта (гейт W1, если его включил этот пользователь), строка [notice].
  Future<void> _afterKeyRemoved(UnlockNotice notice) async {
    final BiometricUnlockKind kind = await ref.read(biometricUnlockProvider).kind();
    if (!ref.mounted) {
      return;
    }
    state = _signal(
      state.copyWith(
        bioKind: kind == BiometricUnlockKind.windowsHelloKey ? BiometricUnlockKind.none : kind,
        notice: () => notice,
      ),
      MascotSignal.idle,
    );
  }

  /// N-я цифра PIN → `POST /auth/unlock {method: pin}`.
  Future<void> submitPin(String pin) async {
    if (!state.pinInputEnabled) {
      return;
    }
    state = _signal(state.copyWith(phase: UnlockPhase.verifying, failure: () => null), MascotSignal.requestStarted);
    final Result<UnlockSuccess> result = await ref
        .read(unlockWithPinProvider)
        .call(pin, biometricInvalidated: state.biometricInvalidated, helloKeyInvalidated: state.helloKeyInvalidated);
    if (!ref.mounted) {
      return;
    }
    switch (result) {
      case Success<UnlockSuccess>(value: final UnlockSuccess ok):
        // Успешный PIN продлевает срок уровня W на сервере (09 BIO-031) — кнопка лица снова видна (02 SCR-08.4 п. 10).
        state = state.copyWith(biometricInvalidated: false, helloKeyInvalidated: false, bioPinDue: false);
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
      state.copyWith(
        phase: UnlockPhase.success,
        attemptsLeft: () => null,
        notice: () => null,
        effect: UnlockedEffect(_nextId(), profile),
      ),
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
