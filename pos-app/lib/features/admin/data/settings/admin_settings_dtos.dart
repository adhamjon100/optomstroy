// DTO-кодеки SCR-46 (contracts/openapi/pos-api.v1.yaml 1.2.0; ADR-085 — вручную): `AdminDiscountLimits`,
// `AdminDiscountLimitsByRole`, `AdminDiscountLimitsUpdateRequest`, `AdminSettingsResponse`, `AdminSettingsValues`,
// `AdminSettingsEnv`, `AdminSettingsUpdateRequest` (тела — `additionalProperties: false`).
// Сверка ключей — test/features/admin/data/admin_settings_dtos_contract_test.dart.
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/core/network/models/pos_common_dtos.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/admin/domain/settings/admin_settings.dart';

/// `AdminDiscountLimitsByRole`: ключ API ↔ роль.
abstract final class DiscountLimitsByRoleDto {
  static const Set<String> jsonKeys = {'seller', 'cashier', 'senior_seller', 'admin', 'owner'};
  static const Set<String> requiredKeys = jsonKeys;

  static Map<RoleCode, Percent> fromJson(JsonMap j) => <RoleCode, Percent>{
    for (final RoleCode role in discountLimitRoles)
      role: jPercent(j, role.value) ?? (throw DtoFormatException('limits.${role.value}')),
  };

  static JsonMap toJson(Map<RoleCode, Percent> limits) => <String, dynamic>{
    for (final RoleCode role in discountLimitRoles) role.value: (limits[role] ?? Percent.zero).toApiString(),
  };
}

/// `AdminDiscountLimits` / `AdminDiscountLimitsUpdateRequest`.
abstract final class AdminDiscountLimitsDto {
  static const Set<String> jsonKeys = {'limits', 'overrideRoles', 'rowVersion', 'updatedAt', 'updatedBy'};
  static const Set<String> requiredKeys = {'limits', 'overrideRoles', 'rowVersion'};
  static const Set<String> updateKeys = {'limits', 'overrideRoles', 'rowVersion'};

  static AdminDiscountLimits fromJson(JsonMap j) => AdminDiscountLimits(
    limits: DiscountLimitsByRoleDto.fromJson(jReqObject(j, 'limits')),
    overrideRoles: <RoleCode>[
      for (final String r in jStrings(j, 'overrideRoles', required: true)) ?RoleCode.tryParse(r),
    ],
    rowVersion: jReqInt(j, 'rowVersion'),
    updatedAt: jDate(j, 'updatedAt'),
    updatedBy: UserRefDto.optional(j, 'updatedBy'),
  );

  static JsonMap toUpdateJson(AdminDiscountLimits l) => <String, dynamic>{
    'limits': DiscountLimitsByRoleDto.toJson(l.limits),
    'overrideRoles': <String>[for (final RoleCode r in l.overrideRoles) r.value],
    'rowVersion': l.rowVersion,
  };
}

/// `AdminSettingsValues`.
abstract final class AdminSettingsValuesDto {
  /// Сущности `syncInterval.<entity>` (OpenAPI 1.2.0).
  static const List<String> syncEntities = <String>[
    'categories',
    'products',
    'variants',
    'attributes',
    'units',
    'barcodes',
    'images',
    'warehouses',
    'stock',
    'prices',
    'customers',
    'receivables',
    'sales_history',
    'order_status',
    'discounts',
    'payment_docs',
    'return_docs',
  ];

  static const Set<String> _plainKeys = {
    'lowStockThreshold',
    'cartStaleMinutes',
    'parkedCartTtlDays',
    'overpayAllowed',
    'returnApprovalThreshold',
    'returnsEnabled',
    'cashRounding',
    'deliverySlots',
    'receivables.maxAgeMinutes',
    'minAppVersion',
    'recommendedAppVersion',
    'secureScreens',
    'privacyContact',
    'otp.ttlSeconds',
    'otp.maxAttempts',
    'session.staffRefreshDays',
    'consentTexts',
    'categoryIcons',
    'attributeCodes',
    'print.defaultPaper',
    'qr.enabled',
    'customerStockDisplay',
    'supportContacts',
  };

  static final Set<String> jsonKeys = <String>{..._plainKeys, for (final String e in syncEntities) 'syncInterval.$e'};
  static const Set<String> requiredKeys = <String>{};

  static Map<String, Object?>? _map(JsonMap j, String key) => jObject(j, key)?.cast<String, Object?>();

  static AdminSettingsValues fromJson(JsonMap j) => AdminSettingsValues(
    lowStockThreshold: jInt(j, 'lowStockThreshold'),
    cartStaleMinutes: jInt(j, 'cartStaleMinutes'),
    parkedCartTtlDays: jInt(j, 'parkedCartTtlDays'),
    overpayAllowed: jBool(j, 'overpayAllowed'),
    returnApprovalThreshold: jMoney(j, 'returnApprovalThreshold'),
    returnsEnabled: jBool(j, 'returnsEnabled'),
    cashRounding: jOpt<String>(j, 'cashRounding'),
    deliverySlots: j['deliverySlots'] == null
        ? null
        : jObjects(
            j,
            'deliverySlots',
            (JsonMap s) => DeliverySlotValue(from: jReq<String>(s, 'from'), to: jReq<String>(s, 'to')),
          ),
    receivablesMaxAgeMinutes: jInt(j, 'receivables.maxAgeMinutes'),
    minAppVersion: jOpt<String>(j, 'minAppVersion'),
    recommendedAppVersion: jOpt<String>(j, 'recommendedAppVersion'),
    secureScreens: j['secureScreens'] == null ? null : jStrings(j, 'secureScreens'),
    privacyContact: jOpt<String>(j, 'privacyContact'),
    syncIntervals: <String, int>{
      for (final String e in syncEntities)
        if (jInt(j, 'syncInterval.$e') != null) e: jInt(j, 'syncInterval.$e')!,
    },
    otpTtlSeconds: jInt(j, 'otp.ttlSeconds'),
    otpMaxAttempts: jInt(j, 'otp.maxAttempts'),
    sessionStaffRefreshDays: jInt(j, 'session.staffRefreshDays'),
    consentTexts: _map(j, 'consentTexts'),
    categoryIcons: _map(j, 'categoryIcons'),
    attributeCodes: _map(j, 'attributeCodes'),
    printDefaultPaper: jEnum(j, 'print.defaultPaper', PrintPaper.tryParse),
    qrEnabled: jBool(j, 'qr.enabled'),
    customerStockDisplay: jEnum(j, 'customerStockDisplay', CustomerStockDisplay.tryParse),
    supportContacts: j['supportContacts'] == null
        ? null
        : jObjects(
            j,
            'supportContacts',
            (JsonMap s) => SupportContactValue(
              kind: jReq<String>(s, 'kind'),
              value: jReq<String>(s, 'value'),
              label: jOpt<String>(s, 'label'),
            ),
          ),
  );

  /// Тело `settings` для `PUT /admin/settings` — только заданные значения.
  static JsonMap toJson(AdminSettingsValues v) => <String, dynamic>{
    'lowStockThreshold': ?v.lowStockThreshold,
    'cartStaleMinutes': ?v.cartStaleMinutes,
    'parkedCartTtlDays': ?v.parkedCartTtlDays,
    'overpayAllowed': ?v.overpayAllowed,
    if (v.returnApprovalThreshold != null) 'returnApprovalThreshold': moneyJson(v.returnApprovalThreshold!),
    'returnsEnabled': ?v.returnsEnabled,
    'cashRounding': ?v.cashRounding,
    if (v.deliverySlots != null)
      'deliverySlots': <JsonMap>[
        for (final DeliverySlotValue s in v.deliverySlots!) <String, dynamic>{'from': s.from, 'to': s.to},
      ],
    'receivables.maxAgeMinutes': ?v.receivablesMaxAgeMinutes,
    'minAppVersion': ?v.minAppVersion,
    'recommendedAppVersion': ?v.recommendedAppVersion,
    'secureScreens': ?v.secureScreens,
    'privacyContact': ?v.privacyContact,
    for (final MapEntry<String, int> e in v.syncIntervals.entries)
      if (syncEntities.contains(e.key)) 'syncInterval.${e.key}': e.value,
    'otp.ttlSeconds': ?v.otpTtlSeconds,
    'otp.maxAttempts': ?v.otpMaxAttempts,
    'session.staffRefreshDays': ?v.sessionStaffRefreshDays,
    'consentTexts': ?v.consentTexts,
    'categoryIcons': ?v.categoryIcons,
    'attributeCodes': ?v.attributeCodes,
    if (v.printDefaultPaper != null) 'print.defaultPaper': v.printDefaultPaper!.value,
    'qr.enabled': ?v.qrEnabled,
    if (v.customerStockDisplay != null) 'customerStockDisplay': v.customerStockDisplay!.value,
    if (v.supportContacts != null)
      'supportContacts': <JsonMap>[
        for (final SupportContactValue c in v.supportContacts!)
          <String, dynamic>{'kind': c.kind, 'value': c.value, 'label': ?c.label},
      ],
  };
}

/// `AdminSettingsEnv`.
abstract final class AdminSettingsEnvDto {
  static const Set<String> jsonKeys = {
    'customerSelfService',
    'debtPaymentsFromPos',
    'qrProvider',
    'qrTtlMinutes',
    'qrOnecPollSeconds',
    'receivablesMaxAgeMin',
    'minAppVersion',
    'recommendedAppVersion',
    'otpTtlSeconds',
    'otpResendCooldownSeconds',
    'otpMaxVerifyAttempts',
    'otpGlobalPerMin',
    'otpLockAfterLockedCodes',
    'otpPhonePauseMinutes',
    'sessionIdleLockMinutes',
    'authBackgroundLockMinutes',
    'smsSenderName',
  };
  static const Set<String> requiredKeys = <String>{};

  static AdminSettingsEnv fromJson(JsonMap j) => AdminSettingsEnv(
    customerSelfService: jBool(j, 'customerSelfService'),
    debtPaymentsFromPos: jBool(j, 'debtPaymentsFromPos'),
    qrProvider: jEnum(j, 'qrProvider', QrProviderMode.tryParse),
    qrTtlMinutes: jInt(j, 'qrTtlMinutes'),
    qrOnecPollSeconds: jInt(j, 'qrOnecPollSeconds'),
    receivablesMaxAgeMin: jInt(j, 'receivablesMaxAgeMin'),
    minAppVersion: jOpt<String>(j, 'minAppVersion'),
    recommendedAppVersion: jOpt<String>(j, 'recommendedAppVersion'),
    otpTtlSeconds: jInt(j, 'otpTtlSeconds'),
    otpResendCooldownSeconds: jInt(j, 'otpResendCooldownSeconds'),
    otpMaxVerifyAttempts: jInt(j, 'otpMaxVerifyAttempts'),
    otpGlobalPerMin: jInt(j, 'otpGlobalPerMin'),
    otpLockAfterLockedCodes: jInt(j, 'otpLockAfterLockedCodes'),
    otpPhonePauseMinutes: jInt(j, 'otpPhonePauseMinutes'),
    sessionIdleLockMinutes: jInt(j, 'sessionIdleLockMinutes'),
    authBackgroundLockMinutes: jInt(j, 'authBackgroundLockMinutes'),
    smsSenderName: jOpt<String>(j, 'smsSenderName'),
  );
}

/// `AdminSettingsResponse` / `AdminSettingsUpdateRequest`.
abstract final class AdminSettingsDto {
  static const Set<String> jsonKeys = {'settings', 'env', 'rowVersion'};
  static const Set<String> requiredKeys = {'settings', 'env', 'rowVersion'};
  static const Set<String> updateKeys = {'settings', 'rowVersion'};

  static AdminSettings fromJson(JsonMap j) => AdminSettings(
    values: AdminSettingsValuesDto.fromJson(jReqObject(j, 'settings')),
    env: AdminSettingsEnvDto.fromJson(jReqObject(j, 'env')),
    rowVersion: jReqInt(j, 'rowVersion'),
  );

  static JsonMap toUpdateJson(AdminSettingsValues values, {required int rowVersion}) => <String, dynamic>{
    'settings': AdminSettingsValuesDto.toJson(values),
    'rowVersion': rowVersion,
  };
}
