// SCR-06 «Привязка к карточке клиента 1С» (02 SCR-06; 08 §4.2.2, §4.2.4; ядро §22.12).
// Финансовые данные не запрашиваются и не показываются до `confirmed` (SRC-B-145).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/registration/domain/entities/registration_entities.dart';
import 'package:optomstroy/features/registration/registration_providers.dart';

enum CustomerLinkPhase { loading, ready, loadError, confirming, rejecting, confirmed }

final class CustomerLinkState {
  const CustomerLinkState({
    this.phase = CustomerLinkPhase.loading,
    this.match = CustomerMatch.none,
    this.actionError = false,
    this.waitAdmin = false,
  });

  final CustomerLinkPhase phase;
  final CustomerMatch match;

  /// Снекбар «Повторить» после сетевой/серверной ошибки confirm/reject.
  final bool actionError;

  /// `409 CUSTOMER_LINK_CONFLICT` / `403 self_service_disabled` → «Ожидает подтверждения администратором».
  final bool waitAdmin;

  bool get busy => phase == CustomerLinkPhase.confirming || phase == CustomerLinkPhase.rejecting;

  /// Кнопки «Да, это я / Нет, это не я» (02 SCR-06.4).
  bool get canDecide => !waitAdmin && match.canSelfResolve && phase != CustomerLinkPhase.confirmed;

  CustomerLinkState copyWith({CustomerLinkPhase? phase, CustomerMatch? match, bool? actionError, bool? waitAdmin}) =>
      CustomerLinkState(
        phase: phase ?? this.phase,
        match: match ?? this.match,
        actionError: actionError ?? this.actionError,
        waitAdmin: waitAdmin ?? this.waitAdmin,
      );
}

final customerLinkProvider = NotifierProvider.autoDispose<CustomerLinkController, CustomerLinkState>(
  CustomerLinkController.new,
);

final class CustomerLinkController extends Notifier<CustomerLinkState> {
  bool _inFlight = false;
  bool? _lastConfirm;

  @override
  CustomerLinkState build() => const CustomerLinkState();

  Future<void> load() async {
    state = state.copyWith(phase: CustomerLinkPhase.loading, actionError: false);
    final res = await ref.read(registrationRepositoryProvider).customerMatch();
    state = switch (res) {
      Success<CustomerMatch>(:final value) => state.copyWith(
        phase: CustomerLinkPhase.ready,
        match: value,
        waitAdmin: value.nextStep == CustomerMatchNextStep.waitAdmin,
      ),
      FailureResult<CustomerMatch>() => state.copyWith(phase: CustomerLinkPhase.loadError),
    };
  }

  /// «Да, это я».
  Future<void> confirm() => _resolve(confirm: true);

  /// «Нет, это не я» (после ConfirmDialog).
  Future<void> reject() => _resolve(confirm: false);

  /// «Повторить» в снекбаре — то же действие (операция идемпотентна по состоянию привязки).
  Future<void> retry() async {
    final last = _lastConfirm;
    if (last == null) return load();
    return _resolve(confirm: last);
  }

  Future<void> _resolve({required bool confirm}) async {
    _lastConfirm = confirm;
    final linkId = state.match.linkId;
    if (_inFlight || linkId == null || !state.canDecide) return;
    _inFlight = true;
    state = state.copyWith(
      phase: confirm ? CustomerLinkPhase.confirming : CustomerLinkPhase.rejecting,
      actionError: false,
    );
    final repo = ref.read(registrationRepositoryProvider);
    final res = confirm ? await repo.confirmCustomerMatch(linkId) : await repo.rejectCustomerMatch(linkId);
    _inFlight = false;
    switch (res) {
      case Success<CustomerMatch>(:final value):
        state = state.copyWith(
          match: value,
          phase: value.status == CustomerLinkStatus.confirmed ? CustomerLinkPhase.confirmed : CustomerLinkPhase.ready,
        );
      case FailureResult<CustomerMatch>(:final failure):
        await _onFailure(failure);
    }
  }

  Future<void> _onFailure(Failure failure) async {
    switch (failure) {
      case ConflictFailure(kind: ConflictKind.customerLinkConflict):
      case PermissionFailure():
        state = state.copyWith(phase: CustomerLinkPhase.ready, waitAdmin: true);
      case ServerFailure(code: 'NOT_FOUND'):
        // Привязка не своя / уже не `proposed` — показать фактическое состояние.
        await load();
      default:
        state = state.copyWith(phase: CustomerLinkPhase.ready, actionError: true);
    }
  }
}
