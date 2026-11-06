// SCR-54 «Планшеты магазина» поверх единственного Dio-клиента (08 §3.17, §4.18.11–§4.18.15, §4.4.6; OpenAPI 1.3.0
// `StoreTablet`, `KioskTokens`, `KioskTabletsListResponse`, `KioskTabletsEnrollRequest`, `KioskTabletsUpdateRequest`,
// `KioskTabletsRevokeRequest`, `CatalogWarehouse`; ADR-085 — DTO вручную). Ошибки → Failure только через ErrorMapper
// (06 §6.8). Тела ответов (токены планшета, аварийный код) не логируются (LoggingInterceptor пишет метод, путь,
// статус) и нигде не сохраняются: код живёт только в памяти диалога SCR-54, токены сохраняет сессия планшета.
// Сверка ключей DTO — test/features/admin/tablets/enroll_flow_test.dart.
import 'package:dio/dio.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/dto_json.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/features/admin/domain/tablets/admin_tablets_repository.dart';
import 'package:optomstroy/features/admin/domain/tablets/store_tablet.dart';

/// Пути API SCR-54.
abstract final class AdminTabletsApiPaths {
  static const String tablets = '/admin/store-tablets';
  static const String warehouses = '/catalog/warehouses';

  static String tablet(String id) => '$tablets/${Uri.encodeComponent(id)}';
  static String reconnect(String id) => '${tablet(id)}/reconnect';
  static String revoke(String id) => '${tablet(id)}/revoke';
}

/// `StoreTablet` (все поля присутствуют всегда, nullable — как `null`).
abstract final class StoreTabletDto {
  static const Set<String> jsonKeys = {
    'id',
    'name',
    'warehouseId',
    'status',
    'enrolledAt',
    'reconnectedAt',
    'revokedAt',
    'lastSeenAt',
    'lockTaskEnabled',
    'appVersion',
    'expiresAt',
  };
  static const Set<String> requiredKeys = jsonKeys;

  static StoreTablet fromJson(JsonMap j) => StoreTablet(
    id: jReq<String>(j, 'id'),
    name: jReq<String>(j, 'name'),
    warehouseId: jReq<String>(j, 'warehouseId'),
    status: jReqEnum(j, 'status', StoreTabletStatus.tryParse),
    enrolledAt: jReqDate(j, 'enrolledAt'),
    reconnectedAt: jDate(j, 'reconnectedAt'),
    revokedAt: jDate(j, 'revokedAt'),
    lastSeenAt: jDate(j, 'lastSeenAt'),
    lockTaskEnabled: jBool(j, 'lockTaskEnabled'),
    appVersion: jOpt<String>(j, 'appVersion'),
    expiresAt: jDate(j, 'expiresAt'),
  );
}

/// `KioskTabletsListResponse`.
abstract final class StoreTabletsListDto {
  static const Set<String> jsonKeys = {'items'};
  static const Set<String> requiredKeys = jsonKeys;

  static List<StoreTablet> fromJson(JsonMap j) => jObjects(j, 'items', StoreTabletDto.fromJson, required: true);
}

/// `KioskTokens`.
abstract final class KioskTokensDto {
  static const Set<String> jsonKeys = {
    'tablet',
    'accessToken',
    'accessExpiresIn',
    'refreshToken',
    'refreshExpiresAt',
    'sid',
    'exitCode',
  };
  static const Set<String> requiredKeys = jsonKeys;

  static KioskEnrollment fromJson(JsonMap j) {
    final String code = jReq<String>(j, 'exitCode');
    if (!KioskEnrollment.exitCodePattern.hasMatch(code)) throw const DtoFormatException('exitCode');
    return KioskEnrollment(
      tablet: StoreTabletDto.fromJson(jReqObject(j, 'tablet')),
      accessToken: jReq<String>(j, 'accessToken'), // check-secrets: allow (разбор ответа, не значение)
      refreshToken: jReq<String>(j, 'refreshToken'), // check-secrets: allow (разбор ответа, не значение)
      exitCode: code,
      sessionId: jOpt<String>(j, 'sid'),
    );
  }
}

/// Тела запросов: `KioskTabletsEnrollRequest`, `KioskTabletsUpdateRequest`, `KioskTabletsRevokeRequest`.
abstract final class StoreTabletRequestDto {
  static const Set<String> enrollKeys = {'name', 'warehouseId'};
  static const Set<String> updateKeys = {'name', 'warehouseId'};
  static const Set<String> revokeKeys = {'reason'};

  static JsonMap enroll({required String name, required String warehouseId}) => <String, dynamic>{
    'name': name.trim(),
    'warehouseId': warehouseId,
  };

  static JsonMap update({String? name, String? warehouseId}) => <String, dynamic>{
    if (name != null) 'name': name.trim(),
    'warehouseId': ?warehouseId,
  };
}

/// `CatalogWarehouse` / `CatalogWarehousesResponse`.
abstract final class TabletWarehouseDto {
  static const Set<String> jsonKeys = {'id', 'name', 'code', 'isActive', 'isDefaultForPos'};
  static const Set<String> requiredKeys = {'id', 'name'};

  static TabletWarehouse fromJson(JsonMap j) => TabletWarehouse(
    id: jReq<String>(j, 'id'),
    name: jReq<String>(j, 'name'),
    isActive: jBool(j, 'isActive') ?? true,
    isDefaultForPos: jBool(j, 'isDefaultForPos') ?? false,
  );

  static List<TabletWarehouse> listFromJson(JsonMap j) => jObjects(j, 'items', fromJson, required: true);
}

Options _opts({String? idempotencyKey, String? stepUpToken}) {
  final Options o = apiOptions(idempotencyKey: idempotencyKey);
  if (stepUpToken != null) o.headers![ApiHeaders.stepUpToken] = stepUpToken; // check-secrets: allow (имя заголовка)
  return o;
}

final class DioAdminTabletsRepository implements AdminTabletsRepository {
  DioAdminTabletsRepository(this._dio);

  final Dio _dio;

  @override
  Future<Result<List<StoreTablet>>> list() => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.get<Object?>(AdminTabletsApiPaths.tablets, options: _opts());
    return StoreTabletsListDto.fromJson(jsonObject(r.data));
  });

  @override
  Future<Result<List<TabletWarehouse>>> warehouses() => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.get<Object?>(AdminTabletsApiPaths.warehouses, options: _opts());
    return TabletWarehouseDto.listFromJson(jsonObject(r.data));
  });

  @override
  Future<Result<KioskEnrollment>> enroll({
    required String name,
    required String warehouseId,
    required String idempotencyKey,
    String? stepUpToken,
  }) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.post<Object?>(
      AdminTabletsApiPaths.tablets,
      data: StoreTabletRequestDto.enroll(name: name, warehouseId: warehouseId),
      options: _opts(idempotencyKey: idempotencyKey, stepUpToken: stepUpToken),
    );
    return KioskTokensDto.fromJson(jsonObject(r.data));
  });

  @override
  Future<Result<KioskEnrollment>> reconnect(String id, {required String idempotencyKey, String? stepUpToken}) =>
      ErrorMapper.guard(() async {
        final Response<Object?> r = await _dio.post<Object?>(
          AdminTabletsApiPaths.reconnect(id),
          data: const <String, dynamic>{},
          options: _opts(idempotencyKey: idempotencyKey, stepUpToken: stepUpToken),
        );
        return KioskTokensDto.fromJson(jsonObject(r.data));
      });

  @override
  Future<Result<StoreTablet>> update(String id, {String? name, String? warehouseId}) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.patch<Object?>(
      AdminTabletsApiPaths.tablet(id),
      data: StoreTabletRequestDto.update(name: name, warehouseId: warehouseId),
      options: _opts(),
    );
    return StoreTabletDto.fromJson(jsonObject(r.data));
  });

  @override
  Future<Result<StoreTablet>> revoke(String id, {String? stepUpToken}) => ErrorMapper.guard(() async {
    final Response<Object?> r = await _dio.post<Object?>(
      AdminTabletsApiPaths.revoke(id),
      options: _opts(stepUpToken: stepUpToken),
    );
    return StoreTabletDto.fromJson(jsonObject(r.data));
  });
}
