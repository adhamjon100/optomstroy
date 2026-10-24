// Общая поддержка тестов core/sync (RM-E-009): фейковый сервер `GET /catalog/sync/{entity}` с курсорами,
// синтетический каталог, сборка стека «Dio (фейковый транспорт) → CatalogSyncRepositoryImpl → адаптер порта →
// CatalogSyncEngine» поверх drift в памяти. Синтетические данные, не реальная интеграция.
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/sync/catalog_sync_engine.dart';
import 'package:optomstroy/core/sync/sync_ports.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/features/catalog/data/datasources/catalog_remote_data_source.dart';
import 'package:optomstroy/features/catalog/data/local/catalog_sync_port_adapters.dart';
import 'package:optomstroy/features/catalog/data/repositories/catalog_repositories_impl.dart';

import '../database/test_database.dart';
import '../network/fake_adapter.dart';

const String unitId = '00000000-0000-4000-8000-00000000000a';
const String catId = '00000000-0000-4000-8000-0000000000c1';
const String whId = '00000000-0000-4000-8000-0000000000b1';
const String plId = '00000000-0000-4000-8000-0000000000d1';

const String serverTime = '2026-10-19T09:00:00Z';

Map<String, Object?> syncProduct(String id, {String? name, String? sku}) => {
  'id': id,
  'name': name ?? 'Смеситель $id',
  'sku': sku ?? 'SKU-$id',
  'categoryId': catId,
  'brand': 'Frap',
  'hasVariants': false,
  'defaultVariantId': 'v-$id',
  'baseUnit': {'id': unitId, 'code': 'шт', 'name': 'штука', 'qtyPrecision': 0},
  'attributes': {'color': 'хром'},
  'imageIds': <String>[],
  'deletionMark': false,
  'updatedAt': '2026-10-18T10:00:00Z',
};

Map<String, Object?> syncVariant(String productId) => {
  'id': 'v-$productId',
  'productId': productId,
  'isDefault': true,
  'name': 'Хром',
  'sku': 'SKU-$productId',
};

/// `id` — uuid строки сервера сверх схемы (EQ-CSYNC-02): `deleted[]` ссылается на него.
Map<String, Object?> syncPrice(String productId, String amount) => {
  'id': 'price-$productId',
  'variantId': 'v-$productId',
  'priceListId': plId,
  'price': {'amount': amount, 'currency': 'KGS'},
};

Map<String, Object?> syncStock(String productId, String available) => {
  'variantId': 'v-$productId',
  'warehouseId': whId,
  'available': available,
  'stockLevel': 'in_stock',
};

Map<String, Object?> syncBarcode(String productId, int n) => {
  'id': 'bc-$productId',
  'barcode': '46${n.toString().padLeft(11, '0')}',
  'variantId': 'v-$productId',
  'packagingId': null,
  'type': 'EAN13',
};

/// Разбить список на страницы.
List<List<Map<String, Object?>>> paged(List<Map<String, Object?>> items, int size) => [
  for (var i = 0; i < items.length; i += size) items.sublist(i, i + size > items.length ? items.length : i + size),
];

/// Синтетический каталог: [products] товаров (по одному варианту, цене, остатку и штрихкоду), страницы [pageSize].
Map<String, List<List<Map<String, Object?>>>> syntheticCatalog(int products, {int pageSize = 200}) {
  final ids = [for (var i = 1; i <= products; i++) 'p-$i'];
  return {
    'units': [
      [
        {'id': unitId, 'code': 'шт', 'name': 'штука', 'shortName': 'шт', 'qtyPrecision': 0},
      ],
    ],
    'categories': [
      [
        {'id': catId, 'name': 'Смесители', 'productCount': products, 'sortOrder': 1},
      ],
    ],
    'warehouses': [
      [
        {'id': whId, 'name': 'Основной', 'isActive': true},
      ],
    ],
    'price_lists': [
      [
        {
          'id': plId,
          'name': 'Розничная',
          'isDefault': true,
          'visibleToRoles': ['seller'],
        },
      ],
    ],
    'products': paged([for (final id in ids) syncProduct(id)], pageSize),
    'variants': paged([for (final id in ids) syncVariant(id)], pageSize),
    'packagings': <List<Map<String, Object?>>>[],
    'barcodes': paged([for (var i = 0; i < ids.length; i++) syncBarcode(ids[i], i + 1)], pageSize),
    'prices': paged([for (final id in ids) syncPrice(id, '1250.50')], pageSize),
    'stock': paged([for (final id in ids) syncStock(id, '24.000')], pageSize),
    'images': <List<Map<String, Object?>>>[],
  };
}

/// Фейковый `GET /catalog/sync/{entity}`: курсор `<entity>#<номер следующей страницы>`; после последней страницы
/// инкремент возвращает добавленные позже строки ([addLater]) и `deleted[]` ([deleteLater]).
final class FakeCatalogServer {
  FakeCatalogServer(this.pages);

  final Map<String, List<List<Map<String, Object?>>>> pages;

  /// Строки, появившиеся на сервере после выгрузки (отдаются инкрементом).
  final Map<String, List<Map<String, Object?>>> addLater = {};

  /// Удалённые на сервере идентификаторы (отдаются инкрементом в `deleted[]`).
  final Map<String, List<String>> deleteLater = {};

  /// Подмена ответа: вернуть не-`null`, чтобы ответить иначе (обрыв, ошибка).
  ResponseBody? Function(RequestOptions o, String entity, String? since)? fault;

  /// Прочие маршруты (`/favorites/...`, `/sync/status`): путь → обработчик.
  final Map<String, ResponseBody Function(RequestOptions o)> routes = {};

  final List<({String entity, String? since})> syncRequests = [];

  int countFor(String entity) => syncRequests.where((r) => r.entity == entity).length;

  Future<ResponseBody> handle(RequestOptions o) async {
    final path = o.uri.path.replaceFirst('/api/v1', '');
    final route = routes['${o.method} $path'] ?? routes[path];
    if (route != null) return route(o);
    const prefix = '/catalog/sync/';
    if (!path.startsWith(prefix)) return json(404, problem('NOT_FOUND', 404));
    final entity = path.substring(prefix.length);
    final since = o.uri.queryParameters['since'];
    syncRequests.add((entity: entity, since: since));
    final injected = fault?.call(o, entity, since);
    if (injected != null) return injected;
    final list = pages[entity] ?? const <List<Map<String, Object?>>>[];
    final index = since == null ? 0 : int.parse(since.split('#').last);
    if (index >= list.length) {
      final added = addLater.remove(entity) ?? const <Map<String, Object?>>[];
      final deleted = deleteLater.remove(entity) ?? const <String>[];
      final next = added.isEmpty && deleted.isEmpty ? index : index + 1;
      if (added.isNotEmpty) list.add(added);
      return json(200, {
        'items': added,
        'deleted': deleted,
        'nextCursor': '$entity#$next',
        'hasMore': false,
        'serverTime': serverTime,
      });
    }
    return json(200, {
      'items': list[index],
      'deleted': const <String>[],
      'nextCursor': '$entity#${index + 1}',
      'hasMore': index + 1 < list.length,
      'serverTime': serverTime,
    });
  }
}

/// Стек загрузки кэша поверх drift в памяти и фейкового транспорта.
final class SyncStack {
  SyncStack(this.server, {AppDatabase? database, FixedClock? clock})
    : db = database ?? _memoryDb(),
      clock = clock ?? FixedClock(DateTime.utc(2026, 10, 19, 10)) {
    adapter = FakeAdapter(server.handle);
    dio = Dio(BaseOptions(baseUrl: 'https://pos.test/api/v1'))..httpClientAdapter = adapter;
    remote = CatalogRemoteDataSource(dio);
    syncRepo = CatalogSyncRepositoryImpl(
      remote: remote,
      dao: () => db.catalogDao,
      appMeta: () => db.appMetaDao,
      clock: this.clock,
    );
    port = CatalogCachePortAdapter(syncRepo);
  }

  static AppDatabase _memoryDb() {
    configureSqliteForTests();
    return AppDatabase(NativeDatabase.memory());
  }

  final FakeCatalogServer server;
  final AppDatabase db;
  final FixedClock clock;
  late final FakeAdapter adapter;
  late final Dio dio;
  late final CatalogRemoteDataSource remote;
  late final CatalogSyncRepositoryImpl syncRepo;
  late final CatalogCachePortAdapter port;

  CatalogSyncEngine engine({SyncStatusPort? status, int pageSize = 200}) => CatalogSyncEngine(
    port: () => port,
    dao: () => db.catalogDao,
    status: status == null ? null : () => status,
    clock: clock,
    pageSize: pageSize,
  );
}

/// Управляемый источник сигнала сети для `ConnectivityWatcher`.
final class FakeNetworkSource implements NetworkSignalSource {
  FakeNetworkSource({this.network = true});

  bool network;
  final List<void Function(bool)> _listeners = [];

  @override
  Future<bool> hasNetwork() async => network;

  @override
  Stream<bool> get changes => Stream<bool>.multi((c) {
    void l(bool v) => c.add(v);
    _listeners.add(l);
    c.onCancel = () => _listeners.remove(l);
  });

  void set(bool value) {
    network = value;
    for (final l in List.of(_listeners)) {
      l(value);
    }
  }
}
