// Лимиты скидок и настройки приложения SCR-46 (08 §4.18.5–§4.18.6 `AdminDiscountLimits`, `AdminSettingsResponse`,
// `AdminSettingsValues`, `AdminSettingsEnv`; 10 DISC-, D-23; RM-G-003, RM-G-008, RM-G-014). Изменение — только
// `admin` со step-up (`settings.discount_limits.update`, `settings.app.update`), `owner` — только просмотр (ядро §21
// п. 3); `env` (`CUSTOMER_SELF_SERVICE`, `DEBT_PAYMENTS_FROM_POS`, …) — только чтение. Лимиты по ролям seed
// `5/5/10/15` — [НЕ ПОДТВЕРЖДЕНО: Q-015]. Планшет магазина (08 §4.18.6; 07 §5.59; 02 UI-46-018; ADR-115): шесть общих
// ключей `kiosk*` (умолчания — в коде сервера: 120 / 15 / 60 / 30 / 200 и пустые часы работы — сигнал «планшет не на
// связи» выключен, Q-341) и env `kioskMode` (`KIOSK_MODE`, только чтение; в SCR-46 не показывается). Чистый Dart (FL-01).
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
    this.kioskIdleSeconds,
    this.kioskIdleWarningSeconds,
    this.kioskDoneSeconds,
    this.kioskOtpPerHour,
    this.kioskOtpPerDay,
    this.kioskWorkingHours,
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

  /// Планшет магазина: автосброс без касаний, с (30…1800; по умолчанию 120 — Р-09 (а)).
  final int? kioskIdleSeconds;

  /// Обратный отсчёт «Вы ещё здесь?», с (5…120; 15).
  final int? kioskIdleWarningSeconds;

  /// Номер заявки на экране SCR-53, с (10…600; 60).
  final int? kioskDoneSeconds;

  /// Кодов `kiosk_order` с одного планшета в час (1…1000; 30 — Р-14 (а)).
  final int? kioskOtpPerHour;

  /// То же за сутки (1…10000; 200).
  final int? kioskOtpPerDay;

  /// Часы работы магазина (07 §5.59: `mon-sat 08:00-20:00;sun 09:00-15:00`, Asia/Bishkek); `''` — сигнал «планшет не
  /// на связи» выключен (Q-341).
  final String? kioskWorkingHours;
}

/// Значения env (`AdminSettingsEnv`) — только чтение в UI.
final class AdminSettingsEnv {
  const AdminSettingsEnv({
    this.customerSelfService,
    this.kioskMode,
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

  /// `KIOSK_MODE` — режим «Планшет магазина» (только env; публикуется как `features.storeTablet`).
  final bool? kioskMode;
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
