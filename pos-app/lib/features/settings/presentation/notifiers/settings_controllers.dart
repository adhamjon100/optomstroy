// Состояние секций SCR-42 «Устройства и сессии» и «Защита входа» (02 SCR-42.4, SCR-42.7, SCR-42.11).
// Повторные нажатия во время запроса игнорируются (тумблеры в `loading`, строки в `revoking`).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/settings/domain/entities/settings_entities.dart';
import 'package:optomstroy/features/settings/domain/repositories/settings_repositories.dart';
import 'package:optomstroy/features/settings/settings_providers.dart';

/// Состояние списка сессий.
final class SessionsViewState {
  const SessionsViewState({
    this.items = const <DeviceSession>[],
    this.loading = false,
    this.loaded = false,
    this.failure,
    this.asOf,
    this.busy = const <String>{},
    this.loggingOutAll = false,
  });

  final List<DeviceSession> items;
  final bool loading;

  /// Хотя бы один успешный ответ.
  final bool loaded;

  /// Ошибка последнего обновления (при [loaded] — баннер «Список устройств от {time}»).
  final Failure? failure;

  /// Время последнего успешного ответа.
  final DateTime? asOf;

  /// Строки с запросом в работе (завершение / переименование).
  final Set<String> busy;
  final bool loggingOutAll;

  bool get stale => loaded && failure != null;

  SessionsViewState copyWith({
    List<DeviceSession>? items,
    bool? loading,
    bool? loaded,
    Failure? failure,
    bool clearFailure = false,
    DateTime? asOf,
    Set<String>? busy,
    bool? loggingOutAll,
  }) => SessionsViewState(
    items: items ?? this.items,
    loading: loading ?? this.loading,
    loaded: loaded ?? this.loaded,
    failure: clearFailure ? null : (failure ?? this.failure),
    asOf: asOf ?? this.asOf,
    busy: busy ?? this.busy,
    loggingOutAll: loggingOutAll ?? this.loggingOutAll,
  );
}

/// «Устройства и сессии» (UI-42-013, UI-42-015…017).
final sessionsControllerProvider = NotifierProvider.autoDispose<SessionsController, SessionsViewState>(
  SessionsController.new,
);

final class SessionsController extends Notifier<SessionsViewState> {
  DeviceSessionsRepository get _repo => ref.read(deviceSessionsRepositoryProvider);

  @override
  SessionsViewState build() {
    scheduleMicrotask(() {
      if (ref.mounted) unawaited(refresh());
    });
    return const SessionsViewState(loading: true);
  }

  /// `GET /auth/sessions`.
  Future<void> refresh() async {
    state = state.copyWith(loading: true);
    final Result<List<DeviceSession>> res = await _repo.list();
    if (!ref.mounted) return;
    state = switch (res) {
      Success<List<DeviceSession>>(:final value) => state.copyWith(
        items: value,
        loading: false,
        loaded: true,
        clearFailure: true,
        asOf: ref.read(clockProvider).nowUtc(),
      ),
      FailureResult<List<DeviceSession>>(:final failure) => state.copyWith(loading: false, failure: failure),
    };
  }

  /// Завершить сессию другого устройства; `null` — успех (строка удалена).
  Future<Failure?> revoke(String id) async {
    if (state.busy.contains(id)) return null;
    state = state.copyWith(busy: <String>{...state.busy, id});
    final Result<void> res = await _repo.revoke(id);
    if (!ref.mounted) return res.failureOrNull;
    final Set<String> busy = <String>{...state.busy}..remove(id);
    if (res.isSuccess) {
      state = state.copyWith(
        items: <DeviceSession>[
          for (final DeviceSession s in state.items)
            if (s.id != id) s,
        ],
        busy: busy,
      );
      return null;
    }
    state = state.copyWith(busy: busy);
    return res.failureOrNull;
  }

  /// Переименовать устройство; `null` — успех.
  Future<Failure?> rename(String id, String name) async {
    if (state.busy.contains(id)) return null;
    state = state.copyWith(busy: <String>{...state.busy, id});
    final Result<DeviceSession> res = await _repo.rename(id, name);
    if (!ref.mounted) return res.failureOrNull;
    final Set<String> busy = <String>{...state.busy}..remove(id);
    switch (res) {
      case Success<DeviceSession>(:final value):
        state = state.copyWith(
          items: <DeviceSession>[for (final DeviceSession s in state.items) s.id == id ? value : s],
          busy: busy,
        );
        return null;
      case FailureResult<DeviceSession>(:final failure):
        state = state.copyWith(busy: busy);
        return failure;
    }
  }

  /// «Выйти» (текущая сессия).
  Future<void> logoutCurrent() => _repo.logoutCurrent();

  /// «Выйти на всех устройствах» (S!); `null` — выполнено (переход на SCR-01 делает роутер).
  Future<Failure?> logoutAll() async {
    if (state.loggingOutAll) return null;
    state = state.copyWith(loggingOutAll: true);
    final Result<void> res = await _repo.logoutAll();
    if (ref.mounted) state = state.copyWith(loggingOutAll: false);
    return res.failureOrNull;
  }
}

/// Состояние «Защиты входа».
final class SecurityViewState {
  const SecurityViewState({this.data, this.loading = false, this.failure, this.bioBusy = false, this.idleBusy = false});

  final LoginProtectionState? data;
  final bool loading;
  final Failure? failure;

  /// Тумблер биометрии ждёт ответа (спиннер в ползунке).
  final bool bioBusy;
  final bool idleBusy;

  SecurityViewState copyWith({
    LoginProtectionState? data,
    bool? loading,
    Failure? failure,
    bool clearFailure = false,
    bool? bioBusy,
    bool? idleBusy,
  }) => SecurityViewState(
    data: data ?? this.data,
    loading: loading ?? this.loading,
    failure: clearFailure ? null : (failure ?? this.failure),
    bioBusy: bioBusy ?? this.bioBusy,
    idleBusy: idleBusy ?? this.idleBusy,
  );
}

/// «Защита входа» (UI-42-009, UI-42-010, UI-42-023, UI-42-024, UI-42-026).
final securityControllerProvider = NotifierProvider.autoDispose<SecurityController, SecurityViewState>(
  SecurityController.new,
);

final class SecurityController extends Notifier<SecurityViewState> {
  LoginProtectionRepository get _repo => ref.read(loginProtectionRepositoryProvider);

  @override
  SecurityViewState build() {
    scheduleMicrotask(() {
      if (ref.mounted) unawaited(refresh());
    });
    return const SecurityViewState(loading: true);
  }

  Future<void> refresh() async {
    state = state.copyWith(loading: true);
    final Result<LoginProtectionState> res = await _repo.load();
    if (!ref.mounted) return;
    state = switch (res) {
      Success<LoginProtectionState>(:final value) => state.copyWith(data: value, loading: false, clearFailure: true),
      FailureResult<LoginProtectionState>(:final failure) => state.copyWith(loading: false, failure: failure),
    };
    if (res case Success<LoginProtectionState>(:final value)) {
      ref.read(userScanAddsToCartProvider.notifier).set(value.scanAddsToCart);
    }
  }

  /// `POST /me/pin` (step-up — интерсептор).
  Future<Result<void>> changePin(String newPin) async {
    final Result<void> res = await _repo.changePin(newPin);
    if (res.isSuccess && ref.mounted && state.data != null) {
      state = state.copyWith(data: state.data!.copyWith(pinSet: true));
    }
    return res;
  }

  /// Удалить PIN (`customer` при включённой биометрии).
  Future<Result<void>> removePin() async {
    final Result<void> res = await _repo.removePin();
    if (res.isSuccess && ref.mounted && state.data != null) {
      state = state.copyWith(data: state.data!.copyWith(pinSet: false));
    }
    return res;
  }

  /// Step-up перед сменой PIN (`otpOnly` — «Забыли PIN?»).
  Future<bool> stepUpForPin({required bool otpOnly}) => _repo.stepUpForPin(otpOnly: otpOnly);

  /// Включить/выключить биометрию.
  Future<BiometricToggleOutcome?> setBiometrics(bool enable, BiometricPromptCopy prompt) async {
    if (state.bioBusy) return null;
    state = state.copyWith(bioBusy: true);
    final BiometricToggleOutcome outcome = enable
        ? await _repo.enableBiometrics(prompt)
        : await _repo.disableBiometrics();
    if (!ref.mounted) return outcome;
    final LoginProtectionState? data = state.data;
    final bool? nowEnabled = switch (outcome) {
      BiometricToggleOutcome.enabled => true,
      BiometricToggleOutcome.disabled => false,
      _ => null,
    };
    state = state.copyWith(
      bioBusy: false,
      data: data == null || nowEnabled == null ? data : data.copyWith(biometricsEnabled: nowEnabled),
    );
    return outcome;
  }

  /// Автоблокировка (optimistic; ошибка — откат значения).
  Future<Failure?> setIdleLock(int minutes) async {
    final LoginProtectionState? data = state.data;
    if (data == null || state.idleBusy) return null;
    final int? previous = data.idleLockMinutes;
    state = state.copyWith(idleBusy: true, data: data.copyWith(idleLockMinutes: minutes));
    final Result<int> res = await _repo.setIdleLockMinutes(minutes);
    if (!ref.mounted) return res.failureOrNull;
    switch (res) {
      case Success<int>(:final value):
        state = state.copyWith(idleBusy: false, data: state.data!.copyWith(idleLockMinutes: value));
        return null;
      case FailureResult<int>(:final failure):
        final LoginProtectionState now = state.data ?? data;
        state = state.copyWith(
          idleBusy: false,
          data: previous == null ? now.copyWith(clearIdleLock: true) : now.copyWith(idleLockMinutes: previous),
        );
        return failure;
    }
  }

  /// Серверные настройки сканера (UI-42-011 режим, UI-42-019 «Сразу добавлять в корзину»): optimistic,
  /// ошибка — откат значения. `null` — сохранено.
  Future<Failure?> setScannerSettings({String? mode, bool? addsToCart}) async {
    final LoginProtectionState? data = state.data;
    if (data == null) return null;
    state = state.copyWith(
      data: data.copyWith(scannerMode: mode, scanAddsToCart: addsToCart),
    );
    // Режим скана каталога/SCR-17 меняется сразу (13 RM-E-014 п. 5: `scan_adds_to_cart` меняет поведение).
    final UserScanAddsToCart applied = ref.read(userScanAddsToCartProvider.notifier);
    if (addsToCart != null) applied.set(addsToCart);
    final Result<Map<String, Object?>> res = await _repo.patchSettings(<String, Object?>{
      if (mode != null) 'scanner': <String, Object?>{'mode': mode},
      'scanAddsToCart': ?addsToCart,
    });
    if (!ref.mounted) return res.failureOrNull;
    if (res case FailureResult<Map<String, Object?>>(:final failure)) {
      state = state.copyWith(data: data);
      if (addsToCart != null) applied.set(data.scanAddsToCart);
      return failure;
    }
    return null;
  }
}
