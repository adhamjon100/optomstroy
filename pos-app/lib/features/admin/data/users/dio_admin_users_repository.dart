// Реализация порта SCR-45 поверх единственного Dio-клиента (core/network/dio_client.dart).
// Ошибки → Failure только через ErrorMapper (06 §6.8). Тела запросов и ответов не логируются
// (LoggingInterceptor пишет метод, путь, статус); аварийный код и stepUpToken нигде не сохраняются.
import 'package:dio/dio.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/features/admin/data/users/admin_users_dto.dart';
import 'package:optomstroy/features/admin/domain/users/admin_user.dart';
import 'package:optomstroy/features/admin/domain/users/admin_users_repository.dart';
import 'package:optomstroy/features/admin/domain/users/admin_viewer.dart';
import 'package:optomstroy/features/admin/domain/users/customer_link_case.dart';
import 'package:optomstroy/features/admin/domain/users/emergency_login_code.dart';
import 'package:optomstroy/features/admin/domain/users/invitation.dart';

final class DioAdminUsersRepository implements AdminUsersRepository {
  DioAdminUsersRepository(this._dio);

  final Dio _dio;

  static Options _options({String? idempotencyKey, String? stepUpToken}) => Options(
    headers: {
      ApiHeaders.idempotencyKey: ?idempotencyKey,
      ApiHeaders.stepUpToken: ?stepUpToken, // check-secrets: allow (имя заголовка)
    },
  );

  /// Вызов с разбором ответа; ошибка контракта DTO (`AdminDtoException`) → `UnknownFailure`.
  static Future<Result<T>> _guard<T>(Future<T> Function() call) => ErrorMapper.guard(call);

  @override
  Future<Result<AdminViewer>> viewer() => _guard(() async {
    final r = await _dio.get<Object?>('/me');
    return AdminUsersDto.viewer(r.data);
  });

  @override
  Future<Result<AdminPage<AdminUser>>> listUsers(AdminUsersQuery query) => _guard(() async {
    final q = query.effectiveQuery;
    final r = await _dio.get<Object?>(
      '/admin/users',
      queryParameters: {
        'kind': UserKind.staff.value,
        'limit': query.limit,
        'q': ?q,
        if (query.role != null) 'role': query.role!.value,
        if (query.status != null) 'status': query.status!.value,
        if (query.cursor != null) 'cursor': query.cursor,
      },
    );
    return AdminUsersDto.page(r.data, AdminUsersDto.user);
  });

  @override
  Future<Result<AdminUser>> getUser(String id) => _guard(() async {
    final r = await _dio.get<Object?>('/admin/users/${Uri.encodeComponent(id)}');
    return AdminUsersDto.user(r.data);
  });

  @override
  Future<Result<AdminUser>> setRoles(
    String id, {
    required List<RoleCode> roles,
    required String reason,
    required int rowVersion,
    required String idempotencyKey,
    String? stepUpToken,
  }) => _guard(() async {
    final r = await _dio.put<Object?>(
      '/admin/users/${Uri.encodeComponent(id)}/roles',
      data: {
        'roles': [for (final role in roles) role.value],
        'reason': reason,
        'rowVersion': rowVersion,
      },
      options: _options(idempotencyKey: idempotencyKey, stepUpToken: stepUpToken),
    );
    return AdminUsersDto.user(r.data);
  });

  @override
  Future<Result<AdminUser>> setBlocked(
    String id, {
    required bool blocked,
    required String reason,
    required String idempotencyKey,
    String? stepUpToken,
  }) => _guard(() async {
    final r = await _dio.post<Object?>(
      '/admin/users/${Uri.encodeComponent(id)}/block',
      data: {'blocked': blocked, 'reason': reason},
      options: _options(idempotencyKey: idempotencyKey, stepUpToken: stepUpToken),
    );
    return AdminUsersDto.user(r.data);
  });

  @override
  Future<Result<void>> logoutAll(String id, {required String idempotencyKey, String? stepUpToken}) =>
      _guard<void>(() async {
        await _dio.post<Object?>(
          '/admin/users/${Uri.encodeComponent(id)}/logout-all',
          options: _options(idempotencyKey: idempotencyKey, stepUpToken: stepUpToken),
        );
      });

  @override
  Future<Result<void>> resetPin(String id, {required String reason, String? stepUpToken}) => _guard<void>(() async {
    await _dio.delete<Object?>(
      '/admin/users/${Uri.encodeComponent(id)}/pin',
      data: {'reason': reason},
      options: _options(stepUpToken: stepUpToken),
    );
  });

  @override
  Future<Result<EmergencyLoginCode>> issueEmergencyCode(
    String id, {
    required EmergencyCodeReason reason,
    String? comment,
    String? stepUpToken,
  }) => _guard(() async {
    final text = comment?.trim() ?? '';
    // Без Idempotency-Key: операция намеренно неидемпотентна, секрет не попадает в хранилище
    // идемпотентности (08 §4.18.10). RetryInterceptor POST без ключа не повторяет.
    final r = await _dio.post<Object?>(
      '/admin/users/${Uri.encodeComponent(id)}/emergency-login-code',
      data: {'reason': reason.value, if (text.isNotEmpty) 'comment': text},
      options: _options(stepUpToken: stepUpToken),
    );
    return AdminUsersDto.emergencyCode(r.data);
  });

  @override
  Future<Result<AdminUser>> activate({
    required String phoneE164,
    required String fullName,
    required RoleCode role,
    required String idempotencyKey,
    String? stepUpToken,
  }) => _guard(() async {
    final r = await _dio.post<Object?>(
      '/admin/users',
      data: {
        'phone': phoneE164,
        'fullName': fullName,
        'roles': [role.value],
      },
      options: _options(idempotencyKey: idempotencyKey, stepUpToken: stepUpToken),
    );
    return AdminUsersDto.user(r.data);
  });

  @override
  Future<Result<AdminPage<Invitation>>> listInvitations({String? cursor}) => _guard(() async {
    final r = await _dio.get<Object?>('/admin/invitations', queryParameters: {'limit': 100, 'cursor': ?cursor});
    return AdminUsersDto.page(r.data, AdminUsersDto.invitation);
  });

  @override
  Future<Result<Invitation>> createInvitation(
    InvitationDraft draft, {
    required String idempotencyKey,
    String? stepUpToken,
  }) => _guard(() async {
    final r = await _dio.post<Object?>(
      '/admin/invitations',
      data: AdminUsersDto.invitationRequest(draft),
      options: _options(idempotencyKey: idempotencyKey, stepUpToken: stepUpToken),
    );
    return AdminUsersDto.invitation(r.data);
  });

  @override
  Future<Result<void>> revokeInvitation(String id, {String? stepUpToken}) => _guard<void>(() async {
    await _dio.delete<Object?>(
      '/admin/invitations/${Uri.encodeComponent(id)}',
      options: _options(stepUpToken: stepUpToken),
    );
  });

  @override
  Future<Result<AdminPage<CustomerLinkCase>>> listLinkCases({String? cursor}) => _guard(() async {
    final r = await _dio.get<Object?>(
      '/customers',
      queryParameters: {
        'linkStatus': '${CustomerLinkStatus.proposed.value},${CustomerLinkStatus.conflict.value}',
        'limit': 50,
        'cursor': ?cursor,
      },
    );
    return AdminUsersDto.page(r.data, AdminUsersDto.linkCase);
  });

  @override
  Future<Result<CustomerLinkCandidate>> confirmLink(
    String customerId,
    String linkId, {
    String? comment,
    required String idempotencyKey,
    String? stepUpToken,
  }) => _resolve('confirm', customerId, linkId, comment, idempotencyKey, stepUpToken);

  @override
  Future<Result<CustomerLinkCandidate>> rejectLink(
    String customerId,
    String linkId, {
    String? comment,
    required String idempotencyKey,
    String? stepUpToken,
  }) => _resolve('reject', customerId, linkId, comment, idempotencyKey, stepUpToken);

  Future<Result<CustomerLinkCandidate>> _resolve(
    String action,
    String customerId,
    String linkId,
    String? comment,
    String idempotencyKey,
    String? stepUpToken,
  ) => _guard(() async {
    final text = comment?.trim() ?? '';
    final r = await _dio.post<Object?>(
      '/customers/${Uri.encodeComponent(customerId)}/links/${Uri.encodeComponent(linkId)}/$action',
      data: {if (text.isNotEmpty) 'comment': text},
      options: _options(idempotencyKey: idempotencyKey, stepUpToken: stepUpToken),
    );
    return AdminUsersDto.link(r.data, customerId: customerId);
  });
}
