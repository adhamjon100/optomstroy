// Публичный контракт фичи catalog (06 §6.1 L-3 (2), §6.14; FL-07): провайдеры портов domain.
//
// Реализации подключает композиционный корень `app/di/overrides.dart` списком `catalogBindings`
// (data/catalog_bindings.dart, L-8). Без него провайдеры бросают `UnimplementedError`.
// В widget-тестах — `ProviderScope(overrides: [catalogRepositoryProvider.overrideWithValue(fake), …])`.
// presentation не импортирует core/hardware (FL-02): признак камеры-сканера для кнопки скана шапки реэкспортируется
// отсюда (`cameraScannerSupportedProvider`: Android/iOS вне браузера; Windows и web — без камеры, D-42).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_json_decoder.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_repository.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_user_settings_store.dart';

export 'package:optomstroy/core/hardware/hardware_providers.dart' show cameraScannerSupportedProvider;

Never _unbound(String name) => throw UnimplementedError('$name: подключите catalogBindings в app/di/overrides.dart');

/// Категории, товары, карточка, справочники (сеть + кэш drift).
final catalogRepositoryProvider = Provider<CatalogRepository>((ref) => _unbound('catalogRepositoryProvider'));

/// Поиск (`/search/*`) и поиск по кэшу.
final searchRepositoryProvider = Provider<SearchRepository>((ref) => _unbound('searchRepositoryProvider'));

/// Остатки (`/inventory/*`) и остатки из кэша.
final inventoryRepositoryProvider = Provider<InventoryRepository>((ref) => _unbound('inventoryRepositoryProvider'));

/// Загрузка офлайн-кэша каталога `GET /catalog/sync/{entity}` (RM-E-009, core/sync).
final catalogSyncRepositoryProvider = Provider<CatalogSyncRepository>(
  (ref) => _unbound('catalogSyncRepositoryProvider'),
);

/// Статус обмена с 1С и прогоны (`/sync/status`, `/sync/runs`).
final syncStatusRepositoryProvider = Provider<SyncStatusRepository>((ref) => _unbound('syncStatusRepositoryProvider'));

/// Настройки экранов каталога в drift `settings` БД текущего пользователя (вид, сортировка, сайдбар, история поиска —
/// EQ-CAT-05, EQ-CAT-06). `null` — БД пользователя не открыта (до входа, тесты): presentation хранит значения в памяти
/// процесса. Смена пользователя меняет экземпляр (БД — файл пользователя), поэтому значения не переходят к другому.
final catalogUserSettingsStoreProvider = Provider<CatalogUserSettingsStore?>((ref) => null);

/// Разбор `ProductSummary` для фич-потребителей (favorites) без импорта catalog/data (FL-06).
final catalogJsonDecoderProvider = Provider<CatalogJsonDecoder>((ref) => _unbound('catalogJsonDecoderProvider'));

/// Роль текущего пользователя для экранов каталога (цены по роли, поведение сканера, показ остатков):
/// фича catalog не импортирует auth (DAG 06 §6.1), значение подставляет корень `app/di/overrides.dart`
/// из профиля входа (`authSessionProvider.profile.primaryRole`) и вида пользователя сессии.
/// `null` — пользователь неизвестен (до входа). Права проверяет сервер (D-15).
final catalogViewerRoleProvider = Provider<RoleCode?>((ref) => null);
