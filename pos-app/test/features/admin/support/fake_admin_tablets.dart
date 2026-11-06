// Фейки SCR-54 «Планшеты магазина» (13 TAB-2-02; ADR-115) для widget-тестов: репозиторий планшетов (step-up
// требуется, пока не предъявлен токен из [FakeAdminTabletsRepository.validTokens]), порт «это устройство — планшет»
// и переопределения провайдеров. Данные тестовые: UUID-заглушки, имена планшетов, без телефонов и ФИО людей.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/features/admin/admin_providers.dart';
import 'package:optomstroy/features/admin/domain/tablets/admin_tablets_repository.dart';
import 'package:optomstroy/features/admin/domain/tablets/store_tablet.dart';
import 'package:optomstroy/features/admin/domain/users/admin_viewer.dart';

import 'fake_admin_repository.dart';

const String tabletAId = '0192f3a1-6c3e-7a1b-9f00-0000000005a1';
const String tabletBId = '0192f3a1-6c3e-7a1b-9f00-0000000005b1';
const String warehouseMainId = '0192f3a1-6c3e-7a1b-9f00-000000000101';
const String warehouseSecondId = '0192f3a1-6c3e-7a1b-9f00-000000000102';
const String warehouseClosedId = '0192f3a1-6c3e-7a1b-9f00-000000000103';

/// Access JWT планшета для ответов подключения (клиент подпись не проверяет).
const String kioskAccessStub = 'kiosk-access-stub';

const List<TabletWarehouse> testWarehouses = <TabletWarehouse>[
  TabletWarehouse(id: warehouseSecondId, name: 'Склад №2'),
  TabletWarehouse(id: warehouseMainId, name: 'Основной', isDefaultForPos: true),
  TabletWarehouse(id: warehouseClosedId, name: 'Закрытый', isActive: false),
];

StoreTablet tablet(
  String id, {
  String name = 'Планшет у входа',
  String warehouseId = warehouseMainId,
  StoreTabletStatus status = StoreTabletStatus.active,
  DateTime? lastSeenAt,
  bool? lockTaskEnabled,
  String? appVersion = '1.4.2+87',
  DateTime? expiresAt,
}) => StoreTablet(
  id: id,
  name: name,
  warehouseId: warehouseId,
  status: status,
  enrolledAt: t0.subtract(const Duration(days: 10)),
  lastSeenAt: lastSeenAt,
  lockTaskEnabled: lockTaskEnabled,
  appVersion: appVersion,
  expiresAt: expiresAt,
);

/// Фейк [AdminTabletsRepository]: подключение, подключение заново и отключение — только с токеном step-up.
final class FakeAdminTabletsRepository implements AdminTabletsRepository {
  FakeAdminTabletsRepository({List<StoreTablet>? tablets, List<TabletWarehouse>? warehouses})
    : tablets = tablets ?? <StoreTablet>[],
      stock = warehouses ?? testWarehouses;

  List<StoreTablet> tablets;

  /// Справочник складов (`GET /catalog/warehouses`).
  List<TabletWarehouse> stock;
  final Set<String> validTokens = <String>{'step-up-token'};
  final List<RepoCall> calls = <RepoCall>[];

  /// Следующее подключение / подключение заново ответит этим отказом (один раз, после step-up).
  Failure? nextConnectFailure;

  /// Отказ загрузки списка.
  Failure? failList;

  /// Выданные аварийные коды по порядку (каждое подключение — новый код, ADR-115 п. 20).
  final List<String> issuedCodes = <String>[];
  int _codes = 0;

  Result<T>? _gate<T>(String? token) => token != null && validTokens.contains(token)
      ? null
      : FailureResult<T>(stepUpRequired(KioskAdminOperations.manage));

  KioskEnrollment _issue(StoreTablet t) {
    _codes++;
    final String code = (24681357 + _codes * 1111).toString().padLeft(8, '0');
    issuedCodes.add(code);
    return KioskEnrollment(
      tablet: t,
      accessToken: kioskAccessStub,
      refreshToken: 'rk$_codes', // check-secrets: allow (тест)
      exitCode: code,
    );
  }

  @override
  Future<Result<List<StoreTablet>>> list() async {
    calls.add(const RepoCall('list'));
    if (failList != null) return FailureResult<List<StoreTablet>>(failList!);
    return Success<List<StoreTablet>>(List<StoreTablet>.of(tablets));
  }

  @override
  Future<Result<List<TabletWarehouse>>> warehouses() async {
    calls.add(const RepoCall('warehouses'));
    return Success<List<TabletWarehouse>>(stock);
  }

  @override
  Future<Result<KioskEnrollment>> enroll({
    required String name,
    required String warehouseId,
    required String idempotencyKey,
    String? stepUpToken,
  }) async {
    calls.add(
      RepoCall(
        'enroll',
        idempotencyKey: idempotencyKey,
        stepUpToken: stepUpToken,
        args: <String, Object?>{'name': name, 'warehouseId': warehouseId},
      ),
    );
    final Result<KioskEnrollment>? gate = _gate<KioskEnrollment>(stepUpToken);
    if (gate != null) return gate;
    final Failure? fail = nextConnectFailure;
    if (fail != null) {
      nextConnectFailure = null;
      return FailureResult<KioskEnrollment>(fail);
    }
    final StoreTablet t = tablet(tabletAId, name: name, warehouseId: warehouseId);
    return Success<KioskEnrollment>(_issue(t));
  }

  @override
  Future<Result<KioskEnrollment>> reconnect(String id, {required String idempotencyKey, String? stepUpToken}) async {
    calls.add(RepoCall('reconnect', id: id, idempotencyKey: idempotencyKey, stepUpToken: stepUpToken));
    final Result<KioskEnrollment>? gate = _gate<KioskEnrollment>(stepUpToken);
    if (gate != null) return gate;
    final Failure? fail = nextConnectFailure;
    if (fail != null) {
      nextConnectFailure = null;
      return FailureResult<KioskEnrollment>(fail);
    }
    final StoreTablet t = tablets.firstWhere((StoreTablet x) => x.id == id);
    return Success<KioskEnrollment>(_issue(t));
  }

  @override
  Future<Result<StoreTablet>> update(String id, {String? name, String? warehouseId}) async {
    calls.add(RepoCall('update', id: id, args: <String, Object?>{'name': name, 'warehouseId': warehouseId}));
    final StoreTablet old = tablets.firstWhere((StoreTablet x) => x.id == id);
    final StoreTablet next = tablet(
      id,
      name: name ?? old.name,
      warehouseId: warehouseId ?? old.warehouseId,
      status: old.status,
      lastSeenAt: old.lastSeenAt,
      lockTaskEnabled: old.lockTaskEnabled,
      appVersion: old.appVersion,
      expiresAt: old.expiresAt,
    );
    tablets = <StoreTablet>[for (final StoreTablet x in tablets) x.id == id ? next : x];
    return Success<StoreTablet>(next);
  }

  @override
  Future<Result<StoreTablet>> revoke(String id, {String? stepUpToken}) async {
    calls.add(RepoCall('revoke', id: id, stepUpToken: stepUpToken));
    final Result<StoreTablet>? gate = _gate<StoreTablet>(stepUpToken);
    if (gate != null) return gate;
    final StoreTablet old = tablets.firstWhere((StoreTablet x) => x.id == id);
    final StoreTablet next = tablet(
      id,
      name: old.name,
      warehouseId: old.warehouseId,
      status: StoreTabletStatus.revoked,
      lastSeenAt: old.lastSeenAt,
      lockTaskEnabled: old.lockTaskEnabled,
      appVersion: old.appVersion,
    );
    tablets = <StoreTablet>[for (final StoreTablet x in tablets) x.id == id ? next : x];
    return Success<StoreTablet>(next);
  }
}

/// Порт «это устройство — планшет»: записывает удержание сессии и переход.
final class FakeKioskDevice implements AdminKioskDevice {
  FakeKioskDevice({this.known});

  String? known;
  int holds = 0;
  int releases = 0;
  final List<KioskEnrollment> became = <KioskEnrollment>[];

  /// `become` бросит исключение (переход не удался).
  bool failBecome = false;

  @override
  Future<String?> knownTabletId() async => known;

  @override
  void holdSession() => holds++;

  @override
  void releaseSession() => releases++;

  @override
  Future<void> become(KioskEnrollment enrollment) async {
    if (failBecome) throw StateError('become');
    became.add(enrollment);
  }
}

/// Переопределения SCR-54: репозиторий, зритель, порт устройства, флаг `features.storeTablet`, рекомендуемая версия.
List<Override> tabletsOverrides(
  FakeAdminTabletsRepository repo, {
  AdminViewer me = adminViewer,
  FakeKioskDevice? device,
  bool kioskEnabled = true,
  String? recommendedVersion,
  FakeStepUpPrompter? prompter,
  Clock? clock,
}) => <Override>[
  ...adminTestOverrides(
    FakeAdminUsersRepository(me: me),
    prompter: prompter,
    clock: clock,
  ),
  adminTabletsRepositoryProvider.overrideWithValue(repo),
  adminKioskDeviceProvider.overrideWithValue(device),
  adminKioskEnabledProvider.overrideWithValue(kioskEnabled),
  adminRecommendedAppVersionProvider.overrideWithValue(recommendedVersion),
];
