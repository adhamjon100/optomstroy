// Состояние и действия SCR-54 «Планшеты магазина» (02 SCR-54.4, SCR-54.7, SCR-54.11; 08 §4.18.11–§4.18.15; FLOW-043;
// ADR-115): загрузка списка, справочника складов, зрителя (`GET /me`: `kiosk.read` — `admin`, `owner`; `kiosk.manage` —
// только `admin`; зритель неизвестен — только просмотр, fail-closed) и признака планшета на устройстве (предвыбор
// UI-54-013); подключение и подключение заново — step-up `kiosk.manage` и `Idempotency-Key` вызывающего (повтор после
// обрыва — тем же ключом); изменение — без step-up; отключение — step-up, повтор безопасен. Данные списка не кэшируются
// (02 SCR-54.12); stepUpToken живёт только в памяти `StepUpRunner`; аварийный код в состояние не попадает.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/admin/admin_providers.dart';
import 'package:optomstroy/features/admin/domain/tablets/admin_tablets_repository.dart';
import 'package:optomstroy/features/admin/domain/tablets/store_tablet.dart';
import 'package:optomstroy/features/admin/domain/users/admin_viewer.dart';
import 'package:optomstroy/features/admin/domain/users/step_up.dart';

final class AdminTabletsState {
  const AdminTabletsState({
    this.loading = true,
    this.failure,
    this.tablets,
    this.warehouses = const <TabletWarehouse>[],
    this.viewer,
    this.knownTabletId,
  });

  final bool loading;
  final Failure? failure;

  /// `null` — ещё не загружены.
  final List<StoreTablet>? tablets;
  final List<TabletWarehouse> warehouses;
  final AdminViewer? viewer;

  /// `store_tablets.id` из признака планшета на устройстве (если сохранился).
  final String? knownTabletId;

  /// Подключать, изменять и отключать может только `admin` (`kiosk.manage`); зритель неизвестен — нет.
  bool get canManage {
    final AdminViewer? v = viewer;
    return v != null && v.can(AdminPermissions.kioskManage, byRole: v.isAdmin);
  }

  /// Название склада по id (`null` — справочник недоступен или склад неизвестен).
  String? warehouseName(String id) => warehouses.where((TabletWarehouse w) => w.id == id).firstOrNull?.name;

  AdminTabletsState copyWith({
    bool? loading,
    Failure? failure,
    bool clearFailure = false,
    List<StoreTablet>? tablets,
    List<TabletWarehouse>? warehouses,
    AdminViewer? viewer,
    String? knownTabletId,
  }) => AdminTabletsState(
    loading: loading ?? this.loading,
    failure: clearFailure ? null : (failure ?? this.failure),
    tablets: tablets ?? this.tablets,
    warehouses: warehouses ?? this.warehouses,
    viewer: viewer ?? this.viewer,
    knownTabletId: knownTabletId ?? this.knownTabletId,
  );
}

final adminTabletsControllerProvider = NotifierProvider.autoDispose<AdminTabletsController, AdminTabletsState>(
  AdminTabletsController.new,
);

final class AdminTabletsController extends Notifier<AdminTabletsState> {
  late AdminTabletsRepository _repo;
  late StepUpRunner _runner;

  @override
  AdminTabletsState build() {
    _repo = ref.watch(adminTabletsRepositoryProvider);
    _runner = StepUpRunner(nowUtc: ref.watch(clockProvider).nowUtc);
    ref.onDispose(_runner.clear);
    scheduleMicrotask(() {
      if (ref.mounted) unawaited(load());
    });
    return const AdminTabletsState();
  }

  /// Забыть токены step-up (сворачивание приложения, уход с экрана).
  void forgetStepUp() => _runner.clear();

  /// Загрузка и «Повторить» / pull-to-refresh: список, склады, зритель и признак планшета — параллельно.
  Future<void> load() async {
    state = state.copyWith(loading: true, clearFailure: true);
    final AdminKioskDevice? device = ref.read(adminKioskDeviceProvider);
    final List<Object?> results = await Future.wait<Object?>(<Future<Object?>>[
      _repo.list(),
      _repo.warehouses(),
      ref.read(adminUsersRepositoryProvider).viewer(),
      device?.knownTabletId() ?? Future<String?>.value(),
    ]);
    if (!ref.mounted) return;
    final Result<List<StoreTablet>> list = results[0]! as Result<List<StoreTablet>>;
    final Result<List<TabletWarehouse>> warehouses = results[1]! as Result<List<TabletWarehouse>>;
    final Result<AdminViewer> viewer = results[2]! as Result<AdminViewer>;
    final Failure? failure = list.failureOrNull;
    if (failure != null) {
      state = state.copyWith(loading: false, failure: failure);
      return;
    }
    state = AdminTabletsState(
      loading: false,
      tablets: list.valueOrNull,
      // Справочник складов недоступен — строки без названия склада, форма — без выбора (ошибка у поля).
      warehouses: warehouses.valueOrNull ?? const <TabletWarehouse>[],
      viewer: viewer.valueOrNull,
      knownTabletId: results[3] as String?,
    );
  }

  /// «Сделать это устройство планшетом магазина»: `POST /admin/store-tablets` (step-up по `403`, повтор тем же ключом).
  Future<AdminActionResult<KioskEnrollment>> enroll({
    required String name,
    required String warehouseId,
    required String idempotencyKey,
    required StepUpObtainer obtain,
  }) => _runner.run<KioskEnrollment>(
    operation: KioskAdminOperations.manage,
    obtain: obtain,
    call: (String? token) =>
        _repo.enroll(name: name, warehouseId: warehouseId, idempotencyKey: idempotencyKey, stepUpToken: token),
  );

  /// «Подключить заново этот планшет»: `POST /admin/store-tablets/{id}/reconnect` (step-up, тот же ключ при повторе).
  Future<AdminActionResult<KioskEnrollment>> reconnect(
    String id, {
    required String idempotencyKey,
    required StepUpObtainer obtain,
  }) => _runner.run<KioskEnrollment>(
    operation: KioskAdminOperations.manage,
    obtain: obtain,
    call: (String? token) => _repo.reconnect(id, idempotencyKey: idempotencyKey, stepUpToken: token),
  );

  /// «Изменить»: `PATCH /admin/store-tablets/{id}` без step-up; строка — из ответа.
  Future<AdminActionResult<StoreTablet>> update(String id, {String? name, String? warehouseId}) async {
    final Result<StoreTablet> r = await _repo.update(id, name: name, warehouseId: warehouseId);
    if (!ref.mounted) return _done(r);
    if (r case Success<StoreTablet>(:final value)) _replace(value);
    return _done(r);
  }

  /// «Отключить планшет»: `POST /admin/store-tablets/{id}/revoke` (step-up); строка — «Отключён».
  Future<AdminActionResult<StoreTablet>> revoke(String id, {required StepUpObtainer obtain}) async {
    final AdminActionResult<StoreTablet> r = await _runner.run<StoreTablet>(
      operation: KioskAdminOperations.manage,
      obtain: obtain,
      call: (String? token) => _repo.revoke(id, stepUpToken: token),
    );
    if (!ref.mounted) return r;
    if (r case ActionDone<StoreTablet>(:final value)) _replace(value);
    return r;
  }

  void _replace(StoreTablet t) {
    final List<StoreTablet>? list = state.tablets;
    if (list == null) return;
    state = state.copyWith(tablets: <StoreTablet>[for (final StoreTablet x in list) x.id == t.id ? t : x]);
  }

  static AdminActionResult<T> _done<T>(Result<T> r) => switch (r) {
    Success<T>(:final value) => ActionDone<T>(value),
    FailureResult<T>(:final failure) => ActionFailed<T>(failure),
  };
}
