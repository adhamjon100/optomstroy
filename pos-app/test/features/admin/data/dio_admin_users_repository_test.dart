// Data-слой SCR-45 поверх настоящего DioClient (интерсепторы core) и фейкового транспорта:
// пути, заголовки Idempotency-Key / X-Step-Up-Token, тела запросов, разбор ответов и ошибок.
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/app_version/app_version_controller.dart';
import 'package:optomstroy/core/network/auth/token_store.dart';
import 'package:optomstroy/core/network/client_meta.dart';
import 'package:optomstroy/core/network/dio_client.dart';
import 'package:optomstroy/core/network/etag_cache.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/features/admin/data/users/dio_admin_users_repository.dart';
import 'package:optomstroy/features/admin/data/users/dio_step_up_gateway.dart';
import 'package:optomstroy/features/admin/domain/users/admin_user.dart';
import 'package:optomstroy/features/admin/domain/users/emergency_login_code.dart';
import 'package:optomstroy/features/admin/domain/users/invitation.dart';

import '../../../core/network/fake_adapter.dart';
import '../../../core/storage/in_memory_secure_storage.dart';

const _meta = ClientMeta(
  appVersion: '0.1.0+1',
  platform: ClientPlatform.windows,
  deviceId: '1b4e28ba-2d11-4d4f-9f4a-0c3a6f6e7d01',
);
final _config = AppConfig.fromMap(const {'API_BASE_URL': 'https://api.test/api/v1', 'ENV': 'staging'});

const _userId = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f01';

Map<String, Object?> adminUserJson({String id = _userId, String status = 'active', String role = 'cashier'}) => {
  'id': id,
  'kind': 'staff',
  'status': status,
  'phoneMasked': '+996700000001',
  'fullName': 'Иван Петров',
  'roles': [role],
  'permissionsVersion': 3,
  'lastLoginAt': '2026-10-22T03:12:00.000Z',
  'devicesCount': 2,
  'createdAt': '2026-09-01T00:00:00.000Z',
  'invitation': {'status': 'accepted', 'createdAt': '2026-08-31T00:00:00.000Z'},
  'rowVersion': 7,
};

final class _Harness {
  _Harness(FakeHandler handler) {
    adapter = FakeAdapter(handler);
    final storage = InMemorySecureStorage({SecureKey.refreshToken: 'r0'}); // check-secrets: allow (тест)
    final tokens = TokenStore(storage);
    unawaited(tokens.saveTokens(accessToken: 'a0', refreshToken: 'r0')); // check-secrets: allow (тест)
    dio = DioClient.create(
      DioClientDeps(
        config: _config,
        meta: () => _meta,
        tokens: tokens,
        appVersion: AppVersionController(currentVersion: '0.1.0+1', platform: 'windows', sink: (k, v) async {}),
        etagCache: EtagCache(),
        adapter: adapter,
        logger: logger,
        sleep: (d) async {},
      ),
    );
    repo = DioAdminUsersRepository(dio);
    gateway = DioStepUpGateway(dio);
  }

  late final FakeAdapter adapter;
  late final Dio dio;
  late final DioAdminUsersRepository repo;
  late final DioStepUpGateway gateway;
  final Logger logger = Logger.detached('admin-test')..level = Level.ALL;
}

Map<String, Object?> _body(Object? data) => data is String
    ? jsonDecode(data) as Map<String, Object?>
    : (data as Map<Object?, Object?>?)?.cast<String, Object?>() ?? const {};

void main() {
  test('GET /admin/users: kind=staff, фильтры и поиск; разбор Page<AdminUser>', () async {
    late RequestOptions sent;
    final h = _Harness((o) async {
      sent = o;
      return json(200, {
        'items': [adminUserJson()],
        'nextCursor': 'c2',
        'hasMore': true,
        'totalEstimate': 18,
      });
    });
    final r = await h.repo.listUsers(
      const AdminUsersQuery(q: '700 000', role: RoleCode.cashier, status: UserStatus.active),
    );
    expect(sent.uri.path, '/api/v1/admin/users');
    expect(sent.uri.queryParameters, {
      'kind': 'staff',
      'limit': '50',
      'q': '700 000',
      'role': 'cashier',
      'status': 'active',
    });
    final page = r.valueOrNull!;
    expect(page.count, 18);
    expect(page.nextCursor, 'c2');
    final u = page.items.single;
    expect(u.roleCodes, [RoleCode.cashier]);
    expect(u.hasFullPhone, isTrue);
    expect(u.rowVersion, 7);
    expect(u.invitation?.status, 'accepted');
    expect(u.lastLoginAt, DateTime.utc(2026, 10, 22, 3, 12));
  });

  test('короткий поиск (1 буква) не отправляется в q', () async {
    late RequestOptions sent;
    final h = _Harness((o) async {
      sent = o;
      return json(200, {'items': <Object?>[], 'nextCursor': null, 'hasMore': false});
    });
    await h.repo.listUsers(const AdminUsersQuery(q: 'И'));
    expect(sent.uri.queryParameters.containsKey('q'), isFalse);
  });

  test('PUT …/roles: Idempotency-Key, X-Step-Up-Token, тело {roles, reason, rowVersion}', () async {
    late RequestOptions sent;
    final h = _Harness((o) async {
      sent = o;
      return json(200, adminUserJson(role: 'senior_seller'));
    });
    final r = await h.repo.setRoles(
      _userId,
      roles: [RoleCode.seniorSeller],
      reason: 'перевод на старшего',
      rowVersion: 7,
      idempotencyKey: 'k-1',
      stepUpToken: 'su-1',
    );
    expect(sent.method, 'PUT');
    expect(sent.uri.path, '/api/v1/admin/users/$_userId/roles');
    expect(sent.headers[ApiHeaders.idempotencyKey], 'k-1');
    expect(sent.headers[ApiHeaders.stepUpToken], 'su-1');
    expect(_body(sent.data), {
      'roles': ['senior_seller'],
      'reason': 'перевод на старшего',
      'rowVersion': 7,
    });
    expect(r.valueOrNull?.roleCodes, [RoleCode.seniorSeller]);
  });

  test('403 STEP_UP_REQUIRED → AuthFailure(stepUpRequired) с operation', () async {
    final h = _Harness(
      (o) async => json(
        403,
        problem(
          'STEP_UP_REQUIRED',
          403,
          extra: {
            'stepUp': {
              'operation': 'users.roles.assign',
              'allowedMethods': ['pin', 'otp'],
            },
          },
        ),
      ),
    );
    final r = await h.repo.setRoles(
      _userId,
      roles: [RoleCode.seller],
      reason: 'причина',
      rowVersion: 1,
      idempotencyKey: 'k',
    );
    final f = r.failureOrNull! as AuthFailure;
    expect(f.reason, AuthReason.stepUpRequired);
    expect(f.stepUpOperation, 'users.roles.assign');
  });

  test('409 VERSION_CONFLICT, 422 self_demotion, 403 owner_role_reserved', () async {
    var status = 409;
    final h = _Harness((o) async {
      return switch (status) {
        409 => json(409, problem('VERSION_CONFLICT', 409, extra: {'current': adminUserJson()})),
        422 => json(
          422,
          problem(
            'VALIDATION_FAILED',
            422,
            extra: {
              'errors': [
                {'field': 'roles', 'rule': 'self_demotion', 'message': 'нельзя'},
              ],
            },
          ),
        ),
        _ => json(403, problem('FORBIDDEN', 403, extra: {'reason': 'owner_role_reserved'})),
      };
    });
    Future<Object?> call() async => (await h.repo.setRoles(
      _userId,
      roles: [RoleCode.owner],
      reason: 'причина',
      rowVersion: 1,
      idempotencyKey: 'k',
    )).failureOrNull;
    expect((await call() as ConflictFailure?)?.kind, ConflictKind.versionConflict);
    status = 422;
    expect((await call() as ValidationFailure?)?.errors.single.rule, 'self_demotion');
    status = 403;
    expect((await call() as PermissionFailure?)?.serverReason, 'owner_role_reserved');
  });

  test('аварийный код: POST без Idempotency-Key, X-Step-Up-Token, тело {reason, comment}; 201 разбирается', () async {
    late RequestOptions sent;
    final h = _Harness((o) async {
      sent = o;
      return json(
        201,
        {'code': '482913', 'expiresAt': '2026-10-22T09:10:00.000Z', 'phoneMasked': '+996 7** *** *01'},
        headers: {'Cache-Control': 'no-store'},
      );
    });
    final records = <LogRecord>[];
    final sub = h.logger.onRecord.listen(records.add);
    final r = await h.repo.issueEmergencyCode(
      _userId,
      reason: EmergencyCodeReason.other,
      comment: 'потерял телефон',
      stepUpToken: 'su-1',
    );
    await sub.cancel();
    expect(sent.method, 'POST');
    expect(sent.uri.path, '/api/v1/admin/users/$_userId/emergency-login-code');
    expect(sent.headers.containsKey(ApiHeaders.idempotencyKey), isFalse);
    expect(sent.headers[ApiHeaders.stepUpToken], 'su-1');
    expect(_body(sent.data), {'reason': 'other', 'comment': 'потерял телефон'});
    expect(r.valueOrNull?.code, '482913');
    // Код не попадает в журнал HTTP (LoggingInterceptor пишет метод/путь/статус).
    expect(records.map((e) => e.message).join('\n'), isNot(contains('482913')));
  });

  test('аварийный код: 5xx не повторяется автоматически (нет Idempotency-Key)', () async {
    final h = _Harness((o) async => json(503, problem('INTERNAL', 503)));
    await h.repo.issueEmergencyCode(_userId, reason: EmergencyCodeReason.smsUnavailable);
    expect(h.adapter.countPath('/admin/users/$_userId/emergency-login-code'), 1);
  });

  test('429 RATE_LIMITED аварийного кода → ServerFailure(RATE_LIMITED)', () async {
    final h = _Harness((o) async => json(429, problem('RATE_LIMITED', 429), headers: {'Retry-After': '3600'}));
    final f = (await h.repo.issueEmergencyCode(_userId, reason: EmergencyCodeReason.simLost)).failureOrNull;
    expect((f! as ServerFailure).problemCode, ProblemCode.rateLimited);
  });

  test('POST /admin/invitations: тело по AdminInvitationsCreateRequest + Idempotency-Key', () async {
    late RequestOptions sent;
    final h = _Harness((o) async {
      sent = o;
      return json(201, {
        'id': 'inv-1',
        'phoneMasked': '+996 7** *** *07',
        'roles': ['seller'],
        'status': 'pending',
        'createdBy': {'id': 'a', 'displayName': 'Админ'},
        'createdAt': '2026-10-22T09:00:00.000Z',
        'expiresAt': '2026-11-21T17:59:59.000Z',
        'acceptedAt': null,
        'appliedToUserId': null,
      });
    });
    final r = await h.repo.createInvitation(
      InvitationDraft(
        phoneE164: '+996700000007',
        role: RoleCode.seller,
        fullName: ' Асан Усенов ',
        expiresAt: DateTime(2026, 11, 21),
      ),
      idempotencyKey: 'k-inv',
      stepUpToken: 'su',
    );
    expect(sent.uri.path, '/api/v1/admin/invitations');
    expect(sent.headers[ApiHeaders.idempotencyKey], 'k-inv');
    final body = _body(sent.data);
    expect(body.keys.toSet(), {'phone', 'roles', 'fullName', 'expiresAt'});
    expect(body['phone'], '+996700000007');
    expect(body['roles'], ['seller']);
    expect(body['fullName'], 'Асан Усенов');
    expect(DateTime.parse(body['expiresAt']! as String).isUtc, isTrue);
    final inv = r.valueOrNull!;
    expect(inv.isPending, isTrue);
    expect(inv.createdByName, 'Админ');
    expect(inv.expiresAt, isNotNull);
  });

  test('409 PHONE_ALREADY_REGISTERED → ConflictFailure(phoneAlreadyRegistered)', () async {
    final h = _Harness((o) async => json(409, problem('PHONE_ALREADY_REGISTERED', 409)));
    final r = await h.repo.createInvitation(
      const InvitationDraft(phoneE164: '+996700000001', role: RoleCode.cashier),
      idempotencyKey: 'k',
    );
    expect((r.failureOrNull! as ConflictFailure).kind, ConflictKind.phoneAlreadyRegistered);
  });

  test('DELETE …/pin с телом {reason}; logout-all и block — пути и ключи', () async {
    final sent = <RequestOptions>[];
    final h = _Harness((o) async {
      sent.add(o);
      if (o.uri.path.endsWith('/block')) return json(200, adminUserJson(status: 'blocked'));
      return json(204, null);
    });
    expect((await h.repo.resetPin(_userId, reason: 'забыл PIN', stepUpToken: 's')).isSuccess, isTrue);
    expect((await h.repo.logoutAll(_userId, idempotencyKey: 'k2', stepUpToken: 's')).isSuccess, isTrue);
    final blocked = await h.repo.setBlocked(_userId, blocked: true, reason: 'увольнение', idempotencyKey: 'k3');
    expect(sent[0].method, 'DELETE');
    expect(sent[0].uri.path, '/api/v1/admin/users/$_userId/pin');
    expect(_body(sent[0].data), {'reason': 'забыл PIN'});
    expect(sent[1].uri.path, '/api/v1/admin/users/$_userId/logout-all');
    expect(sent[1].headers[ApiHeaders.idempotencyKey], 'k2');
    expect(_body(sent[2].data), {'blocked': true, 'reason': 'увольнение'});
    expect(blocked.valueOrNull?.isBlocked, isTrue);
  });

  test('GET /customers?linkStatus=proposed,conflict; confirm → CustomerLink', () async {
    final sent = <RequestOptions>[];
    final h = _Harness((o) async {
      sent.add(o);
      if (o.method == 'GET') {
        return json(200, {
          'items': [
            {
              'id': 'cust-1',
              'name': 'ОсОО «Строй»',
              'displayName': 'Строй',
              'inn': '01234567890123',
              'phones': [
                {'value': '+996700000009', 'verified': true},
              ],
              'links': [
                {
                  'id': 'l-1',
                  'customerId': 'cust-1',
                  'status': 'conflict',
                  'matchedBy': 'phone',
                  'user': {'id': 'u-1', 'displayName': 'Асан', 'phoneMasked': '+996 7** *** *09'},
                },
              ],
            },
          ],
          'nextCursor': null,
          'hasMore': false,
        });
      }
      return json(200, {'id': 'l-1', 'customerId': 'cust-1', 'status': 'confirmed'});
    });
    final cases = (await h.repo.listLinkCases()).valueOrNull!;
    expect(sent.first.uri.queryParameters['linkStatus'], 'proposed,conflict');
    final c = cases.items.single;
    expect(c.title, 'Строй');
    expect(c.phones, ['+996700000009']);
    expect(c.hasConflict, isTrue);
    expect(c.links.single.userDisplayName, 'Асан');
    final r = await h.repo.confirmLink('cust-1', 'l-1', comment: 'проверено', idempotencyKey: 'k', stepUpToken: 's');
    expect(sent.last.uri.path, '/api/v1/customers/cust-1/links/l-1/confirm');
    expect(sent.last.headers[ApiHeaders.stepUpToken], 's');
    expect(_body(sent.last.data), {'comment': 'проверено'});
    expect(r.valueOrNull?.status, 'confirmed');
  });

  test('GET /me → AdminViewer (роли и права, без ПДн)', () async {
    final h = _Harness(
      (o) async => json(200, {
        'id': 'me-1',
        'kind': 'staff',
        'status': 'active',
        'roles': ['owner'],
        'permissions': ['users.read', 'users.roles.assign'],
        'permissionsVersion': 1,
        'profile': {'fullName': 'Руководитель', 'phone': '+996700000002'},
      }),
    );
    final v = (await h.repo.viewer()).valueOrNull!;
    expect(v.isOwner, isTrue);
    expect(v.permissions, {'users.read', 'users.roles.assign'});
  });

  test('ответ не по контракту → UnknownFailure', () async {
    final h = _Harness((o) async => json(200, {'items': 'oops'}));
    expect((await h.repo.listInvitations()).failureOrNull, isA<UnknownFailure>());
  });

  group('POST /auth/step-up', () {
    test('PIN → 200 {stepUpToken}; тело {method, pin, operation}', () async {
      late RequestOptions sent;
      final h = _Harness((o) async {
        sent = o;
        return json(200, {
          'stepUpToken': 'su-1',
          'expiresAt': '2026-10-22T09:15:00.000Z',
          'method': 'pin',
          'scope': ['users.roles.assign'],
        });
      });
      final g = (await h.gateway.withPin('users.roles.assign', '482913')).valueOrNull!;
      expect(_body(sent.data), {'method': 'pin', 'pin': '482913', 'operation': 'users.roles.assign'});
      expect(g.token, 'su-1');
      expect(g.method, StepUpMethod.pin);
    });

    test('PIN_INVALID → AuthFailure(pinInvalid, attemptsLeft)', () async {
      final h = _Harness((o) async => json(401, problem('PIN_INVALID', 401, extra: {'attemptsLeft': 2})));
      final f = (await h.gateway.withPin('users.manage', '000001')).failureOrNull! as AuthFailure;
      expect(f.reason, AuthReason.pinInvalid);
      expect(f.attemptsLeft, 2);
      expect(h.adapter.countPath('/auth/refresh'), 0);
    });

    test('OTP: 202 challenge → 200 токен', () async {
      final h = _Harness((o) async {
        final b = _body(o.data);
        if (!b.containsKey('code')) return json(202, {'challengeId': 'ch-1', 'resendAfterSec': 60, 'otpTtlSec': 300});
        return json(200, {
          'stepUpToken': 'su-otp',
          'expiresAt': '2026-10-22T09:15:00.000Z',
          'method': 'otp',
          'scope': <String>[],
        });
      });
      final ch = (await h.gateway.requestOtp('users.manage')).valueOrNull!;
      expect(ch.challengeId, 'ch-1');
      final g = (await h.gateway.withOtp('users.manage', challengeId: 'ch-1', code: '123456')).valueOrNull!;
      expect(g.method, StepUpMethod.otp);
    });
  });

  test('Result<void> успешного 204', () async {
    final h = _Harness((o) async => json(204, null));
    expect(await h.repo.revokeInvitation('inv-1', stepUpToken: 's'), isA<Success<void>>());
  });
}
