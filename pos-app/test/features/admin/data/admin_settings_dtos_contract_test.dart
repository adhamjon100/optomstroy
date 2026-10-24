// Этап G (основа), ADR-085: DTO SCR-46/SCR-47 (`AdminDiscountLimits`, `AdminSettingsResponse`, значения и env,
// тела `PUT`, `GET /admin/audit-logs`) == contracts/openapi/pos-api.v1.yaml 1.2.0; изменения — со step-up.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/models/journal_period.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/admin/data/settings/admin_settings_dtos.dart';
import 'package:optomstroy/features/admin/data/settings/dio_admin_settings_repository.dart';
import 'package:optomstroy/features/admin/domain/audit/audit_log.dart';
import 'package:optomstroy/features/admin/domain/settings/admin_settings.dart';

import '../../../core/network/fake_adapter.dart';
import '../../../support/openapi_schemas.dart';

const List<String> _schemas = <String>[
  'AdminDiscountLimits',
  'AdminDiscountLimitsByRole',
  'AdminDiscountLimitsUpdateRequest',
  'AdminSettingsResponse',
  'AdminSettingsValues',
  'AdminSettingsEnv',
  'AdminSettingsUpdateRequest',
];

void main() {
  final OpenApiSchemas? api = OpenApiSchemas.load(_schemas);
  final String? skip = api == null ? 'нет python с PyYAML — сверка DTO невозможна' : null;

  void matches(String name, Set<String> keys, Set<String> required) {
    expect(keys, api!.props(name), reason: '$name: ключи DTO ≠ properties');
    expect(required, api.required(name), reason: '$name: required DTO ≠ required схемы');
  }

  test('ключи и обязательные поля == схемы OpenAPI 1.2.0', () {
    matches('AdminDiscountLimits', AdminDiscountLimitsDto.jsonKeys, AdminDiscountLimitsDto.requiredKeys);
    matches('AdminDiscountLimitsByRole', DiscountLimitsByRoleDto.jsonKeys, DiscountLimitsByRoleDto.requiredKeys);
    matches('AdminDiscountLimitsUpdateRequest', AdminDiscountLimitsDto.updateKeys, AdminDiscountLimitsDto.updateKeys);
    matches('AdminSettingsResponse', AdminSettingsDto.jsonKeys, AdminSettingsDto.requiredKeys);
    matches('AdminSettingsValues', AdminSettingsValuesDto.jsonKeys, AdminSettingsValuesDto.requiredKeys);
    matches('AdminSettingsEnv', AdminSettingsEnvDto.jsonKeys, AdminSettingsEnvDto.requiredKeys);
    matches('AdminSettingsUpdateRequest', AdminSettingsDto.updateKeys, AdminSettingsDto.updateKeys);
  }, skip: skip);

  test('примеры разбираются; тело PUT /admin/settings — только ключи AdminSettingsValues', () {
    final AdminSettings s = AdminSettingsDto.fromJson(jsonCopy(api!.example('AdminSettingsResponse')));
    expect(s.values.returnApprovalThreshold, isA<Money>());
    expect(s.values.syncIntervals, hasLength(AdminSettingsValuesDto.syncEntities.length));
    expect(s.env.customerSelfService, isTrue);
    final Map<String, dynamic> body = AdminSettingsDto.toUpdateJson(s.values, rowVersion: s.rowVersion);
    final Map<String, dynamic> settings = body['settings'] as Map<String, dynamic>;
    expect(api.props('AdminSettingsValues').containsAll(settings.keys), isTrue, reason: settings.keys.toString());
    final AdminDiscountLimits l = AdminDiscountLimitsDto.fromJson(jsonCopy(api.example('AdminDiscountLimits')));
    expect(l.limits.keys.toSet(), discountLimitRoles.toSet());
    expect(AdminDiscountLimitsDto.toUpdateJson(l).keys.toSet(), AdminDiscountLimitsDto.updateKeys);
  }, skip: skip);

  test('PUT /admin/discount-limits: X-Step-Up-Token и Idempotency-Key; аудит — период обязателен', () async {
    final List<RequestOptions> seen = <RequestOptions>[];
    final FakeAdapter adapter = FakeAdapter((RequestOptions o) async {
      seen.add(o);
      if (o.path.endsWith('audit-logs')) {
        return json(200, <String, Object?>{'items': <Object?>[], 'nextCursor': null, 'hasMore': false});
      }
      return json(200, <String, Object?>{
        'limits': <String, String>{
          'seller': '5.00',
          'cashier': '5.00',
          'senior_seller': '10.00',
          'admin': '15.00',
          'owner': '0.00',
        },
        'overrideRoles': <String>['senior_seller', 'admin'],
        'rowVersion': 2,
      });
    });
    final Dio dio = Dio(BaseOptions(baseUrl: 'http://pos.test/api/v1'))..httpClientAdapter = adapter;
    final AdminDiscountLimits updated = (await DioAdminSettingsRepository(dio).updateDiscountLimits(
      const AdminDiscountLimits(
        limits: <RoleCode, Percent>{RoleCode.seller: Percent(700)},
        overrideRoles: <RoleCode>[RoleCode.seniorSeller, RoleCode.admin],
        rowVersion: 1,
      ),
      idempotencyKey: 'k1',
      stepUpToken: 'su',
    )).valueOrNull!;
    expect(updated.limits[RoleCode.seniorSeller], const Percent(1000));
    expect(adapter.requests.first.headers[ApiHeaders.stepUpToken], 'su');
    expect(adapter.requests.first.headers[ApiHeaders.idempotencyKey], 'k1');
    expect((adapter.requests.first.data! as Map<String, dynamic>)['limits'], <String, String>{
      'seller': '7.00',
      'cashier': '0.00',
      'senior_seller': '0.00',
      'admin': '0.00',
      'owner': '0.00',
    });

    final JournalPeriod period = JournalPeriod.tryCreate(DateTime.utc(2026, 10), DateTime.utc(2026, 10, 2))!;
    await DioAuditLogRepository(dio).list(AuditQuery(period: period, actorId: 'u1', result: AuditResult.denied));
    final Map<String, String> q = seen.last.uri.queryParameters;
    expect(
      (q['from'], q['to'], q['actorId'], q['result']),
      ('2026-10-01T00:00:00.000Z', '2026-10-02T00:00:00.000Z', 'u1', 'denied'),
    );
  });
}
