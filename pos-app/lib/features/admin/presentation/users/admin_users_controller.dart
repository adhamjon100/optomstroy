// Состояние и действия SCR-45 (06 §6.11; 02 SCR-45.7). Данные пользователей только в памяти —
// не в drift (ПДн, AC-UI-45-015). Аварийный код в состояние НЕ попадает: возвращается вызывающему
// диалогу и живёт только в нём (11 SEC-131). stepUpToken — только в памяти `StepUpRunner`.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/admin/admin_providers.dart';
import 'package:optomstroy/features/admin/domain/users/admin_user.dart';
import 'package:optomstroy/features/admin/domain/users/admin_users_policy.dart';
import 'package:optomstroy/features/admin/domain/users/admin_users_repository.dart';
import 'package:optomstroy/features/admin/domain/users/admin_viewer.dart';
import 'package:optomstroy/features/admin/domain/users/customer_link_case.dart';
import 'package:optomstroy/features/admin/domain/users/emergency_login_code.dart';
import 'package:optomstroy/features/admin/domain/users/invitation.dart';
import 'package:optomstroy/features/admin/domain/users/step_up.dart';

/// Срез списка с пагинацией.
final class ListSlice<T> {
  const ListSlice({
    this.items = const [],
    this.loading = false,
    this.loadingMore = false,
    this.failure,
    this.nextCursor,
    this.hasMore = false,
    this.total,
    this.loaded = false,
  });

  final List<T> items;
  final bool loading;
  final bool loadingMore;
  final Failure? failure;
  final String? nextCursor;
  final bool hasMore;
  final int? total;

  /// Хотя бы одна загрузка завершилась.
  final bool loaded;

  int get count => total ?? items.length;

  ListSlice<T> copyWith({
    List<T>? items,
    bool? loading,
    bool? loadingMore,
    Failure? failure,
    bool clearFailure = false,
    String? nextCursor,
    bool? hasMore,
    int? total,
    bool? loaded,
  }) => ListSlice<T>(
    items: items ?? this.items,
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    failure: clearFailure ? null : (failure ?? this.failure),
    nextCursor: nextCursor ?? this.nextCursor,
    hasMore: hasMore ?? this.hasMore,
    total: total ?? this.total,
    loaded: loaded ?? this.loaded,
  );
}

final class AdminUsersState {
  const AdminUsersState({
    this.viewer,
    this.viewerFailure,
    this.query = const AdminUsersQuery(),
    this.users = const ListSlice(),
    this.invitations = const ListSlice(),
    this.links = const ListSlice(),
    this.selectedId,
    this.selected,
    this.selectedLoading = false,
    this.selectedFailure,
    this.versionConflict = false,
  });

  final AdminViewer? viewer;
  final Failure? viewerFailure;
  final AdminUsersQuery query;
  final ListSlice<AdminUser> users;
  final ListSlice<Invitation> invitations;
  final ListSlice<CustomerLinkCase> links;
  final String? selectedId;
  final AdminUser? selected;
  final bool selectedLoading;
  final Failure? selectedFailure;

  /// `409 VERSION_CONFLICT` — баннер UI-45-020 над карточкой.
  final bool versionConflict;

  AdminUsersPolicy? get policy => viewer == null ? null : AdminUsersPolicy(viewer!);

  AdminUsersState copyWith({
    AdminViewer? viewer,
    Failure? viewerFailure,
    bool clearViewerFailure = false,
    AdminUsersQuery? query,
    ListSlice<AdminUser>? users,
    ListSlice<Invitation>? invitations,
    ListSlice<CustomerLinkCase>? links,
    String? selectedId,
    AdminUser? selected,
    bool clearSelected = false,
    bool? selectedLoading,
    Failure? selectedFailure,
    bool clearSelectedFailure = false,
    bool? versionConflict,
  }) => AdminUsersState(
    viewer: viewer ?? this.viewer,
    viewerFailure: clearViewerFailure ? null : (viewerFailure ?? this.viewerFailure),
    query: query ?? this.query,
    users: users ?? this.users,
    invitations: invitations ?? this.invitations,
    links: links ?? this.links,
    selectedId: clearSelected ? null : (selectedId ?? this.selectedId),
    selected: clearSelected ? null : (selected ?? this.selected),
    selectedLoading: selectedLoading ?? this.selectedLoading,
    selectedFailure: clearSelectedFailure || clearSelected ? null : (selectedFailure ?? this.selectedFailure),
    versionConflict: versionConflict ?? this.versionConflict,
  );
}

final adminUsersControllerProvider = NotifierProvider.autoDispose<AdminUsersController, AdminUsersState>(
  AdminUsersController.new,
);

final class AdminUsersController extends Notifier<AdminUsersState> {
  late AdminUsersRepository _repo;
  late StepUpRunner _runner;
  int _usersRequest = 0;

  @override
  AdminUsersState build() {
    _repo = ref.watch(adminUsersRepositoryProvider);
    final clock = ref.watch(clockProvider);
    _runner = StepUpRunner(nowUtc: clock.nowUtc);
    ref.onDispose(_runner.clear);
    scheduleMicrotask(() => unawaited(_init()));
    return const AdminUsersState(users: ListSlice(loading: true));
  }

  /// Забыть токены step-up (сворачивание приложения, idle-блокировка).
  void forgetStepUp() => _runner.clear();

  Future<void> _init() async {
    final viewer = await _repo.viewer();
    if (!ref.mounted) return;
    switch (viewer) {
      case FailureResult(:final failure):
        state = state.copyWith(viewerFailure: failure, users: state.users.copyWith(loading: false));
        return;
      case Success(:final value):
        state = state.copyWith(viewer: value, clearViewerFailure: true);
    }
    final policy = state.policy!;
    if (policy.mode == AdminUsersMode.none) {
      state = state.copyWith(users: state.users.copyWith(loading: false));
      return;
    }
    await Future.wait([
      reloadUsers(),
      if (policy.canSeeInvitations) reloadInvitations(),
      if (policy.isAdmin) reloadLinks(),
    ]);
  }

  /// «Повторить» после ошибки загрузки зрителя.
  Future<void> retry() async {
    state = const AdminUsersState(users: ListSlice(loading: true));
    await _init();
  }

  // ---------------------------------------------------------------- списки

  Future<void> setQuery(AdminUsersQuery query) async {
    if (query == state.query) return;
    state = state.copyWith(query: query);
    await reloadUsers();
  }

  Future<void> reloadUsers() async {
    final request = ++_usersRequest;
    state = state.copyWith(users: state.users.copyWith(loading: true, clearFailure: true));
    final result = await _repo.listUsers(state.query.copyWith(clearCursor: true));
    if (!ref.mounted || request != _usersRequest) return;
    state = state.copyWith(
      users: switch (result) {
        Success(:final value) => ListSlice(
          items: value.items,
          nextCursor: value.nextCursor,
          hasMore: value.hasMore,
          total: value.totalEstimate,
          loaded: true,
        ),
        FailureResult(:final failure) => state.users.copyWith(loading: false, failure: failure, loaded: true),
      },
    );
  }

  Future<void> loadMoreUsers() async {
    final slice = state.users;
    if (!slice.hasMore || slice.loadingMore || slice.loading || slice.nextCursor == null) return;
    final request = _usersRequest;
    state = state.copyWith(users: slice.copyWith(loadingMore: true));
    final result = await _repo.listUsers(state.query.copyWith(cursor: slice.nextCursor));
    if (!ref.mounted || request != _usersRequest) return;
    state = state.copyWith(
      users: switch (result) {
        Success(:final value) => state.users.copyWith(
          items: [...state.users.items, ...value.items],
          nextCursor: value.nextCursor,
          hasMore: value.hasMore,
          loadingMore: false,
        ),
        FailureResult(:final failure) => state.users.copyWith(loadingMore: false, failure: failure),
      },
    );
  }

  Future<void> reloadInvitations() async {
    state = state.copyWith(invitations: state.invitations.copyWith(loading: true, clearFailure: true));
    final result = await _repo.listInvitations();
    if (!ref.mounted) return;
    state = state.copyWith(
      invitations: switch (result) {
        Success(:final value) => ListSlice(
          items: value.items,
          nextCursor: value.nextCursor,
          hasMore: value.hasMore,
          total: value.totalEstimate,
          loaded: true,
        ),
        FailureResult(:final failure) => state.invitations.copyWith(loading: false, failure: failure, loaded: true),
      },
    );
  }

  Future<void> reloadLinks() async {
    state = state.copyWith(links: state.links.copyWith(loading: true, clearFailure: true));
    final result = await _repo.listLinkCases();
    if (!ref.mounted) return;
    state = state.copyWith(
      links: switch (result) {
        Success(:final value) => ListSlice(
          items: value.items,
          nextCursor: value.nextCursor,
          hasMore: value.hasMore,
          total: value.totalEstimate,
          loaded: true,
        ),
        FailureResult(:final failure) => state.links.copyWith(loading: false, failure: failure, loaded: true),
      },
    );
  }

  // ---------------------------------------------------------------- карточка

  /// Выбрать пользователя (`?userId=`); `null` — закрыть карточку.
  Future<void> select(String? id) async {
    if (id == null) {
      state = state.copyWith(clearSelected: true, versionConflict: false);
      return;
    }
    final fromList = state.users.items.where((u) => u.id == id).firstOrNull;
    state = state.copyWith(clearSelected: true, versionConflict: false);
    state = state.copyWith(selectedId: id, selected: fromList);
    await refreshSelected();
  }

  /// Перечитать карточку (`GET /admin/users/{id}`; «Обновить» баннера UI-45-020).
  Future<void> refreshSelected() async {
    final id = state.selectedId;
    if (id == null) return;
    state = state.copyWith(selectedLoading: true, clearSelectedFailure: true);
    final result = await _repo.getUser(id);
    if (!ref.mounted || state.selectedId != id) return;
    switch (result) {
      case Success(:final value):
        _replaceUser(value);
        state = state.copyWith(selectedLoading: false, versionConflict: false);
      case FailureResult(:final failure):
        state = state.copyWith(selectedLoading: false, selectedFailure: failure);
    }
  }

  void _replaceUser(AdminUser user) {
    final items = [for (final u in state.users.items) u.id == user.id ? user : u];
    state = state.copyWith(
      users: state.users.copyWith(items: items),
      selected: state.selectedId == user.id ? user : null,
      selectedId: state.selectedId,
    );
  }

  AdminActionResult<T> _track<T>(AdminActionResult<T> result) {
    final failure = result.failureOrNull;
    if (failure is ConflictFailure && failure.kind == ConflictKind.versionConflict) {
      state = state.copyWith(versionConflict: true);
    }
    return result;
  }

  // ---------------------------------------------------------------- действия (S!)

  /// Сменить роль (UI-45-005): `PUT /admin/users/{id}/roles` + step-up `users.roles.assign`.
  Future<AdminActionResult<AdminUser>> changeRole(
    AdminUser user,
    RoleCode role, {
    required String reason,
    required String idempotencyKey,
    required StepUpObtainer obtain,
  }) async {
    final result = await _runner.run(
      operation: AdminStepUpOperations.rolesAssign,
      obtain: obtain,
      call: (token) => _repo.setRoles(
        user.id,
        roles: [role],
        reason: reason,
        rowVersion: user.rowVersion,
        idempotencyKey: idempotencyKey,
        stepUpToken: token,
      ),
    );
    if (!ref.mounted) return result;
    if (result case ActionDone(:final value)) _replaceUser(value);
    return _track(result);
  }

  /// Заблокировать / разблокировать (UI-45-007): step-up `users.manage`.
  Future<AdminActionResult<AdminUser>> setBlocked(
    AdminUser user, {
    required bool blocked,
    required String reason,
    required String idempotencyKey,
    required StepUpObtainer obtain,
  }) async {
    final result = await _runner.run(
      operation: AdminStepUpOperations.usersManage,
      obtain: obtain,
      call: (token) => _repo.setBlocked(
        user.id,
        blocked: blocked,
        reason: reason,
        idempotencyKey: idempotencyKey,
        stepUpToken: token,
      ),
    );
    if (!ref.mounted) return result;
    if (result case ActionDone(:final value)) _replaceUser(value);
    return _track(result);
  }

  /// Завершить все сессии (UI-45-006): step-up `session.revoke.any` → «Устройств: 0».
  Future<AdminActionResult<void>> logoutAll(
    AdminUser user, {
    required String idempotencyKey,
    required StepUpObtainer obtain,
  }) async {
    final result = await _runner.run<void>(
      operation: AdminStepUpOperations.sessionRevokeAny,
      obtain: obtain,
      call: (token) => _repo.logoutAll(user.id, idempotencyKey: idempotencyKey, stepUpToken: token),
    );
    if (!ref.mounted) return result;
    if (result is ActionDone<void>) {
      final current = state.users.items.where((u) => u.id == user.id).firstOrNull ?? state.selected ?? user;
      _replaceUser(current.copyWith(devicesCount: 0));
    }
    return result;
  }

  /// Сбросить PIN (UI-45-007): step-up `users.pin.reset` → 204.
  Future<AdminActionResult<void>> resetPin(AdminUser user, {required String reason, required StepUpObtainer obtain}) =>
      _runner.run<void>(
        operation: AdminStepUpOperations.pinReset,
        obtain: obtain,
        call: (token) => _repo.resetPin(user.id, reason: reason, stepUpToken: token),
      );

  /// Выдать аварийный код (UI-45-023): StepUpDialog ДО запроса, только PIN; без `Idempotency-Key`.
  /// Код возвращается вызывающему диалогу и в состоянии контроллера не хранится.
  Future<AdminActionResult<EmergencyLoginCode>> issueEmergencyCode(
    AdminUser user, {
    required EmergencyCodeReason reason,
    String? comment,
    required StepUpObtainer obtain,
  }) => _runner.run(
    operation: AdminStepUpOperations.emergencyCode,
    obtain: obtain,
    proactive: true,
    methods: const [StepUpMethod.pin],
    call: (token) => _repo.issueEmergencyCode(user.id, reason: reason, comment: comment, stepUpToken: token),
  );

  /// Активировать `pending_activation` (UI-45-012): `POST /admin/users`, step-up `users.manage`.
  Future<AdminActionResult<AdminUser>> activate(
    AdminUser user,
    RoleCode role, {
    required String idempotencyKey,
    required StepUpObtainer obtain,
  }) async {
    final phone = user.phone;
    final name = user.fullName?.trim() ?? '';
    if (phone == null || !user.hasFullPhone || name.length < InvitationRules.fullNameMin) {
      return const ActionFailed(ValidationFailure());
    }
    final result = await _runner.run(
      operation: AdminStepUpOperations.usersManage,
      obtain: obtain,
      call: (token) => _repo.activate(
        phoneE164: phone,
        fullName: name,
        role: role,
        idempotencyKey: idempotencyKey,
        stepUpToken: token,
      ),
    );
    if (!ref.mounted) return result;
    if (result case ActionDone(:final value)) _replaceUser(value);
    return result;
  }

  /// Создать приглашение (UI-45-009): `POST /admin/invitations` + `Idempotency-Key`, step-up `invitations.manage`.
  /// Новая строка — вверху вкладки «Приглашения» (AC-UI-45-003).
  Future<AdminActionResult<Invitation>> createInvitation(
    InvitationDraft draft, {
    required String idempotencyKey,
    required StepUpObtainer obtain,
  }) async {
    final result = await _runner.run(
      operation: AdminStepUpOperations.invitationsManage,
      obtain: obtain,
      call: (token) => _repo.createInvitation(draft, idempotencyKey: idempotencyKey, stepUpToken: token),
    );
    if (!ref.mounted) return result;
    if (result case ActionDone(:final value)) {
      final rest = [
        for (final i in state.invitations.items)
          if (i.id != value.id) i,
      ];
      state = state.copyWith(invitations: state.invitations.copyWith(items: [value, ...rest], loaded: true));
      if (value.appliedToUserId != null) unawaited(reloadUsers());
    }
    return result;
  }

  /// Отозвать приглашение (UI-45-011): `DELETE /admin/invitations/{id}`, step-up `invitations.manage`.
  Future<AdminActionResult<void>> revokeInvitation(Invitation invitation, {required StepUpObtainer obtain}) async {
    final result = await _runner.run<void>(
      operation: AdminStepUpOperations.invitationsManage,
      obtain: obtain,
      call: (token) => _repo.revokeInvitation(invitation.id, stepUpToken: token),
    );
    if (!ref.mounted) return result;
    if (result is ActionDone<void>) {
      final items = [
        for (final i in state.invitations.items)
          i.id == invitation.id ? i.withStatus(InvitationStatus.revoked.value) : i,
      ];
      state = state.copyWith(invitations: state.invitations.copyWith(items: items));
    }
    return result;
  }

  /// Подтвердить привязку (UI-45-018): step-up `customer.link.resolve`.
  Future<AdminActionResult<CustomerLinkCandidate>> confirmLink(
    CustomerLinkCandidate link, {
    String? comment,
    required String idempotencyKey,
    required StepUpObtainer obtain,
  }) => _resolveLink(link, confirm: true, comment: comment, idempotencyKey: idempotencyKey, obtain: obtain);

  /// Отклонить привязку (UI-45-018): step-up `customer.link.resolve`.
  Future<AdminActionResult<CustomerLinkCandidate>> rejectLink(
    CustomerLinkCandidate link, {
    String? comment,
    required String idempotencyKey,
    required StepUpObtainer obtain,
  }) => _resolveLink(link, confirm: false, comment: comment, idempotencyKey: idempotencyKey, obtain: obtain);

  Future<AdminActionResult<CustomerLinkCandidate>> _resolveLink(
    CustomerLinkCandidate link, {
    required bool confirm,
    String? comment,
    required String idempotencyKey,
    required StepUpObtainer obtain,
  }) async {
    final result = await _runner.run(
      operation: AdminStepUpOperations.linkResolve,
      obtain: obtain,
      call: (token) => confirm
          ? _repo.confirmLink(
              link.customerId,
              link.id,
              comment: comment,
              idempotencyKey: idempotencyKey,
              stepUpToken: token,
            )
          : _repo.rejectLink(
              link.customerId,
              link.id,
              comment: comment,
              idempotencyKey: idempotencyKey,
              stepUpToken: token,
            ),
    );
    if (!ref.mounted) return result;
    if (result case ActionDone(:final value)) {
      final items = [for (final c in state.links.items) c.customerId == link.customerId ? c.withLink(value) : c];
      state = state.copyWith(links: state.links.copyWith(items: items));
    }
    return result;
  }
}
