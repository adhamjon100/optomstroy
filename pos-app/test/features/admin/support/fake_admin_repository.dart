// Фейки портов фичи admin для unit/widget-тестов SCR-45.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/admin/admin_providers.dart';
import 'package:optomstroy/features/admin/domain/users/admin_user.dart';
import 'package:optomstroy/features/admin/domain/users/admin_users_repository.dart';
import 'package:optomstroy/features/admin/domain/users/admin_viewer.dart';
import 'package:optomstroy/features/admin/domain/users/customer_link_case.dart';
import 'package:optomstroy/features/admin/domain/users/emergency_login_code.dart';
import 'package:optomstroy/features/admin/domain/users/invitation.dart';
import 'package:optomstroy/features/admin/domain/users/step_up.dart';

const String adminId = '00000000-0000-4000-8000-0000000000a1';
const String ownerId = '00000000-0000-4000-8000-0000000000b1';
const String cashierId = '00000000-0000-4000-8000-0000000000c1';
const String otherAdminId = '00000000-0000-4000-8000-0000000000a2';
const String pendingId = '00000000-0000-4000-8000-0000000000d1';

final DateTime t0 = DateTime.utc(2026, 10, 22, 9);

const AdminViewer adminViewer = AdminViewer(userId: adminId, roles: [RoleCode.admin]);
const AdminViewer ownerViewer = AdminViewer(userId: ownerId, roles: [RoleCode.owner]);

AdminUser staff(
  String id, {
  RoleCode role = RoleCode.cashier,
  String status = 'active',
  String kind = 'staff',
  String? phone = '+996700000001',
  String name = 'Иван Петров',
  int rowVersion = 1,
  int devices = 2,
}) => AdminUser(
  id: id,
  kind: kind,
  status: status,
  roles: [role.value],
  phone: phone,
  fullName: name,
  devicesCount: devices,
  lastLoginAt: t0,
  createdAt: t0.subtract(const Duration(days: 30)),
  rowVersion: rowVersion,
);

/// Ответ `403 STEP_UP_REQUIRED`.
Failure stepUpRequired(String operation) =>
    AuthFailure(AuthReason.stepUpRequired, stepUpOperation: operation, requestId: 'rid-step-up');

/// Записанный вызов репозитория (без ПДн).
final class RepoCall {
  const RepoCall(this.method, {this.id, this.idempotencyKey, this.stepUpToken, this.args = const {}});

  final String method;
  final String? id;
  final String? idempotencyKey;
  final String? stepUpToken;
  final Map<String, Object?> args;

  @override
  String toString() => 'RepoCall($method, $id, key=$idempotencyKey, token=$stepUpToken)'; // check-secrets: allow (тест)
}

/// Фейк [AdminUsersRepository]: step-up требуется, пока не предъявлен токен из [validTokens].
final class FakeAdminUsersRepository implements AdminUsersRepository {
  FakeAdminUsersRepository({
    this.me = adminViewer,
    List<AdminUser>? users,
    List<Invitation>? invitations,
    List<CustomerLinkCase>? links,
  }) : users = users ?? [],
       invitations = invitations ?? [],
       links = links ?? [];

  AdminViewer me;
  Failure? viewerFailure;
  final List<AdminUser> users;
  final List<Invitation> invitations;
  final List<CustomerLinkCase> links;

  /// Токены, которые «сервер» принимает.
  final Set<String> validTokens = {'step-up-token'};

  /// Требовать step-up для изменяющих операций.
  bool requireStepUp = true;

  /// Принудительная ошибка следующего изменяющего вызова (после проверки step-up).
  Failure? nextFailure;

  /// Ошибка загрузки списка пользователей.
  Failure? usersFailure;

  final List<RepoCall> calls = [];
  int _codeSeq = 0;

  Iterable<RepoCall> callsOf(String method) => calls.where((c) => c.method == method);

  Result<T>? _gate<T>(String? token, String operation) {
    if (requireStepUp && (token == null || !validTokens.contains(token))) {
      return FailureResult<T>(stepUpRequired(operation));
    }
    final f = nextFailure;
    if (f != null) {
      nextFailure = null;
      return FailureResult<T>(f);
    }
    return null;
  }

  @override
  Future<Result<AdminViewer>> viewer() async => viewerFailure == null ? Success(me) : FailureResult(viewerFailure!);

  @override
  Future<Result<AdminPage<AdminUser>>> listUsers(AdminUsersQuery query) async {
    calls.add(RepoCall('listUsers', args: {'role': query.role?.value, 'status': query.status?.value}));
    if (usersFailure != null) return FailureResult(usersFailure!);
    final q = query.effectiveQuery?.toLowerCase();
    final digits = q?.replaceAll(RegExp(r'\D'), '');
    final items = users.where((u) {
      if (query.role != null && !u.hasRole(query.role!)) return false;
      if (query.status != null && u.status != query.status!.value) return false;
      if (q != null) {
        final byName = (u.fullName ?? '').toLowerCase().contains(q);
        final byPhone = digits != null && digits.length >= 3 && (u.phone ?? '').contains(digits);
        if (!byName && !byPhone) return false;
      }
      return true;
    }).toList();
    return Success(AdminPage(items: items, totalEstimate: items.length));
  }

  @override
  Future<Result<AdminUser>> getUser(String id) async {
    calls.add(RepoCall('getUser', id: id));
    final u = users.where((x) => x.id == id).firstOrNull;
    return u == null ? const FailureResult(ServerFailure(code: 'NOT_FOUND', status: 404)) : Success(u);
  }

  void _put(AdminUser u) {
    final i = users.indexWhere((x) => x.id == u.id);
    if (i >= 0) users[i] = u;
  }

  @override
  Future<Result<AdminUser>> setRoles(
    String id, {
    required List<RoleCode> roles,
    required String reason,
    required int rowVersion,
    required String idempotencyKey,
    String? stepUpToken,
  }) async {
    calls.add(
      RepoCall(
        'setRoles',
        id: id,
        idempotencyKey: idempotencyKey,
        stepUpToken: stepUpToken,
        args: {'roles': roles.map((r) => r.value).toList(), 'reason': reason, 'rowVersion': rowVersion},
      ),
    );
    final gate = _gate<AdminUser>(stepUpToken, AdminStepUpOperations.rolesAssign);
    if (gate != null) return gate;
    final u = users.firstWhere((x) => x.id == id);
    final updated = u.copyWith(roles: [for (final r in roles) r.value], rowVersion: u.rowVersion + 1);
    _put(updated);
    return Success(updated);
  }

  @override
  Future<Result<AdminUser>> setBlocked(
    String id, {
    required bool blocked,
    required String reason,
    required String idempotencyKey,
    String? stepUpToken,
  }) async {
    calls.add(
      RepoCall(
        'setBlocked',
        id: id,
        idempotencyKey: idempotencyKey,
        stepUpToken: stepUpToken,
        args: {'blocked': blocked, 'reason': reason},
      ),
    );
    final gate = _gate<AdminUser>(stepUpToken, AdminStepUpOperations.usersManage);
    if (gate != null) return gate;
    final u = users.firstWhere((x) => x.id == id);
    final updated = u.copyWith(status: blocked ? 'blocked' : 'active', devicesCount: blocked ? 0 : u.devicesCount);
    _put(updated);
    return Success(updated);
  }

  @override
  Future<Result<void>> logoutAll(String id, {required String idempotencyKey, String? stepUpToken}) async {
    calls.add(RepoCall('logoutAll', id: id, idempotencyKey: idempotencyKey, stepUpToken: stepUpToken));
    final gate = _gate<void>(stepUpToken, AdminStepUpOperations.sessionRevokeAny);
    if (gate != null) return gate;
    return const Success<void>(null);
  }

  @override
  Future<Result<void>> resetPin(String id, {required String reason, String? stepUpToken}) async {
    calls.add(RepoCall('resetPin', id: id, stepUpToken: stepUpToken, args: {'reason': reason}));
    final gate = _gate<void>(stepUpToken, AdminStepUpOperations.pinReset);
    if (gate != null) return gate;
    return const Success<void>(null);
  }

  @override
  Future<Result<EmergencyLoginCode>> issueEmergencyCode(
    String id, {
    required EmergencyCodeReason reason,
    String? comment,
    String? stepUpToken,
  }) async {
    calls.add(
      RepoCall(
        'issueEmergencyCode',
        id: id,
        stepUpToken: stepUpToken,
        args: {'reason': reason.value, 'comment': comment},
      ),
    );
    final gate = _gate<EmergencyLoginCode>(stepUpToken, AdminStepUpOperations.emergencyCode);
    if (gate != null) return gate;
    _codeSeq++;
    return Success(
      EmergencyLoginCode(
        code: '48291$_codeSeq',
        expiresAt: t0.add(const Duration(minutes: 10)),
        phoneMasked: '+996 7** *** *01',
      ),
    );
  }

  @override
  Future<Result<AdminUser>> activate({
    required String phoneE164,
    required String fullName,
    required RoleCode role,
    required String idempotencyKey,
    String? stepUpToken,
  }) async {
    calls.add(
      RepoCall('activate', idempotencyKey: idempotencyKey, stepUpToken: stepUpToken, args: {'role': role.value}),
    );
    final gate = _gate<AdminUser>(stepUpToken, AdminStepUpOperations.usersManage);
    if (gate != null) return gate;
    final u = users.firstWhere((x) => x.phone == phoneE164);
    final updated = u.copyWith(status: 'active', roles: [role.value]);
    _put(updated);
    return Success(updated);
  }

  @override
  Future<Result<AdminPage<Invitation>>> listInvitations({String? cursor}) async =>
      Success(AdminPage(items: List.of(invitations)));

  @override
  Future<Result<Invitation>> createInvitation(
    InvitationDraft draft, {
    required String idempotencyKey,
    String? stepUpToken,
  }) async {
    calls.add(
      RepoCall(
        'createInvitation',
        idempotencyKey: idempotencyKey,
        stepUpToken: stepUpToken,
        args: {'role': draft.role.value, 'fullName': draft.fullName, 'expiresAt': draft.expiresAt},
      ),
    );
    final gate = _gate<Invitation>(stepUpToken, AdminStepUpOperations.invitationsManage);
    if (gate != null) return gate;
    final inv = Invitation(
      id: 'inv-$idempotencyKey',
      phoneMasked: '+996 7** *** *07',
      roles: [draft.role.value],
      status: 'pending',
      createdByName: 'Админ',
      createdAt: t0,
      expiresAt: draft.expiresAt,
    );
    if (!invitations.any((i) => i.id == inv.id)) invitations.insert(0, inv);
    return Success(inv);
  }

  @override
  Future<Result<void>> revokeInvitation(String id, {String? stepUpToken}) async {
    calls.add(RepoCall('revokeInvitation', id: id, stepUpToken: stepUpToken));
    final gate = _gate<void>(stepUpToken, AdminStepUpOperations.invitationsManage);
    if (gate != null) return gate;
    return const Success<void>(null);
  }

  @override
  Future<Result<AdminPage<CustomerLinkCase>>> listLinkCases({String? cursor}) async {
    calls.add(const RepoCall('listLinkCases'));
    return Success(AdminPage(items: List.of(links)));
  }

  @override
  Future<Result<CustomerLinkCandidate>> confirmLink(
    String customerId,
    String linkId, {
    String? comment,
    required String idempotencyKey,
    String? stepUpToken,
  }) => _resolve('confirmLink', 'confirmed', customerId, linkId, idempotencyKey, stepUpToken);

  @override
  Future<Result<CustomerLinkCandidate>> rejectLink(
    String customerId,
    String linkId, {
    String? comment,
    required String idempotencyKey,
    String? stepUpToken,
  }) => _resolve('rejectLink', 'rejected', customerId, linkId, idempotencyKey, stepUpToken);

  Future<Result<CustomerLinkCandidate>> _resolve(
    String method,
    String status,
    String customerId,
    String linkId,
    String key,
    String? token,
  ) async {
    calls.add(RepoCall(method, id: linkId, idempotencyKey: key, stepUpToken: token));
    final gate = _gate<CustomerLinkCandidate>(token, AdminStepUpOperations.linkResolve);
    if (gate != null) return gate;
    return Success(CustomerLinkCandidate(id: linkId, customerId: customerId, status: status));
  }
}

/// Мок порта StepUpDialog: записывает запросы и возвращает токен (или `null` — отмена).
final class FakeStepUpPrompter {
  FakeStepUpPrompter({this.token = 'step-up-token', this.cancel = false}); // check-secrets: allow (тест)

  String token;
  bool cancel;
  final List<StepUpChallenge> challenges = [];

  Future<StepUpGrant?> call(BuildContext context, StepUpChallenge challenge) async {
    challenges.add(challenge);
    if (cancel) return null;
    return StepUpGrant(token: token, expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 15)));
  }
}

/// Переопределения провайдеров для тестов SCR-45.
List<Override> adminTestOverrides(
  FakeAdminUsersRepository repo, {
  FakeStepUpPrompter? prompter,
  bool customerSelfService = true,
  Clock? clock,
}) => [
  adminUsersRepositoryProvider.overrideWithValue(repo),
  if (prompter != null) adminStepUpPrompterProvider.overrideWithValue(prompter.call),
  adminCustomerSelfServiceProvider.overrideWithValue(customerSelfService),
  clockProvider.overrideWithValue(clock ?? FixedClock(t0)),
];

/// Обёртка приложения для widget-тестов (тема B, локаль ru).
Future<void> pumpAdmin(
  WidgetTester tester,
  Widget child, {
  required List<Override> overrides,
  Size size = const Size(1440, 900),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        debugShowCheckedModeBanner: false,
        builder: (context, app) =>
            MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: app!),
        home: child,
      ),
    ),
  );
}

/// Ожидание завершения микрозадач/таймеров контроллера.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pumpAndSettle();
}
