// `AdminSettingsRepository` и `AuditLogRepository` поверх единственного Dio-клиента (SCR-46, SCR-47). Ошибки →
// Failure только через ErrorMapper (06 §6.8); stepUpToken нигде не сохраняется.
import 'package:dio/dio.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/audit_record.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/cancel_signal_dio.dart';
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/core/network/models/pos_common_dtos.dart';
import 'package:optomstroy/core/network/models/transaction_dtos.dart';
import 'package:optomstroy/core/utils/cancel_signal.dart';
import 'package:optomstroy/features/admin/data/settings/admin_settings_dtos.dart';
import 'package:optomstroy/features/admin/domain/audit/audit_log.dart';
import 'package:optomstroy/features/admin/domain/settings/admin_settings.dart';
import 'package:optomstroy/features/admin/domain/settings/admin_settings_repository.dart';

/// Пути API SCR-46/SCR-47 (08 §4.18.5–§4.18.7).
abstract final class AdminSettingsApiPaths {
  static const String settings = '/admin/settings';
  static const String discountLimits = '/admin/discount-limits';
  static const String auditLogs = '/admin/audit-logs';
}

Options _opts({String? idempotencyKey, String? stepUpToken}) {
  final Options o = apiOptions(idempotencyKey: idempotencyKey);
  if (stepUpToken != null) o.headers![ApiHeaders.stepUpToken] = stepUpToken; // check-secrets: allow (имя заголовка)
  return o;
}

final class DioAdminSettingsRepository implements AdminSettingsRepository {
  DioAdminSettingsRepository(this._dio);

  final Dio _dio;

  @override
  Future<Result<AdminSettings>> settings() => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.get<Object?>(AdminSettingsApiPaths.settings, options: _opts());
    return AdminSettingsDto.fromJson(jsonObject(r.data));
  });

  @override
  Future<Result<AdminSettings>> updateSettings(
    AdminSettingsValues values, {
    required int rowVersion,
    String? idempotencyKey,
    String? stepUpToken,
  }) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.put<Object?>(
      AdminSettingsApiPaths.settings,
      data: AdminSettingsDto.toUpdateJson(values, rowVersion: rowVersion),
      options: _opts(idempotencyKey: idempotencyKey, stepUpToken: stepUpToken),
    );
    return AdminSettingsDto.fromJson(jsonObject(r.data));
  });

  @override
  Future<Result<AdminDiscountLimits>> discountLimits() => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.get<Object?>(AdminSettingsApiPaths.discountLimits, options: _opts());
    return AdminDiscountLimitsDto.fromJson(jsonObject(r.data));
  });

  @override
  Future<Result<AdminDiscountLimits>> updateDiscountLimits(
    AdminDiscountLimits limits, {
    String? idempotencyKey,
    String? stepUpToken,
  }) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.put<Object?>(
      AdminSettingsApiPaths.discountLimits,
      data: AdminDiscountLimitsDto.toUpdateJson(limits),
      options: _opts(idempotencyKey: idempotencyKey, stepUpToken: stepUpToken),
    );
    return AdminDiscountLimitsDto.fromJson(jsonObject(r.data));
  });
}

final class DioAuditLogRepository implements AuditLogRepository {
  DioAuditLogRepository(this._dio);

  final Dio _dio;

  /// Query `GET /admin/audit-logs` (вынесено для теста).
  static Map<String, Object?> queryOf(AuditQuery q) => <String, Object?>{
    'from': isoUtc(q.period.from),
    'to': isoUtc(q.period.to),
    'actorId': ?q.actorId,
    if (q.action != null && q.action!.isNotEmpty) 'action': q.action,
    if (q.entityType != null && q.entityType!.isNotEmpty) 'entityType': q.entityType,
    if (q.entityId != null && q.entityId!.isNotEmpty) 'entityId': q.entityId,
    if (q.result != null) 'result': q.result!.value,
    'limit': ?q.limit,
    'cursor': ?q.cursor,
  };

  @override
  Future<Result<PageResult<AuditRecord>>> list(AuditQuery query, {CancelSignal? cancel}) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.get<Object?>(
      AdminSettingsApiPaths.auditLogs,
      queryParameters: queryOf(query),
      options: _opts(),
      cancelToken: dioCancelToken(cancel),
    );
    return PageDto.fromJson(jsonObject(r.data), AuditRowDto.fromJson);
  });
}
