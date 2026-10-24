// Лимиты скидок и настройки приложения SCR-46 (08 §4.18.5–§4.18.6 `AdminDiscountLimits`, `AdminSettingsResponse`,
// `AdminSettingsValues`, `AdminSettingsEnv`; 10 DISC-, D-23; RM-G-003, RM-G-008, RM-G-014). Изменение — только
// `admin` со step-up (`settings.discount_limits.update`, `settings.app.update`), `owner` — только просмотр (ядро §21
// п. 3); `env` (`CUSTOMER_SELF_SERVICE`, `DEBT_PAYMENTS_FROM_POS`, …) — только чтение. Лимиты по ролям seed
// `5/5/10/15` — [НЕ ПОДТВЕРЖДЕНО: Q-015]. Чистый Dart (FL-01).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';

/// Роли, для которых задаётся лимит ручной скидки (`AdminDiscountLimitsByRole`, `additionalProperties: false`).
const List<RoleCode> discountLimitRoles = <RoleCode>[
  RoleCode.seller,
  RoleCode.cashier,
  RoleCode.seniorSeller,
  RoleCode.admin,
  RoleCode.owner,
];

/// Лимиты ручной скидки по ролям (`AdminDiscountLimits`).
final class AdminDiscountLimits {
  const AdminDiscountLimits({
    required this.limits,
    required this.overrideRoles,
    required this.rowVersion,
    this.updatedAt,
    this.updatedBy,
  });

  /// Лимит по каждой роли [discountLimitRoles].
  final Map<RoleCode, Percent> limits;

  /// Роли, подтверждающие скидку сверх лимита (≤ 7).
  final List<RoleCode> overrideRoles;
  final int rowVersion;
  final DateTime? updatedAt;
  final UserRef? updatedBy;

  static const int overrideRolesMax = 7;
}

/// Слот доставки (`DeliverySlot`, `HH:MM`).
final class DeliverySlotValue {
  const DeliverySlotValue({required this.from, required this.to});

  final String from;
  final String to;
}

/// Контакт поддержки (`SupportContact`).
final class SupportContactValue {
  const SupportContactValue({required this.kind, required this.value, this.label});

  final String kind;
  final String value;
  final String? label;
}

/// Изменяемые настройки (`AdminSettingsValues`). `null` — значение не задано (сервер — умолчание).
/// Ключи с точкой (`receivables.maxAgeMinutes`, `syncInterval.<entity>`, `otp.*`, `session.*`, `print.*`, `qr.*`)
/// — как в контракте.
final class AdminSettingsValues {
  const AdminSettingsValues({
    this.lowStockThreshold,
    this.cartStaleMinutes,
    this.parkedCartTtlDays,
    this.overpayAllowed,
    this.returnApprovalThreshold,
    this.returnsEnabled,
    this.cashRounding,
    this.deliverySlots,
    this.receivablesMaxAgeMinutes,
    this.minAppVersion,
    this.recommendedAppVersion,
    this.secureScreens,
    this.privacyContact,
    this.syncIntervals = const <String, int>{},
    this.otpTtlSeconds,
    this.otpMaxAttempts,
    this.sessionStaffRefreshDays,
    this.consentTexts,
    this.categoryIcons,
    this.attributeCodes,
    this.printDefaultPaper,
    this.qrEnabled,
    this.customerStockDisplay,
    this.supportContacts,
  });

  final int? lowStockThreshold;
  final int? cartStaleMinutes;

  /// 1…30.
  final int? parkedCartTtlDays;
  final bool? overpayAllowed;

  /// Порог согласования возврата (`return_approval_threshold`).
  final Money? returnApprovalThreshold;

  /// Модуль заявок на возврат (Q-018; 10 RET-012).
  final bool? returnsEnabled;

  /// `none|to_som`.
  final String? cashRounding;
  final List<DeliverySlotValue>? deliverySlots;

  /// `receivables.maxAgeMinutes` (5…1440).
  final int? receivablesMaxAgeMinutes;

  /// `SemVerByPlatform` строкой (`android=1.2.0,windows=1.2.0`).
  final String? minAppVersion;
  final String? recommendedAppVersion;
  final List<String>? secureScreens;
  final String? privacyContact;

  /// `syncInterval.<entity>` → секунды (60…86400); ключ — сущность без префикса.
  final Map<String, int> syncIntervals;

  /// `otp.ttlSeconds` (180…600).
  final int? otpTtlSeconds;

  /// `otp.maxAttempts`.
  final int? otpMaxAttempts;

  /// `session.staffRefreshDays`.
  final int? sessionStaffRefreshDays;
  final Map<String, Object?>? consentTexts;
  final Map<String, Object?>? categoryIcons;
  final Map<String, Object?>? attributeCodes;

  /// `print.defaultPaper`.
  final PrintPaper? printDefaultPaper;

  /// `qr.enabled`.
  final bool? qrEnabled;

  /// «Показ остатков клиенту» (только `admin`, step-up; RM-G-014).
  final CustomerStockDisplay? customerStockDisplay;
  final List<SupportContactValue>? supportContacts;
}

/// Значения env (`AdminSettingsEnv`) — только чтение в UI.
final class AdminSettingsEnv {
  const AdminSettingsEnv({
    this.customerSelfService,
    this.debtPaymentsFromPos,
    this.qrProvider,
    this.qrTtlMinutes,
    this.qrOnecPollSeconds,
    this.receivablesMaxAgeMin,
    this.minAppVersion,
    this.recommendedAppVersion,
    this.otpTtlSeconds,
    this.otpResendCooldownSeconds,
    this.otpMaxVerifyAttempts,
    this.otpGlobalPerMin,
    this.otpLockAfterLockedCodes,
    this.otpPhonePauseMinutes,
    this.sessionIdleLockMinutes,
    this.authBackgroundLockMinutes,
    this.smsSenderName,
  });

  final bool? customerSelfService;
  final bool? debtPaymentsFromPos;
  final QrProviderMode? qrProvider;
  final int? qrTtlMinutes;
  final int? qrOnecPollSeconds;
  final int? receivablesMaxAgeMin;
  final String? minAppVersion;
  final String? recommendedAppVersion;
  final int? otpTtlSeconds;
  final int? otpResendCooldownSeconds;
  final int? otpMaxVerifyAttempts;
  final int? otpGlobalPerMin;
  final int? otpLockAfterLockedCodes;
  final int? otpPhonePauseMinutes;
  final int? sessionIdleLockMinutes;
  final int? authBackgroundLockMinutes;
  final String? smsSenderName;
}

/// Настройки приложения (`AdminSettingsResponse`).
final class AdminSettings {
  const AdminSettings({required this.values, required this.env, required this.rowVersion});

  final AdminSettingsValues values;
  final AdminSettingsEnv env;
  final int rowVersion;
}
