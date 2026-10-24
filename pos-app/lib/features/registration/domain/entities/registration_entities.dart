// Сущности регистрации клиента и первого входа сотрудника (09 §7; 02 SCR-03/04/06/07; 08 §4.2).
// Чистый Dart (FL-01). Значения с ПДн/секретами переопределяют toString без значений (NFR-LOG-001).
import 'package:optomstroy/core/utils/customer_display_name.dart';

/// Допуск к форме SCR-03 после `/auth/otp/verify` → `registration_required` (08 §4.1.2).
/// `registrationToken` живёт только в памяти процесса (09 §7.1, ядро §19.3).
final class RegistrationTicket {
  const RegistrationTicket({
    required this.registrationToken,
    required this.expiresAt,
    required this.phoneE164,
    this.phoneMasked,
  });

  /// JWT purpose=register, TTL 15 мин.
  final String registrationToken;

  /// Абсолютный срок токена (`now + registrationExpiresIn`).
  final DateTime expiresAt;

  /// Подтверждённый номер E.164 (только память потока входа; на устройстве не хранится).
  final String phoneE164;

  /// Маска номера из ответа verify.
  final String? phoneMasked;

  bool isExpired(DateTime now) => !now.isBefore(expiresAt);

  Duration remaining(DateTime now) => isExpired(now) ? Duration.zero : expiresAt.difference(now);

  @override
  String toString() => 'RegistrationTicket(***)';
}

/// Сфера деятельности — код справочника (Q-165, Q-203; коды как в pos-api profile.constants.ts).
enum ActivitySphere {
  plumber('plumber'),
  foreman('foreman'),
  reseller('reseller'),
  installer('installer'),
  privatePerson('private'),
  other('other');

  const ActivitySphere(this.code);

  /// Значение `activitySphere` API.
  final String code;

  static ActivitySphere? tryParse(String? code) {
    for (final item in values) {
      if (item.code == code) return item;
    }
    return null;
  }
}

/// Режим экрана «Защита входа» (02 SCR-04).
enum RegistrationAudience {
  /// Регистрация клиента (`registration_required`): PIN 4 цифры, хотя бы один способ (ядро §24.2).
  customer,

  /// Первый вход сотрудника по приглашению (`nextStep=set_pin`): PIN 6 цифр обязателен (D-48, 09 §7.6).
  staffFirstLogin,
}

/// Политика PIN по аудитории (09 §9.6: `staff` — 6, `customer` — 4).
final class PinPolicy {
  const PinPolicy({required this.length, required this.mandatory});

  static const PinPolicy customer = PinPolicy(length: 4, mandatory: false);
  static const PinPolicy staff = PinPolicy(length: 6, mandatory: true);

  static PinPolicy of(RegistrationAudience audience) => audience == RegistrationAudience.customer ? customer : staff;

  final int length;

  /// `true` — PIN обязателен всегда; `false` — обязателен, если не выбрана биометрия (хотя бы один способ).
  final bool mandatory;
}

/// Шаги мастера (коды — белый список `registration_draft.step`, 07 §11.2).
enum RegistrationStep {
  data('data'),
  security('security'),
  customerLink('customer_link'),
  done('done');

  const RegistrationStep(this.code);

  final String code;

  static RegistrationStep? tryParse(Object? code) {
    for (final item in values) {
      if (item.code == code) return item;
    }
    return null;
  }
}

/// Версии текстов согласий, встроенные в сборку (contracts/legal/consents_ru.md; сервер подтверждает
/// актуальность: устаревшая версия → `CONSENT_REQUIRED`, 02 UI-03-014).
abstract final class ConsentVersions {
  static const String personalData = '2026-10-01';
  static const String activitySphere = '2026-10-01';
  static const String biometricsDevice = '2026-10-01';
}

/// Элемент `consents[]` (`kind` по 07 `consent_kind`).
final class ConsentGrant {
  const ConsentGrant(this.kind, this.version);

  final String kind;
  final String version;

  @override
  bool operator ==(Object other) => other is ConsentGrant && other.kind == kind && other.version == version;

  @override
  int get hashCode => Object.hash(kind, version);

  @override
  String toString() => 'ConsentGrant($kind, $version)';
}

/// Черновик регистрации (09 §7.4): ФИО и год — secure storage, остальное — состояние шагов без ПДн.
/// PIN и номер телефона в черновик не входят.
final class RegistrationDraft {
  const RegistrationDraft({
    this.fullName = '',
    this.birthYear = '',
    this.activitySphere,
    this.personalDataAck = false,
    this.activitySphereConsent = false,
    this.step = RegistrationStep.data,
  });

  final String fullName;
  final String birthYear;
  final ActivitySphere? activitySphere;
  final bool personalDataAck;
  final bool activitySphereConsent;
  final RegistrationStep step;

  bool get isEmpty => fullName.trim().isEmpty && birthYear.isEmpty && activitySphere == null && !personalDataAck;

  RegistrationDraft copyWith({
    String? fullName,
    String? birthYear,
    ActivitySphere? activitySphere,
    bool clearActivitySphere = false,
    bool? personalDataAck,
    bool? activitySphereConsent,
    RegistrationStep? step,
  }) => RegistrationDraft(
    fullName: fullName ?? this.fullName,
    birthYear: birthYear ?? this.birthYear,
    activitySphere: clearActivitySphere ? null : (activitySphere ?? this.activitySphere),
    personalDataAck: personalDataAck ?? this.personalDataAck,
    activitySphereConsent: clearActivitySphere ? false : (activitySphereConsent ?? this.activitySphereConsent),
    step: step ?? this.step,
  );

  @override
  bool operator ==(Object other) =>
      other is RegistrationDraft &&
      other.fullName == fullName &&
      other.birthYear == birthYear &&
      other.activitySphere == activitySphere &&
      other.personalDataAck == personalDataAck &&
      other.activitySphereConsent == activitySphereConsent &&
      other.step == step;

  @override
  int get hashCode => Object.hash(fullName, birthYear, activitySphere, personalDataAck, activitySphereConsent, step);

  @override
  String toString() => 'RegistrationDraft(step: ${step.code}, ***)';
}

/// Тело `POST /registration/complete` без устройства (его добавляет data, 08 §4.2.1).
final class RegistrationRequest {
  const RegistrationRequest({
    required this.registrationToken,
    required this.fullName,
    required this.birthYear,
    required this.biometricsEnabled,
    required this.consents,
    this.activitySphere,
    this.pin,
  });

  final String registrationToken;
  final String fullName;
  final int birthYear;
  final ActivitySphere? activitySphere;
  final String? pin;
  final bool biometricsEnabled;
  final List<ConsentGrant> consents;

  @override
  String toString() => 'RegistrationRequest(***)';
}

/// Статус привязки к карточке 1С (08 §4.2.2).
enum CustomerLinkStatus {
  none('none'),
  proposed('proposed'),
  confirmed('confirmed'),
  rejected('rejected'),
  conflict('conflict');

  const CustomerLinkStatus(this.code);

  final String code;

  static CustomerLinkStatus parse(Object? code) {
    for (final item in values) {
      if (item.code == code) return item;
    }
    return CustomerLinkStatus.none;
  }
}

/// Следующий шаг привязки (08 §4.2.2).
enum CustomerMatchNextStep {
  confirmOrReject('confirm_or_reject'),
  waitAdmin('wait_admin'),
  confirmed('confirmed'),
  none('none');

  const CustomerMatchNextStep(this.code);

  final String code;

  static CustomerMatchNextStep parse(Object? code) {
    for (final item in values) {
      if (item.code == code) return item;
    }
    return CustomerMatchNextStep.none;
  }
}

/// Состояние привязки без финансовых данных (SRC-B-145, 09 REG-032).
final class CustomerMatch {
  const CustomerMatch({
    required this.status,
    required this.nextStep,
    this.linkId,
    this.displayNameMasked,
    this.displayName,
  });

  static const CustomerMatch none = CustomerMatch(
    status: CustomerLinkStatus.none,
    nextStep: CustomerMatchNextStep.none,
  );

  final CustomerLinkStatus status;
  final CustomerMatchNextStep nextStep;
  final String? linkId;
  final String? displayNameMasked;

  /// Только при `confirmed`.
  final String? displayName;

  /// Наименование карточки для показа — единый presenter клиента (D PR-09): маска до `confirmed`, затем полное.
  String? get shownName => CustomerDisplayName.of(
    confirmed: status == CustomerLinkStatus.confirmed,
    displayName: displayName,
    displayNameMasked: displayNameMasked,
  );

  /// SCR-06 нужен после регистрации (02 SCR-04.6: `proposed`/`conflict`).
  bool get needsScreen => status == CustomerLinkStatus.proposed || status == CustomerLinkStatus.conflict;

  /// Кнопки «Да, это я / Нет, это не я» (02 SCR-06.4).
  bool get canSelfResolve =>
      status == CustomerLinkStatus.proposed && nextStep == CustomerMatchNextStep.confirmOrReject && linkId != null;

  @override
  String toString() => 'CustomerMatch(${status.code}, ${nextStep.code})';
}

/// Статус аккаунта после регистрации (08 §4.2.1).
enum RegistrationAccountStatus { authenticated, pendingActivation }

/// Результат `201 POST /registration/complete` (токены уже сохранены слоем data).
final class RegistrationOutcome {
  const RegistrationOutcome({
    required this.accountStatus,
    required this.roles,
    this.userKind,
    this.customerMatch,
    this.biometricRefreshOffered = false,
  });

  final RegistrationAccountStatus accountStatus;
  final String? userKind;
  final List<String> roles;
  final CustomerMatch? customerMatch;

  /// `true` — Android class3 / iOS (08 §4.1.2); при отсутствии поля решает возможность устройства.
  final bool biometricRefreshOffered;

  bool get isCustomer => userKind == 'customer' || roles.contains('customer');

  @override
  String toString() => 'RegistrationOutcome(${accountStatus.name}, $roles)';
}

/// Сведения об аккаунте для SCR-07 (из `GET /me`; ПДн — только в памяти).
final class AccountSnapshot {
  const AccountSnapshot({required this.status, required this.roles, this.fullName, this.phone, this.registeredAt});

  /// `UserStatus` (07): `pending_activation`, `active`, `blocked`, …
  final String status;
  final List<String> roles;
  final String? fullName;
  final String? phone;
  final DateTime? registeredAt;

  bool get isActive => status == 'active';
  bool get isBlocked => status == 'blocked' || status == 'deleted';

  @override
  String toString() => 'AccountSnapshot($status, $roles)';
}

/// Возможность биометрии устройства для экрана SCR-04 (09 §9.4).
enum BiometricOption {
  /// Android Class 3 (API 30+) / iOS: вход по биометрии с криптопривязкой.
  cryptoLogin,

  /// Windows Hello: только UX-гейт перед PIN (локальная настройка, сервер токен не выдаёт).
  windowsHelloGate,

  /// Датчик есть, биометрия в ОС не настроена.
  notEnrolled,

  /// Недоступно (нет датчика, Class 2, API < 30, нет кода устройства).
  unsupported,
}

/// Итог включения биометрии после `201` (02 SCR-04.4 «Системный диалог»).
enum BiometricEnrollmentResult {
  /// `biometric_refresh` получен и сохранён под ключом с биометрией.
  enabled,

  /// Windows: Hello подтверждён как гейт; сервер токен не выдаёт (`no_crypto_binding_on_platform`).
  gateOnly,

  /// Сервер требует step-up (`STEP_UP_REQUIRED`) — экран спрашивает PIN.
  stepUpRequired,

  /// Пользователь отменил системный диалог / step-up.
  cancelled,

  /// Биометрия ОС заблокирована.
  lockout,

  /// Биометрия ОС не настроена.
  notEnrolled,

  /// PIN заблокирован при step-up (`PIN_LOCKED`).
  pinLocked,

  /// Неверный PIN при step-up (`PIN_INVALID`).
  pinInvalid,

  /// Иная ошибка (сеть, сервер, ОС).
  failed,
}

/// Результат включения биометрии с остатком попыток PIN (только из ответа сервера).
final class BiometricEnrollment {
  const BiometricEnrollment(this.result, {this.attemptsLeft, this.stepUpOperation});

  final BiometricEnrollmentResult result;
  final int? attemptsLeft;

  /// `stepUp.operation` из 403 — передаётся в `/auth/step-up` без изменений.
  final String? stepUpOperation;

  bool get isEnabled => result == BiometricEnrollmentResult.enabled || result == BiometricEnrollmentResult.gateOnly;

  @override
  String toString() => 'BiometricEnrollment(${result.name})';
}
