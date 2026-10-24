// SCR-07 «Аккаунт ожидает активации» (только `CUSTOMER_SELF_SERVICE=false`; 02 SCR-07; 09 §7.5).
// `GET /me` при открытии, раз в 60 с (не чаще раза в 30 с — 09 §2.2), при возврате из фона;
// «Проверить статус» — немедленно, затем кулдаун 5 с.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/registration/domain/entities/registration_entities.dart';
import 'package:optomstroy/features/registration/registration_providers.dart';

final class PendingActivationState {
  const PendingActivationState({
    this.account,
    this.checking = false,
    this.checkedAt,
    this.checkError = false,
    this.cooldownUntil,
    this.blocked = false,
  });

  final AccountSnapshot? account;
  final bool checking;
  final DateTime? checkedAt;
  final bool checkError;
  final DateTime? cooldownUntil;
  final bool blocked;

  bool get activated => account?.isActive ?? false;

  PendingActivationState copyWith({
    AccountSnapshot? account,
    bool? checking,
    DateTime? checkedAt,
    bool? checkError,
    DateTime? cooldownUntil,
    bool? blocked,
  }) => PendingActivationState(
    account: account ?? this.account,
    checking: checking ?? this.checking,
    checkedAt: checkedAt ?? this.checkedAt,
    checkError: checkError ?? this.checkError,
    cooldownUntil: cooldownUntil ?? this.cooldownUntil,
    blocked: blocked ?? this.blocked,
  );
}

final pendingActivationProvider = NotifierProvider.autoDispose<PendingActivationController, PendingActivationState>(
  PendingActivationController.new,
);

final class PendingActivationController extends Notifier<PendingActivationState> {
  static const Duration pollInterval = Duration(seconds: 60);
  static const Duration minInterval = Duration(seconds: 30);
  static const Duration manualCooldown = Duration(seconds: 5);

  @override
  PendingActivationState build() => const PendingActivationState();

  DateTime get _now => ref.read(clockProvider).nowUtc();

  /// Автопроверка: не чаще раза в 30 с.
  Future<void> autoCheck() async {
    final last = state.checkedAt;
    if (last != null && _now.difference(last) < minInterval) return;
    await _check();
  }

  /// «Проверить статус» (UI-07-006).
  Future<void> manualCheck() async {
    final until = state.cooldownUntil;
    if (until != null && _now.isBefore(until)) return;
    await _check();
    state = state.copyWith(cooldownUntil: _now.add(manualCooldown));
  }

  Future<void> _check() async {
    if (state.checking) return;
    state = state.copyWith(checking: true, checkError: false);
    final res = await ref.read(registrationRepositoryProvider).fetchAccount();
    switch (res) {
      case Success<AccountSnapshot>(:final value):
        state = state.copyWith(account: value, checking: false, checkedAt: _now, blocked: value.isBlocked);
      case FailureResult<AccountSnapshot>(:final failure):
        state = state.copyWith(
          checking: false,
          checkError: true,
          blocked: failure is PermissionFailure || state.blocked,
        );
    }
  }

  /// «Выйти из аккаунта» (UI-07-008).
  Future<void> logout() => ref.read(registrationRepositoryProvider).logout();
}
