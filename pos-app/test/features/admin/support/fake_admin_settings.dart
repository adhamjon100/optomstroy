// Фейки портов SCR-46 (настройки и лимиты скидок) и SCR-47 (журнал аудита) для widget/golden-тестов этапа G.
// Step-up: изменение требует токен из [FakeAdminSettingsRepository.validTokens], иначе `403 STEP_UP_REQUIRED`.
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/audit_record.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/cancel_signal.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/admin/domain/audit/audit_log.dart';
import 'package:optomstroy/features/admin/domain/settings/admin_settings.dart';
import 'package:optomstroy/features/admin/domain/settings/admin_settings_repository.dart';
import 'package:optomstroy/features/admin/presentation/settings/admin_settings_controller.dart';

import 'fake_admin_repository.dart';

const AdminSettingsValues seedValues = AdminSettingsValues(
  lowStockThreshold: 5,
  cartStaleMinutes: 30,
  parkedCartTtlDays: 7,
  overpayAllowed: false,
  returnsEnabled: true,
  cashRounding: 'none',
  receivablesMaxAgeMinutes: 60,
  minAppVersion: 'android=1.0.0,windows=1.0.0',
  recommendedAppVersion: 'android=1.1.0,windows=1.1.0',
  privacyContact: 'dpo@example.kg',
  syncIntervals: <String, int>{'stock': 600, 'prices': 1800},
  otpTtlSeconds: 300,
  otpMaxAttempts: 5,
  sessionStaffRefreshDays: 7,
  printDefaultPaper: PrintPaper.thermal80,
  qrEnabled: true,
  customerStockDisplay: CustomerStockDisplay.status,
);

const AdminSettingsEnv seedEnv = AdminSettingsEnv(
  customerSelfService: true,
  debtPaymentsFromPos: false,
  qrProvider: QrProviderMode.onec,
  qrTtlMinutes: 10,
  receivablesMaxAgeMin: 60,
  minAppVersion: 'android=1.0.0,windows=1.0.0',
  otpTtlSeconds: 300,
  sessionIdleLockMinutes: 30,
  smsSenderName: 'OPTOMSTROY',
);

AdminDiscountLimits seedLimits() => AdminDiscountLimits(
  limits: const <RoleCode, Percent>{
    RoleCode.seller: Percent(500),
    RoleCode.cashier: Percent(500),
    RoleCode.seniorSeller: Percent(1000),
    RoleCode.admin: Percent(1500),
    RoleCode.owner: Percent(1500),
  },
  overrideRoles: const <RoleCode>[RoleCode.seniorSeller, RoleCode.admin, RoleCode.owner],
  rowVersion: 3,
  updatedAt: t0.subtract(const Duration(days: 2)),
  updatedBy: const UserRef(id: adminId, displayName: 'Г. Администратор', role: RoleCode.admin),
);

/// Фейк [AdminSettingsRepository].
final class FakeAdminSettingsRepository implements AdminSettingsRepository {
  FakeAdminSettingsRepository({AdminSettings? settings, AdminDiscountLimits? limits, this.failLoad})
    : current = settings ?? const AdminSettings(values: seedValues, env: seedEnv, rowVersion: 11),
      limits = limits ?? seedLimits();

  AdminSettings current;
  AdminDiscountLimits limits;
  Failure? failLoad;

  /// Следующее сохранение настроек ответит этим отказом (один раз).
  Failure? nextSettingsFailure;
  final Set<String> validTokens = <String>{'step-up-token'};
  final List<RepoCall> calls = <RepoCall>[];
  AdminSettingsValues? lastValues;
  AdminDiscountLimits? lastLimits;

  Result<T>? _gate<T>(String? token, String operation) =>
      token != null && validTokens.contains(token) ? null : FailureResult<T>(stepUpRequired(operation));

  @override
  Future<Result<AdminSettings>> settings() async {
    calls.add(const RepoCall('settings'));
    if (failLoad != null) return FailureResult<AdminSettings>(failLoad!);
    return Success<AdminSettings>(current);
  }

  @override
  Future<Result<AdminDiscountLimits>> discountLimits() async {
    calls.add(const RepoCall('discountLimits'));
    if (failLoad != null) return FailureResult<AdminDiscountLimits>(failLoad!);
    return Success<AdminDiscountLimits>(limits);
  }

  @override
  Future<Result<AdminSettings>> updateSettings(
    AdminSettingsValues values, {
    required int rowVersion,
    String? idempotencyKey,
    String? stepUpToken,
  }) async {
    calls.add(RepoCall('updateSettings', idempotencyKey: idempotencyKey, stepUpToken: stepUpToken));
    final Result<AdminSettings>? gate = _gate<AdminSettings>(stepUpToken, AdminSettingsOperations.appUpdate);
    if (gate != null) return gate;
    final Failure? fail = nextSettingsFailure;
    if (fail != null) {
      nextSettingsFailure = null;
      return FailureResult<AdminSettings>(fail);
    }
    lastValues = values;
    current = AdminSettings(
      values: AdminSettingsValues(
        lowStockThreshold: values.lowStockThreshold ?? current.values.lowStockThreshold,
        receivablesMaxAgeMinutes: values.receivablesMaxAgeMinutes ?? current.values.receivablesMaxAgeMinutes,
        syncIntervals: <String, int>{...current.values.syncIntervals, ...values.syncIntervals},
        minAppVersion: values.minAppVersion ?? current.values.minAppVersion,
        recommendedAppVersion: values.recommendedAppVersion ?? current.values.recommendedAppVersion,
      ),
      env: current.env,
      rowVersion: rowVersion + 1,
    );
    return Success<AdminSettings>(current);
  }

  @override
  Future<Result<AdminDiscountLimits>> updateDiscountLimits(
    AdminDiscountLimits limits, {
    String? idempotencyKey,
    String? stepUpToken,
  }) async {
    calls.add(RepoCall('updateDiscountLimits', idempotencyKey: idempotencyKey, stepUpToken: stepUpToken));
    final Result<AdminDiscountLimits>? gate = _gate<AdminDiscountLimits>(
      stepUpToken,
      AdminSettingsOperations.discountLimitsUpdate,
    );
    if (gate != null) return gate;
    lastLimits = limits;
    this.limits = AdminDiscountLimits(
      limits: limits.limits,
      overrideRoles: limits.overrideRoles,
      rowVersion: limits.rowVersion + 1,
      updatedAt: t0,
      updatedBy: limits.updatedBy,
    );
    return Success<AdminDiscountLimits>(this.limits);
  }
}

/// Фейк [AuditLogRepository].
final class FakeAuditLogRepository implements AuditLogRepository {
  FakeAuditLogRepository({List<AuditRecord>? records, this.failure}) : records = records ?? seedAudit();

  List<AuditRecord> records;
  Failure? failure;
  final List<AuditQuery> queries = <AuditQuery>[];
  final List<CancelSignal?> cancels = <CancelSignal?>[];

  @override
  Future<Result<PageResult<AuditRecord>>> list(AuditQuery query, {CancelSignal? cancel}) async {
    queries.add(query);
    cancels.add(cancel);
    if (failure != null) return FailureResult<PageResult<AuditRecord>>(failure!);
    final List<AuditRecord> items = records
        .where((AuditRecord r) => query.action == null || r.action.startsWith(query.action!))
        .where((AuditRecord r) => query.result == null || r.result == query.result)
        .toList();
    return Success<PageResult<AuditRecord>>(PageResult<AuditRecord>(items: items));
  }
}

/// Записи аудита: изменение ролей (с причиной), просмотр финансов (маска для `admin`), запись с разрывом цепочки,
/// неизвестное событие.
List<AuditRecord> seedAudit() => <AuditRecord>[
  AuditRecord(
    id: 'a1',
    occurredAt: t0.add(const Duration(minutes: 42, seconds: 17)),
    action: 'user.role_changed',
    result: AuditResult.ok,
    chainOk: true,
    actor: const UserRef(id: adminId, displayName: 'Гульнара Админова'),
    actorRole: RoleCode.admin,
    deviceId: 'dev-kassa-1',
    entityType: 'user',
    entityId: cashierId,
    before: const <String, Object?>{'roles': 'seller'},
    after: const <String, Object?>{'roles': 'cashier'},
    reason: 'Перевод на кассу',
    stepUpMethod: StepUpMethod.pin,
    requestId: 'req-1',
    rowHash: 'a1b2c3d4e5f60718293a4b5c6d7e8f90',
  ),
  AuditRecord(
    id: 'a2',
    occurredAt: t0.add(const Duration(minutes: 30, seconds: 5)),
    action: 'customer.finance_view',
    result: AuditResult.ok,
    chainOk: true,
    actor: const UserRef(id: cashierId, displayName: 'Иван Петров'),
    actorRole: RoleCode.cashier,
    entityType: 'customer',
    entityId: 'cust-1',
    before: const <String, Object?>{'balance': '***'},
    after: const <String, Object?>{'balance': '***'},
  ),
  AuditRecord(
    id: 'a3',
    occurredAt: t0.add(const Duration(minutes: 12, seconds: 59)),
    action: 'discount.over_limit_approved',
    result: AuditResult.denied,
    chainOk: false,
    actor: const UserRef(id: ownerId, displayName: 'Нурлан Руководитель'),
    actorRole: RoleCode.owner,
    entityType: 'order',
    entityId: '1024',
  ),
  AuditRecord(
    id: 'a4',
    occurredAt: t0.subtract(const Duration(hours: 1)),
    action: 'mystery.event',
    result: null,
    chainOk: true,
  ),
];
