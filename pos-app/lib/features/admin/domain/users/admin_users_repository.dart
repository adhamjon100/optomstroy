// Порт данных SCR-45 (08 §4.18.1–§4.18.4, §4.18.9, §4.18.10, §4.11.1, §4.11.7). Реализация —
// data/users/dio_admin_users_repository.dart (подключается через data/admin_bindings.dart, L-8).
// Данные пользователей не кэшируются (ПДн, AC-UI-45-015). Чистый Dart (FL-01).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/admin/domain/users/admin_user.dart';
import 'package:optomstroy/features/admin/domain/users/admin_viewer.dart';
import 'package:optomstroy/features/admin/domain/users/customer_link_case.dart';
import 'package:optomstroy/features/admin/domain/users/emergency_login_code.dart';
import 'package:optomstroy/features/admin/domain/users/invitation.dart';

abstract interface class AdminUsersRepository {
  /// `GET /me` → кто открыл экран (роли и права).
  Future<Result<AdminViewer>> viewer();

  /// `GET /admin/users?q=&role=&status=&limit=&cursor=`.
  Future<Result<AdminPage<AdminUser>>> listUsers(AdminUsersQuery query);

  /// `GET /admin/users/{id}`.
  Future<Result<AdminUser>> getUser(String id);

  /// `PUT /admin/users/{id}/roles` (S! `users.roles.assign`, `Idempotency-Key`).
  Future<Result<AdminUser>> setRoles(
    String id, {
    required List<RoleCode> roles,
    required String reason,
    required int rowVersion,
    required String idempotencyKey,
    String? stepUpToken,
  });

  /// `POST /admin/users/{id}/block` (S! `users.manage`).
  Future<Result<AdminUser>> setBlocked(
    String id, {
    required bool blocked,
    required String reason,
    required String idempotencyKey,
    String? stepUpToken,
  });

  /// `POST /admin/users/{id}/logout-all` (S! `session.revoke.any`) → 204.
  Future<Result<void>> logoutAll(String id, {required String idempotencyKey, String? stepUpToken});

  /// `DELETE /admin/users/{id}/pin {reason}` (S! `users.pin.reset`) → 204.
  Future<Result<void>> resetPin(String id, {required String reason, String? stepUpToken});

  /// `POST /admin/users/{id}/emergency-login-code` (S! по PIN; без `Idempotency-Key` — 08 §4.18.10).
  Future<Result<EmergencyLoginCode>> issueEmergencyCode(
    String id, {
    required EmergencyCodeReason reason,
    String? comment,
    String? stepUpToken,
  });

  /// `POST /admin/users {phone, fullName, roles}` — активация `pending_activation` (S! `users.manage`).
  Future<Result<AdminUser>> activate({
    required String phoneE164,
    required String fullName,
    required RoleCode role,
    required String idempotencyKey,
    String? stepUpToken,
  });

  /// `GET /admin/invitations`.
  Future<Result<AdminPage<Invitation>>> listInvitations({String? cursor});

  /// `POST /admin/invitations` (S! `invitations.manage`, `Idempotency-Key`).
  Future<Result<Invitation>> createInvitation(
    InvitationDraft draft, {
    required String idempotencyKey,
    String? stepUpToken,
  });

  /// `DELETE /admin/invitations/{id}` (S!) → 204.
  Future<Result<void>> revokeInvitation(String id, {String? stepUpToken});

  /// `GET /customers?linkStatus=proposed,conflict` (только `admin`).
  Future<Result<AdminPage<CustomerLinkCase>>> listLinkCases({String? cursor});

  /// `POST /customers/{id}/links/{linkId}/confirm` (S! `customer.link.resolve`).
  Future<Result<CustomerLinkCandidate>> confirmLink(
    String customerId,
    String linkId, {
    String? comment,
    required String idempotencyKey,
    String? stepUpToken,
  });

  /// `POST /customers/{id}/links/{linkId}/reject` (S! `customer.link.resolve`).
  Future<Result<CustomerLinkCandidate>> rejectLink(
    String customerId,
    String linkId, {
    String? comment,
    required String idempotencyKey,
    String? stepUpToken,
  });
}
