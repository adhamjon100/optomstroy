// Публичный контракт фичи catalog (06 §6.1 L-3 (2), §6.14; FL-07): провайдеры портов domain.
//
// Реализации подключает композиционный корень `app/di/overrides.dart` списком `catalogBindings`
// (data/catalog_bindings.dart, L-8). Без него провайдеры бросают `UnimplementedError`.
// В widget-тестах — `ProviderScope(overrides: [catalogRepositoryProvider.overrideWithValue(fake), …])`.
// presentation не импортирует core/hardware (FL-02): признак камеры-сканера для кнопки скана шапки реэкспортируется
// отсюда (`cameraScannerSupportedProvider`: Android/iOS вне браузера; Windows и web — без камеры, D-42).
//
// Планшет магазина (SCR-51 «Витрина и корзина», 02 ч. F; ADR-115 п. 8, 22; 13 TAB-2-03): витрина — экран фичи
// catalog (`presentation/screens/kiosk_catalog_view.dart`), а аварийный выход (фича kiosk) и карточка товара (фича
// product_details) фиче catalog недоступны по DAG 06 §6.1 — их подставляет корень (`app/router/shells/
// kiosk_mode_bindings.dart`) через порты [catalogKioskLogoWrapperProvider], [catalogKioskProductDetailsProvider],
// [catalogKioskStartOverProvider]. Без привязки: логотип без долгого нажатия, карточка не открывается, «Начать заново»
// очищает только состояние витрины.
import 'package:flutter/widgets.dart';
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

// ---------------------------------------------------------------------------
// Планшет магазина: витрина SCR-51 (02 ч. F; ADR-115)
// ---------------------------------------------------------------------------

/// Обёртка логотипа шапки SCR-51 (UI-51-002): долгое нажатие 5 с открывает аварийный выход UI-51-017 (фича kiosk,
/// P-002 §8.9 п. 2). Тап по логотипу — без действия.
typedef CatalogKioskLogoWrapper = Widget Function(Widget logo);

/// Аварийный выход на логотипе витрины; `null` — логотип без долгого нажатия (тесты, корень без режима планшета).
final catalogKioskLogoWrapperProvider = Provider<CatalogKioskLogoWrapper?>((ref) => null);

/// Аргументы слоя карточки товара SCR-51 (UI-51-011): только память слоя, в адрес не пишутся (02 SCR-51.6).
typedef CatalogKioskProductArgs = ({String productId, String? variantId});

/// Содержимое слоя карточки товара SCR-14 в варианте покупателя поверх `/kiosk` (без маршрута, ADR-115 п. 22): без
/// таблицы складов, избранного и «Недавних», запросы без `warehouseId`.
typedef CatalogKioskProductBuilder = Widget Function(BuildContext context, CatalogKioskProductArgs args);

/// Карточка товара витрины (фича product_details через корень); `null` — тап по карточке ничего не открывает.
final catalogKioskProductDetailsProvider = Provider<CatalogKioskProductBuilder?>((ref) => null);

/// «Начать заново» SCR-51 (UI-51-005; 04 FLOW-045.S3–S4): сброс планшета вне витрины — `POST /kiosk/reset {cartId}`,
/// новая пустая корзина, очистка буфера обмена (оркестратор сброса, 13 TAB-2-05). Витрина сама сбрасывает свои
/// категорию, поиск, фильтры, вид, сортировку и прокрутку и ждёт завершения (кнопка — в загрузке, повтор игнорируется).
/// `null` — сбрасывается только состояние витрины.
final catalogKioskStartOverProvider = Provider<Future<void> Function()?>((ref) => null);
