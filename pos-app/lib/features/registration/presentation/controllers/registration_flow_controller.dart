// Состояние потока SCR-03 «Данные» → SCR-04 «Защита входа» → шаг «Готово» (09 §7; 02 SCR-03, SCR-04).
// PIN и `registration_token` — только в памяти этого контроллера/провайдера; черновик без PIN —
// через [RegistrationDraftRepository]. Флаг «в полёте» исключает двойной запрос (02 §0.2).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/registration/domain/entities/registration_entities.dart';
import 'package:optomstroy/features/registration/domain/repositories/registration_repositories.dart';
import 'package:optomstroy/features/registration/domain/usecases/registration_usecases.dart';
import 'package:optomstroy/features/registration/domain/usecases/registration_validation.dart';
import 'package:optomstroy/features/registration/registration_providers.dart';

/// Этап ввода PIN (UI-04-008 → UI-04-009).
enum PinStage { create, confirm, done }

/// Ошибка PIN под полем.
enum PinErrorKind { weak, mismatch }

/// Фаза экрана SCR-04.
enum SecurityPhase {
  /// Выбор способов и ввод PIN.
  editing,

  /// Идёт `POST /registration/complete` / `POST /me/pin`.
  submitting,

  /// После `201`: включение биометрии (системный диалог).
  bioSetup,

  /// Сервер требует step-up для `POST /me/biometrics` — диалог PIN.
  stepUp,

  /// Клиент выбрал только биометрию, она не включилась — нужен PIN (02 AC-UI-04-021).
  needPin,

  /// Шаг «Готово».
  done,
}

/// Ошибка отправки (баннер UI-04-016).
enum SubmitErrorKind { network, server, readOnly }

/// Однократные события для экрана (навигация, диалоги, снекбары).
sealed class RegistrationEffect {
  const RegistrationEffect();
}

/// Время регистрации истекло (`REGISTRATION_TOKEN_INVALID` / таймер) — диалог UI-03-012 → SCR-01.
final class ExpiredEffect extends RegistrationEffect {
  const ExpiredEffect();
}

/// Возврат на SCR-01 (`PHONE_ALREADY_REGISTERED`).
final class ToPhoneEffect extends RegistrationEffect {
  const ToPhoneEffect(this.reason);

  final RegistrationExitReason reason;
}

/// Возврат на SCR-03 с подсветкой (VALIDATION_FAILED профиля, CONSENT_REQUIRED).
final class ToFormEffect extends RegistrationEffect {
  const ToFormEffect();
}

/// Снекбар «Биометрия не включена…» (`reg_bio_not_enabled`).
final class BioNotEnabledEffect extends RegistrationEffect {
  const BioNotEnabledEffect();
}

final class RegistrationFlowState {
  const RegistrationFlowState({
    this.audience = RegistrationAudience.customer,
    this.loaded = false,
    this.draft = const RegistrationDraft(),
    this.restored = false,
    this.formSubmitted = false,
    this.serverFieldErrors = const <String, String>{},
    this.consentServerError = false,
    this.otherSphereText = '',
    this.pinEnabled = true,
    this.pinStage = PinStage.create,
    this.pinError,
    this.pinResetCounter = 0,
    this.bioEnabled = false,
    this.bioConsent = false,
    this.bioOption,
    this.protectionError = false,
    this.phase = SecurityPhase.editing,
    this.submitError,
    this.submitRequestId,
    this.outcome,
    this.bioResult,
    this.stepUpAttemptsLeft,
    this.stepUpError = false,
    this.effect,
  });

  final RegistrationAudience audience;
  final bool loaded;
  final RegistrationDraft draft;

  /// Баннер «Мы восстановили…» (UI-03-017).
  final bool restored;

  /// После попытки «Продолжить» ошибки показываются под всеми полями.
  final bool formSubmitted;

  /// Ошибки полей от сервера (`errors[].field` → `rule`), показываются на SCR-03.
  final Map<String, String> serverFieldErrors;
  final bool consentServerError;

  /// Уточнение «Другое» — только память (в API не передаётся: Q-203, D_spec_questions RM-D-008).
  final String otherSphereText;

  /// Клиент: переключатель «PIN-код приложения» (вкл. по умолчанию).
  final bool pinEnabled;
  final PinStage pinStage;
  final PinErrorKind? pinError;

  /// Меняется при каждой очистке полей PIN (ключ виджета).
  final int pinResetCounter;

  final bool bioEnabled;
  final bool bioConsent;

  /// `null` — доступность ещё проверяется (≤ 300 мс, чип `loading`).
  final BiometricOption? bioOption;

  /// «Выберите способ защиты входа…» (`reg_protection_required`).
  final bool protectionError;

  final SecurityPhase phase;
  final SubmitErrorKind? submitError;
  final String? submitRequestId;
  final RegistrationOutcome? outcome;
  final BiometricEnrollmentResult? bioResult;
  final int? stepUpAttemptsLeft;
  final bool stepUpError;
  final RegistrationEffect? effect;

  PinPolicy get pinPolicy => PinPolicy.of(audience);

  /// PIN обязателен: сотрудник; клиент без доступной биометрии или после неудачного включения.
  bool get pinRequired =>
      pinPolicy.mandatory ||
      phase == SecurityPhase.needPin ||
      (bioOption != null && bioOption != BiometricOption.cryptoLogin);

  /// PIN участвует в регистрации.
  bool get pinActive => pinRequired || pinEnabled;

  /// Плитка биометрии интерактивна.
  bool get bioSelectable => bioOption == BiometricOption.cryptoLogin || bioOption == BiometricOption.windowsHelloGate;

  bool get busy => phase == SecurityPhase.submitting || phase == SecurityPhase.bioSetup;

  RegistrationFlowState copyWith({
    RegistrationAudience? audience,
    bool? loaded,
    RegistrationDraft? draft,
    bool? restored,
    bool? formSubmitted,
    Map<String, String>? serverFieldErrors,
    bool? consentServerError,
    String? otherSphereText,
    bool? pinEnabled,
    PinStage? pinStage,
    PinErrorKind? pinError,
    bool clearPinError = false,
    int? pinResetCounter,
    bool? bioEnabled,
    bool? bioConsent,
    BiometricOption? bioOption,
    bool? protectionError,
    SecurityPhase? phase,
    SubmitErrorKind? submitError,
    String? submitRequestId,
    bool clearSubmitError = false,
    RegistrationOutcome? outcome,
    BiometricEnrollmentResult? bioResult,
    int? stepUpAttemptsLeft,
    bool? stepUpError,
    RegistrationEffect? effect,
    bool clearEffect = false,
  }) => RegistrationFlowState(
    audience: audience ?? this.audience,
    loaded: loaded ?? this.loaded,
    draft: draft ?? this.draft,
    restored: restored ?? this.restored,
    formSubmitted: formSubmitted ?? this.formSubmitted,
    serverFieldErrors: serverFieldErrors ?? this.serverFieldErrors,
    consentServerError: consentServerError ?? this.consentServerError,
    otherSphereText: otherSphereText ?? this.otherSphereText,
    pinEnabled: pinEnabled ?? this.pinEnabled,
    pinStage: pinStage ?? this.pinStage,
    pinError: clearPinError ? null : (pinError ?? this.pinError),
    pinResetCounter: pinResetCounter ?? this.pinResetCounter,
    bioEnabled: bioEnabled ?? this.bioEnabled,
    bioConsent: bioConsent ?? this.bioConsent,
    bioOption: bioOption ?? this.bioOption,
    protectionError: protectionError ?? this.protectionError,
    phase: phase ?? this.phase,
    submitError: clearSubmitError ? null : (submitError ?? this.submitError),
    submitRequestId: clearSubmitError ? null : (submitRequestId ?? this.submitRequestId),
    outcome: outcome ?? this.outcome,
    bioResult: bioResult ?? this.bioResult,
    stepUpAttemptsLeft: stepUpAttemptsLeft ?? this.stepUpAttemptsLeft,
    stepUpError: stepUpError ?? this.stepUpError,
    effect: clearEffect ? null : (effect ?? this.effect),
  );
}

final registrationFlowProvider = NotifierProvider<RegistrationFlowController, RegistrationFlowState>(
  RegistrationFlowController.new,
);

final class RegistrationFlowController extends Notifier<RegistrationFlowState> {
  /// PIN первого прохода и подтверждённый PIN — только память; обнуляются после отправки/ухода.
  String? _pinFirst;
  String? _pin;

  /// `Idempotency-Key` и отпечаток тела, к которому он относится (02 SCR-04.4 п. 2: ключ меняется только
  /// при изменении тела; переживает «Повторить», не переживает перезапуск).
  String? _idempotencyKey;
  int? _keyFingerprint;

  bool _inFlight = false;
  String? _stepUpToken;
  Timer? _saveTimer;
  Timer? _retryTimer;

  RegistrationDraftRepository get _drafts => ref.read(registrationDraftRepositoryProvider);
  RegistrationRepository get _repo => ref.read(registrationRepositoryProvider);

  @override
  RegistrationFlowState build() {
    ref.onDispose(() {
      _saveTimer?.cancel();
      _retryTimer?.cancel();
      _forgetSecrets();
    });
    return const RegistrationFlowState();
  }

  int get _currentYear => ref.read(clockProvider).nowUtc().year;

  // ---------------------------------------------------------------- SCR-03

  /// Открытие SCR-03: подставить действующий черновик (баннер UI-03-017).
  Future<void> loadDraft() async {
    if (state.phase == SecurityPhase.done) {
      _resetAll();
      state = const RegistrationFlowState();
    }
    if (state.loaded) return;
    final draft = await _drafts.load();
    state = state.copyWith(
      loaded: true,
      draft: draft?.copyWith(step: RegistrationStep.data) ?? state.draft,
      restored: draft != null,
    );
  }

  void dismissRestored() => state = state.copyWith(restored: false);

  void setFullName(String value) => _updateDraft(state.draft.copyWith(fullName: value), field: 'fullName');

  void setBirthYear(String value) => _updateDraft(state.draft.copyWith(birthYear: value), field: 'birthYear');

  void setActivitySphere(ActivitySphere? sphere) {
    final draft = sphere == null
        ? state.draft.copyWith(clearActivitySphere: true)
        : state.draft.copyWith(activitySphere: sphere);
    state = state.copyWith(otherSphereText: sphere == ActivitySphere.other ? state.otherSphereText : '');
    _updateDraft(draft, field: 'activitySphere');
  }

  void setOtherSphereText(String value) => state = state.copyWith(
    otherSphereText: value.length > RegistrationValidation.otherSphereMaxLength
        ? value.substring(0, RegistrationValidation.otherSphereMaxLength)
        : value,
  );

  void setPersonalDataAck(bool value) {
    state = state.copyWith(consentServerError: false);
    _updateDraft(state.draft.copyWith(personalDataAck: value));
  }

  void setActivitySphereConsent(bool value) => _updateDraft(state.draft.copyWith(activitySphereConsent: value));

  void _updateDraft(RegistrationDraft draft, {String? field}) {
    final errors = field == null ? state.serverFieldErrors : (Map.of(state.serverFieldErrors)..remove(field));
    state = state.copyWith(draft: draft, restored: false, serverFieldErrors: errors);
    _saveTimer?.cancel();
    // Первый вход сотрудника: черновика регистрации нет (форма SCR-03 не проходится).
    if (state.audience == RegistrationAudience.staffFirstLogin) return;
    _saveTimer = Timer(const Duration(milliseconds: 300), () => unawaited(_drafts.save(state.draft)));
  }

  // Производное значение state для экрана (только чтение, без собственного состояния).
  // ignore: riverpod_lint/avoid_public_notifier_properties
  FullNameCheck get fullNameCheck => RegistrationValidation.checkFullName(state.draft.fullName);

  // Производное значение state для экрана (только чтение, без собственного состояния).
  // ignore: riverpod_lint/avoid_public_notifier_properties
  BirthYearError? get birthYearError =>
      RegistrationValidation.checkBirthYear(state.draft.birthYear, currentYear: _currentYear);

  // Производное значение state для экрана (только чтение, без собственного состояния).
  // ignore: riverpod_lint/avoid_public_notifier_properties
  int get maxBirthYear => RegistrationValidation.maxBirthYear(_currentYear);

  // Производное значение state для экрана (только чтение, без собственного состояния).
  // ignore: riverpod_lint/avoid_public_notifier_properties
  bool get formReady => RegistrationValidation.formReady(
    fullName: state.draft.fullName,
    birthYear: state.draft.birthYear,
    personalDataAck: state.draft.personalDataAck,
  );

  /// «Продолжить» (UI-03-011): полная валидация; `true` — можно на SCR-04.
  Future<bool> submitForm() async {
    final normalized = RegistrationValidation.normalizeFullName(state.draft.fullName);
    state = state.copyWith(formSubmitted: true, draft: state.draft.copyWith(fullName: normalized));
    if (!fullNameCheck.isValid || birthYearError != null || !state.draft.personalDataAck) return false;
    final next = state.draft.copyWith(step: RegistrationStep.security);
    state = state.copyWith(draft: next);
    _saveTimer?.cancel();
    await _drafts.save(next);
    return true;
  }

  // ---------------------------------------------------------------- SCR-04

  /// Открытие SCR-04: режим и проверка биометрии устройства.
  Future<void> openSecurity(RegistrationAudience audience) async {
    if (state.phase == SecurityPhase.done) {
      // Новый проход (другой вход/регистрация в том же процессе) — состояние прошлого прохода не переносится.
      _resetAll();
      state = RegistrationFlowState(audience: audience);
    } else if (state.audience != audience) {
      state = state.copyWith(audience: audience);
    }
    _resetPin();
    await refreshBiometrics();
  }

  /// Переоценка доступности биометрии (открытие, возврат из фона).
  Future<void> refreshBiometrics() async {
    final option = await ref.read(deviceBiometricsProvider).option();
    final selectable = option == BiometricOption.cryptoLogin || option == BiometricOption.windowsHelloGate;
    state = state.copyWith(
      bioOption: option,
      bioEnabled: selectable && state.bioEnabled,
      pinEnabled: option == BiometricOption.cryptoLogin ? state.pinEnabled : true,
    );
  }

  void setPinEnabled(bool value) {
    if (state.pinRequired) return;
    // PIN можно выключить только при включённой биометрии с согласием (AC-UI-04-020).
    if (!value && !(state.bioEnabled && state.bioConsent)) {
      state = state.copyWith(protectionError: true);
      return;
    }
    if (!value) _resetPin();
    state = state.copyWith(pinEnabled: value, protectionError: false);
  }

  void setBioEnabled(bool value) {
    if (!state.bioSelectable) return;
    // Выключение биометрии возвращает PIN (хотя бы один способ, AC-UI-04-020).
    state = state.copyWith(
      bioEnabled: value,
      bioConsent: value ? state.bioConsent : false,
      pinEnabled: value ? state.pinEnabled : true,
      protectionError: false,
    );
  }

  void setBioConsent(bool value) => state = state.copyWith(bioConsent: value, protectionError: false);

  /// «Настроить биометрию позже» (UI-04-013).
  void bioLater() => state = state.copyWith(bioEnabled: false, bioConsent: false, pinEnabled: true);

  /// Ввод PIN завершён (N цифр) на текущем этапе.
  void onPinEntered(String pin) {
    switch (state.pinStage) {
      case PinStage.create:
        final birth = int.tryParse(state.draft.birthYear);
        final weak = RegistrationValidation.pinWeakness(pin, length: state.pinPolicy.length, birthYear: birth);
        if (weak != null) {
          _resetPin(error: PinErrorKind.weak);
          return;
        }
        _pinFirst = pin;
        state = state.copyWith(pinStage: PinStage.confirm, clearPinError: true, protectionError: false);
      case PinStage.confirm:
        if (pin != _pinFirst) {
          _resetPin(error: PinErrorKind.mismatch);
          return;
        }
        _pin = pin;
        _pinFirst = null;
        state = state.copyWith(pinStage: PinStage.done, clearPinError: true, protectionError: false);
      case PinStage.done:
        break;
    }
  }

  /// Правка PIN после совпадения — ввод с начала (02 SCR-04.4 п. 5).
  void restartPin() => _resetPin();

  void _resetPin({PinErrorKind? error}) {
    _pinFirst = null;
    _pin = null;
    state = state.copyWith(
      pinStage: PinStage.create,
      pinError: error,
      clearPinError: error == null,
      pinResetCounter: state.pinResetCounter + 1,
    );
  }

  LoginProtectionChoice get _choice => LoginProtectionChoice(
    pin: state.pinActive ? _pin : null,
    biometricsEnabled: state.bioEnabled && state.bioSelectable,
    biometricsConsent: state.bioConsent,
  );

  // Производное значение state для экрана (только чтение, без собственного состояния).
  // ignore: riverpod_lint/avoid_public_notifier_properties
  /// Кнопка «Завершить регистрацию» / «Начать работу» активна (UI-04-012).
  bool get canSubmit {
    if (state.busy || state.phase == SecurityPhase.done) return false;
    if (state.phase == SecurityPhase.needPin) return _pin != null;
    if (state.pinActive && _pin == null) return false;
    if (state.audience == RegistrationAudience.staffFirstLogin && !state.draft.personalDataAck) return false;
    return _choice.satisfies(PinPolicy(length: state.pinPolicy.length, mandatory: state.pinRequired));
  }

  /// UI-04-012: регистрация клиента / первый вход сотрудника / установка PIN после неудачной биометрии.
  Future<void> submit({required BiometricPromptCopy prompt}) async {
    if (_inFlight) return;
    _lastPrompt = prompt;
    if (!canSubmit) {
      state = state.copyWith(protectionError: true);
      return;
    }
    switch (state.phase) {
      case SecurityPhase.needPin:
        await _setPinAfterBiometricFailure();
      case _ when state.audience == RegistrationAudience.staffFirstLogin:
        await _staffFirstLogin(prompt);
      case _:
        await _completeRegistration(prompt);
    }
  }

  Future<void> _completeRegistration(BiometricPromptCopy prompt) async {
    final ticket = ref.read(registrationTicketProvider);
    final now = ref.read(clockProvider).nowUtc();
    if (ticket == null || ticket.isExpired(now)) {
      state = state.copyWith(effect: const ExpiredEffect());
      return;
    }
    if (!fullNameCheck.isValid || birthYearError != null || !state.draft.personalDataAck) {
      // SCR-04 открыт без валидного шага «Данные» (перезапуск, прямой переход) — назад к форме.
      state = state.copyWith(formSubmitted: true, effect: const ToFormEffect());
      return;
    }
    final choice = _choice;
    final request = RegistrationRequestBuilder.build(ticket: ticket, draft: state.draft, protection: choice);
    final fingerprint = Object.hash(
      request.fullName,
      request.birthYear,
      request.activitySphere,
      request.pin,
      request.biometricsEnabled,
      Object.hashAll(request.consents),
    );
    if (_idempotencyKey == null || _keyFingerprint != fingerprint) {
      _idempotencyKey = ref.read(registrationKeyGeneratorProvider)();
      _keyFingerprint = fingerprint;
    }
    _inFlight = true;
    state = state.copyWith(phase: SecurityPhase.submitting, clearSubmitError: true, protectionError: false);
    final result = await _repo.complete(request, idempotencyKey: _idempotencyKey!);
    _inFlight = false;
    switch (result) {
      case Success<RegistrationOutcome>(:final value):
        _idempotencyKey = null;
        _saveTimer?.cancel();
        await _drafts.clear();
        ref.read(registrationTicketProvider.notifier).clear();
        state = state.copyWith(outcome: value);
        if (choice.biometricsGranted) {
          await _enableBiometrics(prompt);
        } else {
          _finish();
        }
      case FailureResult<RegistrationOutcome>(:final failure):
        _onCompleteFailure(failure);
    }
  }

  void _onCompleteFailure(Failure failure) {
    switch (failure) {
      case AuthFailure(reason: AuthReason.registrationTokenInvalid):
        ref.read(registrationTicketProvider.notifier).clear();
        state = state.copyWith(phase: SecurityPhase.editing, effect: const ExpiredEffect());
      case ConflictFailure(kind: ConflictKind.phoneAlreadyRegistered):
        unawaited(_drafts.clear());
        ref.read(registrationTicketProvider.notifier).clear();
        state = state.copyWith(
          phase: SecurityPhase.editing,
          effect: const ToPhoneEffect(RegistrationExitReason.phoneRegistered),
        );
      case ConflictFailure(kind: ConflictKind.idempotencyInProgress, :final retryAfter):
        // Тот же ключ, автоматический повтор (02 SCR-04.4 п. 5); кнопка остаётся `loading`.
        state = state.copyWith(phase: SecurityPhase.submitting);
        _retryTimer?.cancel();
        _retryTimer = Timer(retryAfter ?? const Duration(seconds: 2), () {
          state = state.copyWith(phase: SecurityPhase.editing);
          unawaited(submit(prompt: _lastPrompt));
        });
      case ValidationFailure(:final errors):
        _onValidation(errors);
      case ServerFailure(code: 'CONSENT_REQUIRED'):
        state = state.copyWith(
          phase: SecurityPhase.editing,
          consentServerError: true,
          draft: state.draft.copyWith(personalDataAck: false),
          effect: const ToFormEffect(),
        );
      case ServerFailure(code: 'APP_READ_ONLY'):
        state = state.copyWith(phase: SecurityPhase.editing, submitError: SubmitErrorKind.readOnly);
      case NetworkFailure():
        state = state.copyWith(phase: SecurityPhase.editing, submitError: SubmitErrorKind.network);
      default:
        state = state.copyWith(
          phase: SecurityPhase.editing,
          submitError: SubmitErrorKind.server,
          submitRequestId: failure.requestId,
        );
    }
  }

  BiometricPromptCopy _lastPrompt = const BiometricPromptCopy(title: ' ', cancel: ' ');

  void _onValidation(List<FieldError> errors) {
    final profile = <String, String>{};
    var pinWeak = false;
    var protection = false;
    for (final e in errors) {
      final field = e.field.split('.').first.split('[').first;
      switch (field) {
        case 'security' when e.rule == 'login_protection_required':
          protection = true;
        case 'security' || 'pin':
          pinWeak = true;
        case 'fullName' || 'birthYear' || 'activitySphere':
          profile[field] = e.rule;
        case 'consents':
          profile['consents'] = e.rule;
      }
    }
    if (pinWeak) _resetPin(error: PinErrorKind.weak);
    state = state.copyWith(
      phase: SecurityPhase.editing,
      protectionError: protection,
      serverFieldErrors: profile,
      formSubmitted: profile.isNotEmpty || state.formSubmitted,
      effect: profile.isNotEmpty ? const ToFormEffect() : null,
    );
  }

  // ---------------------------------------------------------------- биометрия после 201 / PIN

  Future<void> _enableBiometrics(BiometricPromptCopy prompt) async {
    _lastPrompt = prompt;
    state = state.copyWith(phase: SecurityPhase.bioSetup);
    final enrollment = await ref.read(enableBiometricLoginProvider)(copy: prompt, stepUpToken: _stepUpToken);
    _onEnrollment(enrollment);
  }

  void _onEnrollment(BiometricEnrollment enrollment) {
    state = state.copyWith(bioResult: enrollment.result);
    if (enrollment.isEnabled) {
      _finish();
      return;
    }
    final hasPin = _pin != null || state.audience == RegistrationAudience.staffFirstLogin;
    if (enrollment.result == BiometricEnrollmentResult.stepUpRequired && hasPin) {
      state = state.copyWith(phase: SecurityPhase.stepUp, stepUpError: false);
      return;
    }
    _bioFailed();
  }

  void _bioFailed() {
    final pinWasSet = _pin != null || state.audience == RegistrationAudience.staffFirstLogin;
    if (pinWasSet) {
      state = state.copyWith(effect: const BioNotEnabledEffect());
      _finish();
    } else {
      // Клиент без PIN: «Готово» не открывается, пока PIN не задан (02 AC-UI-04-021).
      _resetPin();
      state = state.copyWith(phase: SecurityPhase.needPin, pinEnabled: true);
    }
  }

  /// PIN из `StepUpDialog` для `POST /me/biometrics` (02 SCR-04.4 п. 2).
  Future<void> submitStepUpPin(String pin) async {
    if (_inFlight || state.phase != SecurityPhase.stepUp) return;
    _inFlight = true;
    final res = await ref.read(stepUpWithPinProvider)(pin: pin);
    _inFlight = false;
    if (res.token != null) {
      _stepUpToken = res.token;
      await _enableBiometrics(_lastPrompt);
      return;
    }
    final error = res.error!;
    if (error.result == BiometricEnrollmentResult.pinInvalid) {
      state = state.copyWith(stepUpError: true, stepUpAttemptsLeft: error.attemptsLeft);
      return;
    }
    _bioFailed();
  }

  /// Отмена `StepUpDialog` — регистрация уже завершена без биометрии.
  void cancelStepUp() {
    if (state.phase == SecurityPhase.stepUp) _bioFailed();
  }

  Future<void> _setPinAfterBiometricFailure() async {
    final pin = _pin;
    if (pin == null) return;
    _inFlight = true;
    state = state.copyWith(phase: SecurityPhase.submitting, clearSubmitError: true);
    final res = await _repo.setPin(pin);
    _inFlight = false;
    switch (res) {
      case Success<void>():
        _finish();
      case FailureResult<void>(:final failure):
        if (failure is ValidationFailure) {
          state = state.copyWith(phase: SecurityPhase.needPin);
          _resetPin(error: PinErrorKind.weak);
        } else {
          state = state.copyWith(
            phase: SecurityPhase.needPin,
            submitError: failure is NetworkFailure ? SubmitErrorKind.network : SubmitErrorKind.server,
            submitRequestId: failure.requestId,
          );
        }
    }
  }

  bool _staffPinSet = false;
  bool _staffConsentSent = false;

  /// «Начать работу» (02 SCR-04 «первый вход сотрудника»): `POST /me/pin` → `POST /me/consents` → биометрия.
  Future<void> _staffFirstLogin(BiometricPromptCopy prompt) async {
    final pin = _pin;
    if (pin == null) return;
    _inFlight = true;
    state = state.copyWith(phase: SecurityPhase.submitting, clearSubmitError: true);
    if (!_staffPinSet) {
      final res = await _repo.setPin(pin);
      if (res case FailureResult<void>(:final failure)) {
        _inFlight = false;
        if (failure is ValidationFailure) {
          state = state.copyWith(phase: SecurityPhase.editing);
          _resetPin(error: PinErrorKind.weak);
        } else {
          _onStaffFailure(failure);
        }
        return;
      }
      _staffPinSet = true;
    }
    if (!_staffConsentSent) {
      final res = await _repo.acknowledgePersonalData();
      if (res case FailureResult<void>(:final failure)) {
        _inFlight = false;
        _onStaffFailure(failure);
        return;
      }
      _staffConsentSent = true;
    }
    _inFlight = false;
    if (_choice.biometricsGranted) {
      await _enableBiometrics(prompt);
    } else {
      _finish();
    }
  }

  void _onStaffFailure(Failure failure) => state = state.copyWith(
    phase: SecurityPhase.editing,
    submitError: switch (failure) {
      NetworkFailure() => SubmitErrorKind.network,
      ServerFailure(code: 'APP_READ_ONLY') => SubmitErrorKind.readOnly,
      _ => SubmitErrorKind.server,
    },
    submitRequestId: failure.requestId,
  );

  void _finish() {
    _forgetSecrets();
    state = state.copyWith(phase: SecurityPhase.done, pinStage: PinStage.done);
  }

  void _resetAll() {
    _forgetSecrets();
    _idempotencyKey = null;
    _keyFingerprint = null;
    _staffPinSet = false;
    _staffConsentSent = false;
    _saveTimer?.cancel();
    _retryTimer?.cancel();
  }

  void _forgetSecrets() {
    _pin = null;
    _pinFirst = null;
    _stepUpToken = null;
  }

  /// «Повторить» в баннере UI-04-016 — тот же ключ, если тело не менялось.
  Future<void> retry({required BiometricPromptCopy prompt}) => submit(prompt: prompt);

  /// Экран обработал событие.
  void consumeEffect() => state = state.copyWith(clearEffect: true);

  /// Отмена регистрации (UI-03-001): черновик остаётся до 15 мин, токен — забывается.
  void cancelRegistration() {
    _forgetSecrets();
    ref.read(registrationTicketProvider.notifier).clear();
  }

  /// Уход с SCR-04 назад (UI-04-001): PIN сбрасывается.
  void leaveSecurity() => _resetPin();
}
