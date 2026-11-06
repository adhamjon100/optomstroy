// Привязка реализаций data к провайдерам-интерфейсам фичи catalog (06 §6.10, L-8, FL-06).
// Подключение: `app/di/overrides.dart` → `appOverrides = [..., ...catalogBindings]`.
// Сеть — единственный Dio-клиент `dioProvider` (core/di); кэш — `appDatabaseProvider`
// (БД пользователя `pos_<user_id>.db`, `null` до входа — методы кэша возвращают `CatalogCacheUnavailable`).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/core/database/daos/catalog_dao.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/session/session_overlay.dart' show kioskLocalWarehouseIdProvider;
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/data/datasources/catalog_remote_data_source.dart';
import 'package:optomstroy/features/catalog/data/repositories/catalog_repositories_impl.dart';

/// `CatalogRemoteDataSource` поверх общего Dio (внутренний провайдер data).
final catalogRemoteDataSourceProvider = Provider<CatalogRemoteDataSource>(
  (ref) => CatalogRemoteDataSource(ref.watch(dioProvider)),
);

/// Ленивый доступ к DAO кэша текущего пользователя.
CatalogDao? Function() _catalogDao(Ref ref) =>
    () => ref.read(appDatabaseProvider)?.catalogDao;

/// Склад чтений кэша без явного склада: у планшета магазина — склад планшета (только drift, не сеть; 10 KIOSK-007).
String? Function() _localWarehouse(Ref ref) =>
    () => ref.read(kioskLocalWarehouseIdProvider);

/// Переопределения фичи catalog для композиционного корня.
final List<Override> catalogBindings = <Override>[
  catalogRepositoryProvider.overrideWith(
    (Ref ref) => CatalogRepositoryImpl(
      remote: ref.watch(catalogRemoteDataSourceProvider),
      dao: _catalogDao(ref),
      localWarehouseId: _localWarehouse(ref),
    ),
  ),
  searchRepositoryProvider.overrideWith(
    (Ref ref) => SearchRepositoryImpl(
      remote: ref.watch(catalogRemoteDataSourceProvider),
      dao: _catalogDao(ref),
      localWarehouseId: _localWarehouse(ref),
    ),
  ),
  inventoryRepositoryProvider.overrideWith(
    (Ref ref) => InventoryRepositoryImpl(
      remote: ref.watch(catalogRemoteDataSourceProvider),
      dao: _catalogDao(ref),
      localWarehouseId: _localWarehouse(ref),
    ),
  ),
  catalogSyncRepositoryProvider.overrideWith(
    (Ref ref) => CatalogSyncRepositoryImpl(
      remote: ref.watch(catalogRemoteDataSourceProvider),
      dao: _catalogDao(ref),
      appMeta: () => ref.read(appDatabaseProvider)?.appMetaDao,
      clock: ref.watch(clockProvider),
    ),
  ),
  syncStatusRepositoryProvider.overrideWith(
    (Ref ref) => SyncStatusRepositoryImpl(ref.watch(catalogRemoteDataSourceProvider)),
  ),
  catalogJsonDecoderProvider.overrideWith((Ref ref) => const CatalogJsonDecoderImpl()),
];
