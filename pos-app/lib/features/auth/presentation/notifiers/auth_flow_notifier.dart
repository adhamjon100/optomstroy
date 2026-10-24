// AuthFlowNotifier — поток входа SCR-01 → SCR-02 (02 §0.2–§0.4; 09 §4.4).
//
// Только память процесса: номер, challengeId, сроки, `inFlight`; на диск не пишется ничего
// (телефон пользователя на устройстве не хранится — ядро §19.3). Запросы — только через
// use cases домена; повтор — только явным действием («Повторить», «Отправить повторно»).
// События для персонажа — [AuthFlowState.mascot] (+ счётчик), экран передаёт их
// MascotController; навигация — [AuthFlowState.effect].
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/features/auth/auth_providers.dart';
import 'package:optomstroy/features/auth/domain/entities/auth_entry_reason.dart';
import 'package:optomstroy/features/auth/domain/entities/otp_challenge.dart';
import 'package:optomstroy/features/auth/domain/entities/verify_outcome.dart';
import 'package:optomstroy/features/auth/domain/usecases/request_otp.dart';
import 'package:optomstroy/features/auth/domain/usecases/validate_phone.dart';
import 'package:optomstroy/features/auth/domain/usecases/verify_otp.dart';
import 'package:optomstroy/features/auth/presentation/mascot/mascot_controller.dart';

/// Фаза SCR-02.
enum OtpPhase { idle, verifying, success, invalid, expired, locked, failed, forbidden }

/// Навигация, которую выполняет экран (одноразовое событие с номером [id]).
sealed class AuthFlowEffect {
  const AuthFlowEffect(this.id);

  final int id;
}

/// `202` → SCR-02 (`push`).
final class OpenOtpEffect extends AuthFlowEffect {
  const OpenOtpEffect(super.id);
}

/// Верный код — переход по ветке ответа (после ANIM-005).
final class VerifiedEffect extends AuthFlowEffect {
  const VerifiedEffect(super.id, this.outcome);

  final VerifyOutcome outcome;
}

/// Возврат на SCR-01 с причиной (`DEVICE_MISMATCH`).
final class BackToPhoneEffect extends AuthFlowEffect {
  const BackToPhoneEffect(super.id, this.reason);

  final AuthEntryReason reason;
}

/// Состояние потока (неизменяемое).
final class AuthFlowState {
  const AuthFlowState({
    this.phoneDigits = '',
    this.phoneIssue,
    this.serverRejectedPhone = false,
    this.entryReason,
    this.returnTo,
    this.requesting = false,
    this.requestFailure,
    this.requestBlockedUntil,
    this.blockedPhone,
    this.offline = false,
    this.challenge,
    this.previousChallenge,
    this.usingPreviousChallenge = false,
    this.otpPhase = OtpPhase.idle,
    this.attemptsLeft,
    this.otpLockedUntil,
    this.otpFailure,
    this.hadOtpError = false,
    this.pendingCode,
    this.delivery,
    this.resending = false,
    this.resendFailure,
    this.resendBlockedUntil,
    this.resentCount = 0,
    this.mascot,
    this.mascotSeq = 0,
    this.effect,
  });

  // ---- SCR-01
  /// Национальные цифры (≤ 9) — память.
  final String phoneDigits;

  /// Показанная ошибка поля (после blur/submit).
  final PhoneIssue? phoneIssue;

  /// `VALIDATION_FAILED` по полю phone.
  final bool serverRejectedPhone;

  /// Баннер причины возврата (UI-01-017).
  final AuthEntryReason? entryReason;

  /// Куда вернуться после входа (`returnTo` authGuard; только внутренний путь).
  final String? returnTo;

  /// `POST /auth/otp/request` в полёте (`inFlight`).
  final bool requesting;

  /// Ошибка последнего запроса кода (баннер/снекбар).
  final Failure? requestFailure;

  /// `OTP_RATE_LIMITED`/`OTP_LOCKED` для [blockedPhone] — до этого момента.
  final DateTime? requestBlockedUntil;
  final String? blockedPhone;

  /// Последний запрос не дошёл до сервера (нет сети).
  final bool offline;

  // ---- челлендж
  final OtpChallenge? challenge;

  /// Прежний живой код — резерв, если новый не доставлен (09 §4.4, §5.3).
  final OtpChallenge? previousChallenge;

  /// Новый код не доставлен — используем прежний (`auth_otp_fallback_previous`).
  final bool usingPreviousChallenge;

  // ---- SCR-02
  final OtpPhase otpPhase;
  final int? attemptsLeft;
  final DateTime? otpLockedUntil;
  final Failure? otpFailure;

  /// Была ошибка проверки → на сенсорных устройствах появляется «Подтвердить» (09 §4.4).
  final bool hadOtpError;

  /// Код последней попытки — только после сетевой ошибки, для «Повторить» (02 SCR-02.4).
  final String? pendingCode;
  final OtpDeliveryState? delivery;
  final bool resending;
  final Failure? resendFailure;
  final DateTime? resendBlockedUntil;

  /// Счётчик успешных повторных отправок (снекбар «Код отправлен повторно»).
  final int resentCount;

  // ---- события
  final MascotSignal? mascot;
  final int mascotSeq;
  final AuthFlowEffect? effect;

  /// E.164 текущего ввода или `null`.
  String? get phoneE164 => const ValidatePhone().call(phoneDigits).e164;

  /// Ограничение запроса кода действует для текущего номера.
  bool isRequestBlocked(DateTime now) =>
      requestBlockedUntil != null &&
      now.isBefore(requestBlockedUntil!) &&
      (blockedPhone == null || blockedPhone == phoneE164);

  AuthFlowState copyWith({
    String? phoneDigits,
    PhoneIssue? Function()? phoneIssue,
    bool? serverRejectedPhone,
    AuthEntryReason? Function()? entryReason,
    String? Function()? returnTo,
    bool? requesting,
    Failure? Function()? requestFailure,
    DateTime? Function()? requestBlockedUntil,
    String? Function()? blockedPhone,
    bool? offline,
    OtpChallenge? Function()? challenge,
    OtpChallenge? Function()? previousChallenge,
    bool? usingPreviousChallenge,
    OtpPhase? otpPhase,
    int? Function()? attemptsLeft,
    DateTime? Function()? otpLockedUntil,
    Failure? Function()? otpFailure,
    bool? hadOtpError,
    String? Function()? pendingCode,
    OtpDeliveryState? Function()? delivery,
    bool? resending,
    Failure? Function()? resendFailure,
    DateTime? Function()? resendBlockedUntil,
    int? resentCount,
    MascotSignal? mascot,
    int? mascotSeq,
    AuthFlowEffect? effect,
  }) => AuthFlowState(
    phoneDigits: phoneDigits ?? this.phoneDigits,
    phoneIssue: phoneIssue == null ? this.phoneIssue : phoneIssue(),
    serverRejectedPhone: serverRejectedPhone ?? this.serverRejectedPhone,
    entryReason: entryReason == null ? this.entryReason : entryReason(),
    returnTo: returnTo == null ? this.returnTo : returnTo(),
    requesting: requesting ?? this.requesting,
    requestFailure: requestFailure == null ? this.requestFailure : requestFailure(),
    requestBlockedUntil: requestBlockedUntil == null ? this.requestBlockedUntil : requestBlockedUntil(),
    blockedPhone: blockedPhone == null ? this.blockedPhone : blockedPhone(),
    offline: offline ?? this.offline,
    challenge: challenge == null ? this.challenge : challenge(),
    previousChallenge: previousChallenge == null ? this.previousChallenge : previousChallenge(),
    usingPreviousChallenge: usingPreviousChallenge ?? this.usingPreviousChallenge,
    otpPhase: otpPhase ?? this.otpPhase,
    attemptsLeft: attemptsLeft == null ? this.attemptsLeft : attemptsLeft(),
    otpLockedUntil: otpLockedUntil == null ? this.otpLockedUntil : otpLockedUntil(),
    otpFailure: otpFailure == null ? this.otpFailure : otpFailure(),
    hadOtpError: hadOtpError ?? this.hadOtpError,
    pendingCode: pendingCode == null ? this.pendingCode : pendingCode(),
    delivery: delivery == null ? this.delivery : delivery(),
    resending: resending ?? this.resending,
    resendFailure: resendFailure == null ? this.resendFailure : resendFailure(),
    resendBlockedUntil: resendBlockedUntil == null ? this.resendBlockedUntil : resendBlockedUntil(),
    resentCount: resentCount ?? this.resentCount,
    mascot: mascot ?? this.mascot,
    mascotSeq: mascotSeq ?? this.mascotSeq,
    effect: effect ?? this.effect,
  );

  /// Без номера, кода и токенов (NFR-LOG-001).
  @override
  String toString() => 'AuthFlowState(${phoneDigits.length} digits, requesting: $requesting, otp: ${otpPhase.name})';
}

/// Поток входа живёт между SCR-01 и SCR-02 (не autoDispose: «Изменить номер» возвращает
/// прежний номер и живой челлендж; после входа — [AuthFlowNotifier.reset]).
final authFlowProvider = NotifierProvider<AuthFlowNotifier, AuthFlowState>(AuthFlowNotifier.new);

class AuthFlowNotifier extends Notifier<AuthFlowState> {
  /// Ограничение без `retryAfter` (сервер обязан прислать; запасное значение — cooldown 60 с).
  static const Duration fallbackRetryAfter = Duration(seconds: 60);

  int _seq = 0;

  @override
  AuthFlowState build() => const AuthFlowState();

  Clock get _clock => ref.read(clockProvider);

  DateTime get _now => _clock.nowUtc();

  AuthFlowState _signal(AuthFlowState s, MascotSignal signal) => s.copyWith(mascot: signal, mascotSeq: s.mascotSeq + 1);

  int _nextId() => ++_seq;

  // ------------------------------------------------------------------ SCR-01

  /// Открыт SCR-01 (с причиной возврата из query `reason` и адресом `returnTo`).
  void open({AuthEntryReason? reason, String? returnTo}) {
    state = state.copyWith(
      entryReason: reason == null ? null : () => reason,
      returnTo: returnTo == null ? null : () => returnTo,
    );
  }

  /// Закрыть баннер причины (крестик).
  void dismissEntryReason() => state = state.copyWith(entryReason: () => null);

  /// Ввод в поле: текст «XXX XXX XXX».
  void phoneChanged(String text) {
    final String digits = text.replaceAll(RegExp(r'\D'), '');
    if (digits == state.phoneDigits) {
      return;
    }
    state = state.copyWith(
      phoneDigits: digits,
      phoneIssue: () => null,
      serverRejectedPhone: false,
      // Первый введённый символ закрывает баннер причины (UI-01-017).
      entryReason: digits.isEmpty ? null : () => null,
      requestFailure: state.requestFailure is ValidationFailure ? () => null : null,
    );
  }

  /// Потеря фокуса: полная проверка (кроме пустого поля).
  void phoneBlurred() {
    final PhoneCheck check = ref.read(validatePhoneProvider).call(state.phoneDigits);
    if (check.issue != null && check.issue != PhoneIssue.empty) {
      state = state.copyWith(phoneIssue: () => check.issue);
    }
  }

  /// «Получить код» (тап, `Enter`): один запрос в полёте (`inFlight`).
  Future<void> requestOtp() async {
    if (state.requesting) {
      return;
    }
    final PhoneCheck check = ref.read(validatePhoneProvider).call(state.phoneDigits);
    final String? e164 = check.e164;
    if (e164 == null) {
      state = _signal(state.copyWith(phoneIssue: () => check.issue), MascotSignal.errorRecoverable);
      return;
    }
    if (state.isRequestBlocked(_now)) {
      return;
    }
    final bool reuse = state.challenge?.phoneE164 == e164 && (state.challenge?.isAliveAt(_now) ?? false);
    state = state.copyWith(requesting: true, requestFailure: () => null);
    if (!reuse) {
      state = _signal(state, MascotSignal.requestStarted);
    }
    final Result<OtpRequested> result = await ref
        .read(requestOtpProvider)
        .call(phoneE164: e164, current: state.challenge);
    if (!ref.mounted) {
      return;
    }
    switch (result) {
      case Success<OtpRequested>(value: final OtpRequested ok):
        AuthFlowState next = state.copyWith(requesting: false, offline: false, requestBlockedUntil: () => null);
        if (!ok.reused) {
          next = _freshChallenge(next, ok.challenge, previous: null);
        }
        state = next.copyWith(effect: OpenOtpEffect(_nextId()));
      case FailureResult<OtpRequested>(:final Failure failure):
        state = _requestFailed(state.copyWith(requesting: false), failure, e164);
    }
  }

  AuthFlowState _requestFailed(AuthFlowState s, Failure failure, String e164) {
    if (failure is AuthFailure &&
        (failure.reason == AuthReason.otpRateLimited || failure.reason == AuthReason.otpLocked)) {
      return _signal(
        s.copyWith(
          requestFailure: () => failure,
          requestBlockedUntil: () => _now.add(failure.retryAfter ?? fallbackRetryAfter),
          blockedPhone: () => e164,
          offline: false,
        ),
        MascotSignal.errorBlocking,
      );
    }
    if (failure is ValidationFailure) {
      return _signal(
        s.copyWith(serverRejectedPhone: true, requestFailure: () => failure, offline: false),
        MascotSignal.errorRecoverable,
      );
    }
    final bool offline = failure is NetworkFailure && failure.kind == NetworkFailureKind.offline;
    return _signal(s.copyWith(requestFailure: () => failure, offline: offline), MascotSignal.errorBlocking);
  }

  /// «Повторить» в баннере ошибки — тот же номер.
  Future<void> retryRequest() async {
    state = _signal(state.copyWith(requestFailure: () => null), MascotSignal.retry);
    await requestOtp();
  }

  // ------------------------------------------------------------------ SCR-02

  AuthFlowState _freshChallenge(AuthFlowState s, OtpChallenge challenge, {required OtpChallenge? previous}) =>
      s.copyWith(
        challenge: () => challenge,
        previousChallenge: () => previous,
        usingPreviousChallenge: false,
        otpPhase: OtpPhase.idle,
        attemptsLeft: () => null,
        otpLockedUntil: () => null,
        otpFailure: () => null,
        pendingCode: () => null,
        delivery: () => null,
        resendFailure: () => null,
        resendBlockedUntil: () => null,
      );

  /// Пользователь меняет цифры кода: снимается текст ошибки (до следующего ввода).
  void codeEdited() {
    final OtpPhase p = state.otpPhase;
    if (p == OtpPhase.invalid || p == OtpPhase.failed) {
      state = _signal(
        state.copyWith(otpPhase: OtpPhase.idle, otpFailure: () => null, pendingCode: () => null),
        MascotSignal.idle,
      );
    }
  }

  /// Срок кода истёк по таймеру экрана.
  void markExpiredIfNeeded() {
    final OtpChallenge? c = state.challenge;
    if (c == null || c.isAliveAt(_now)) {
      return;
    }
    final OtpPhase p = state.otpPhase;
    if (p == OtpPhase.idle || p == OtpPhase.invalid || p == OtpPhase.failed) {
      state = state.copyWith(otpPhase: OtpPhase.expired, pendingCode: () => null);
    }
  }

  /// `POST /auth/otp/verify` (автоотправка на 6-й цифре, «Подтвердить», `Enter`).
  Future<void> verify(String code) async {
    final OtpChallenge? challenge = state.challenge;
    final OtpPhase phase = state.otpPhase;
    if (challenge == null ||
        phase == OtpPhase.verifying ||
        phase == OtpPhase.success ||
        phase == OtpPhase.locked ||
        phase == OtpPhase.forbidden) {
      return;
    }
    if (!challenge.isAliveAt(_now)) {
      state = _signal(state.copyWith(otpPhase: OtpPhase.expired), MascotSignal.errorBlocking);
      return;
    }
    if (!VerifyOtp.isWellFormed(code, length: challenge.codeLength)) {
      return;
    }
    state = _signal(
      state.copyWith(otpPhase: OtpPhase.verifying, otpFailure: () => null, pendingCode: () => code),
      MascotSignal.requestStarted,
    );
    final Result<VerifyOutcome> result = await ref.read(verifyOtpProvider).call(challenge: challenge, code: code);
    if (!ref.mounted) {
      return;
    }
    switch (result) {
      case Success<VerifyOutcome>(value: final VerifyOutcome outcome):
        _publishSession(outcome);
        state = _signal(
          state.copyWith(
            otpPhase: OtpPhase.success,
            pendingCode: () => null,
            effect: VerifiedEffect(_nextId(), outcome),
          ),
          MascotSignal.success,
        );
      case FailureResult<VerifyOutcome>(:final Failure failure):
        state = _verifyFailed(failure);
    }
  }

  void _publishSession(VerifyOutcome outcome) {
    final AuthSessionNotifier session = ref.read(authSessionProvider.notifier);
    switch (outcome) {
      case VerifyAuthenticated():
        if (outcome.mustSetPin) {
          session.pinSetupRequired(outcome.profile);
        } else {
          session.signedIn(outcome.profile);
        }
      case VerifyPendingActivation(:final profile):
        session.pendingActivation(profile);
      case VerifyRegistrationRequired(:final ticket):
        ref.read(registrationTicketProvider.notifier).set(ticket);
    }
  }

  AuthFlowState _verifyFailed(Failure failure) {
    final AuthFlowState s = state.copyWith(otpFailure: () => failure);
    if (failure is AuthFailure) {
      switch (failure.reason) {
        case AuthReason.otpInvalid:
          return _signal(
            s.copyWith(
              otpPhase: OtpPhase.invalid,
              attemptsLeft: () => failure.attemptsLeft,
              hadOtpError: true,
              pendingCode: () => null,
            ),
            MascotSignal.errorRecoverable,
          );
        case AuthReason.otpExpired:
          return _signal(s.copyWith(otpPhase: OtpPhase.expired, pendingCode: () => null), MascotSignal.errorBlocking);
        case AuthReason.otpLocked:
          return _signal(
            s.copyWith(
              otpPhase: OtpPhase.locked,
              otpLockedUntil: () => _now.add(failure.retryAfter ?? fallbackRetryAfter),
              pendingCode: () => null,
            ),
            MascotSignal.errorBlocking,
          );
        case AuthReason.deviceMismatch:
          return _signal(
            s.copyWith(
              otpPhase: OtpPhase.failed,
              pendingCode: () => null,
              challenge: () => null,
              previousChallenge: () => null,
              entryReason: () => AuthEntryReason.deviceMismatch,
              effect: BackToPhoneEffect(_nextId(), AuthEntryReason.deviceMismatch),
            ),
            MascotSignal.errorBlocking,
          );
        default:
          break;
      }
    }
    if (failure is ServerFailure && failure.code == 'NOT_FOUND') {
      return _signal(s.copyWith(otpPhase: OtpPhase.expired, pendingCode: () => null), MascotSignal.errorBlocking);
    }
    if (failure is PermissionFailure) {
      return _signal(s.copyWith(otpPhase: OtpPhase.forbidden, pendingCode: () => null), MascotSignal.errorBlocking);
    }
    // Сеть, таймаут, 5xx: код сохраняется для «Повторить» (тот же challengeId и код).
    final bool keepCode = failure is NetworkFailure;
    return _signal(
      s.copyWith(otpPhase: OtpPhase.failed, hadOtpError: true, pendingCode: keepCode ? null : () => null),
      MascotSignal.errorBlocking,
    );
  }

  /// «Повторить» после сетевой ошибки — тот же код.
  Future<void> retryVerify() async {
    final String? code = state.pendingCode;
    if (code == null) {
      return;
    }
    state = _signal(state.copyWith(otpPhase: OtpPhase.idle), MascotSignal.retry);
    await verify(code);
  }

  /// «Отправить код повторно» → новый challengeId; прежний — резерв до своего срока.
  Future<void> resend() async {
    final OtpChallenge? current = state.challenge;
    if (current == null || state.resending || state.otpPhase == OtpPhase.verifying) {
      return;
    }
    final DateTime now = _now;
    if (state.resendBlockedUntil != null && now.isBefore(state.resendBlockedUntil!)) {
      return;
    }
    if (state.otpLockedUntil != null && now.isBefore(state.otpLockedUntil!)) {
      return;
    }
    final bool resendOpen =
        current.canResendAt(now) ||
        !current.isAliveAt(now) ||
        state.delivery == OtpDeliveryState.failed ||
        state.otpPhase == OtpPhase.locked ||
        state.otpPhase == OtpPhase.expired;
    if (!resendOpen) {
      return;
    }
    state = _signal(state.copyWith(resending: true, resendFailure: () => null), MascotSignal.retry);
    final Result<OtpRequested> result = await ref
        .read(requestOtpProvider)
        .call(phoneE164: current.phoneE164, current: current, force: true);
    if (!ref.mounted) {
      return;
    }
    switch (result) {
      case Success<OtpRequested>(value: final OtpRequested ok):
        final OtpChallenge? previous = current.isAliveAt(_now) && state.otpPhase != OtpPhase.locked ? current : null;
        state = _freshChallenge(
          state.copyWith(resending: false, resentCount: state.resentCount + 1, offline: false),
          ok.challenge,
          previous: previous,
        );
      case FailureResult<OtpRequested>(:final Failure failure):
        final bool limited =
            failure is AuthFailure &&
            (failure.reason == AuthReason.otpRateLimited || failure.reason == AuthReason.otpLocked);
        state = _signal(
          state.copyWith(
            resending: false,
            resendFailure: () => failure,
            resendBlockedUntil: limited ? () => _now.add(failure.retryAfter ?? fallbackRetryAfter) : null,
          ),
          MascotSignal.errorBlocking,
        );
    }
  }

  /// Опрос `GET /auth/otp/challenges/{id}` (раз в 3 с, ≤ 30 с — таймер экрана).
  /// Ошибка запроса статуса скрывает строку доставки и не блокирует ввод (UI-02-016).
  Future<void> pollDelivery() async {
    final OtpChallenge? c = state.challenge;
    if (c == null) {
      return;
    }
    final Result<OtpChallengeStatus> result = await ref.read(otpDeliveryStatusProvider).call(c.challengeId);
    if (!ref.mounted || state.challenge?.challengeId != c.challengeId) {
      return;
    }
    switch (result) {
      case Success<OtpChallengeStatus>(value: final OtpChallengeStatus s):
        OtpChallenge challenge = c;
        if (s.resendAfterSec != null) {
          challenge = c.withResendAvailableAt(_now.add(Duration(seconds: s.resendAfterSec!)));
        }
        final OtpChallenge? previous = state.previousChallenge;
        if (s.delivery == OtpDeliveryState.failed && previous != null && previous.isAliveAt(_now)) {
          // Новый код не доставлен — возвращаемся к прежнему (09 §4.4, §5.3).
          state = state.copyWith(
            challenge: () => previous,
            previousChallenge: () => null,
            usingPreviousChallenge: true,
            delivery: () => s.delivery,
          );
          return;
        }
        state = state.copyWith(challenge: () => challenge, delivery: () => s.delivery);
      case FailureResult<OtpChallengeStatus>():
        state = state.copyWith(delivery: () => null);
    }
  }

  /// Поток завершён (вход выполнен / выход): память очищается.
  void reset() {
    state = const AuthFlowState();
  }
}
