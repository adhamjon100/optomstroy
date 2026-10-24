// Провайдер-композиция «кэш → сеть» фичи catalog (RM-E-009; 06 §6.10, L-8, FL-06).
//
// Подключается в композиционном корне `app/di/overrides.dart` ВМЕСТО `catalogBindings` (тот же набор
// провайдеров-интерфейсов, интерфейсы не меняются):
//   - `catalogRepositoryProvider`, `searchRepositoryProvider`, `inventoryRepositoryProvider` — базовые
//     реализации этапа E (`CatalogRepositoryImpl` …), обёрнутые `OfflineFirst*Repository`: офлайн — кэш
//     drift, сбой сети — тот же запрос из кэша;
//   - `catalogSyncRepositoryProvider`, `syncStatusRepositoryProvider`, `catalogJsonDecoderProvider` — как в
//     `catalogBindings`;
//   - порты core/sync: `catalogCachePortProvider`, `syncStatusPortProvider` (адаптеры) и
//     `syncViewerRoleProvider` (= `catalogViewerRoleProvider`).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/core/database/daos/catalog_dao.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/data/catalog_bindings.dart' show catalogRemoteDataSourceProvider;
import 'package:optomstroy/features/catalog/data/local/catalog_sync_port_adapters.dart';
import 'package:optomstroy/features/catalog/data/local/drift_catalog_user_settings_store.dart';
import 'package:optomstroy/features/catalog/data/repositories/catalog_repositories_impl.dart';
import 'package:optomstroy/features/catalog/data/repositories/offline_first_repositories.dart';

CatalogDao? Function() _dao(Ref ref) =>
    () => ref.read(appDatabaseProvider)?.catalogDao;

OnlineProbe _online(Ref ref) =>
    () => ref.read(connectivityWatcherProvider).current;

/// Переопределения фичи catalog с офлайн-кэшем (замена `catalogBindings` в `appOverrides`).
final List<Override> catalogOfflineFirstBindings = <Override>[
  catalogRepositoryProvider.overrideWith(
    (Ref ref) => OfflineFirstCatalogRepository(
      base: CatalogRepositoryImpl(remote: ref.watch(catalogRemoteDataSourceProvider), dao: _dao(ref)),
      online: _online(ref),
    ),
  ),
  searchRepositoryProvider.overrideWith(
    (Ref ref) => OfflineFirstSearchRepository(
      base: SearchRepositoryImpl(remote: ref.watch(catalogRemoteDataSourceProvider), dao: _dao(ref)),
      online: _online(ref),
    ),
  ),
  inventoryRepositoryProvider.overrideWith(
    (Ref ref) => OfflineFirstInventoryRepository(
      base: InventoryRepositoryImpl(remote: ref.watch(catalogRemoteDataSourceProvider), dao: _dao(ref)),
      online: _online(ref),
    ),
  ),
  catalogSyncRepositoryProvider.overrideWith(
    (Ref ref) => CatalogSyncRepositoryImpl(
      remote: ref.watch(catalogRemoteDataSourceProvider),
      dao: _dao(ref),
      appMeta: () => ref.read(appDatabaseProvider)?.appMetaDao,
      clock: ref.watch(clockProvider),
    ),
  ),
  syncStatusRepositoryProvider.overrideWith(
    (Ref ref) => SyncStatusRepositoryImpl(ref.watch(catalogRemoteDataSourceProvider)),
  ),
  catalogJsonDecoderProvider.overrideWith((Ref ref) => const CatalogJsonDecoderImpl()),
  // EQ-CAT-05/06: вид, сортировка, сайдбар и история поиска — drift `settings` БД пользователя.
  catalogUserSettingsStoreProvider.overrideWith((Ref ref) {
    final db = ref.watch(appDatabaseProvider);
    return db == null ? null : DriftCatalogUserSettingsStore(db, ref.watch(clockProvider));
  }),
  catalogCachePortProvider.overrideWith((Ref ref) => CatalogCachePortAdapter(ref.watch(catalogSyncRepositoryProvider))),
  syncStatusPortProvider.overrideWith(
    (Ref ref) => SyncStatusPortAdapter(
      status: ref.watch(syncStatusRepositoryProvider),
      cache: ref.watch(catalogSyncRepositoryProvider),
    ),
  ),
  syncViewerRoleProvider.overrideWith((Ref ref) => ref.watch(catalogViewerRoleProvider)),
];
