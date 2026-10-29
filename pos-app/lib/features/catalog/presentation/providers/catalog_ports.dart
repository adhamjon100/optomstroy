// Точки подключения экранов каталога к соседним фичам без межфичевого импорта (06 §6.1, FL-03):
// favorites → catalog, а не наоборот; notifications, cart (RM-F-005), auth/profile — свои фичи.
// Провайдеры по умолчанию возвращают `null`/пустое значение: экран прячет соответствующий блок.
// Реализации подставляет композиционный корень `app/di/overrides.dart` (интегратор, EQ-CAT-02),
// в тестах — `overrideWithValue(fake)`.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';

/// Избранное и недавние товары для сайдбара SCR-10 (B4–B6), звезды карточек и подборок C6.
/// Адаптер над `FavoritesRepository` / `RecentProductsRepository` (фича favorites) — в корне.
abstract interface class CatalogShelfPort {
  /// Избранное (id товаров) — локальный кэш с неподтверждёнными действиями (`watchCachedIds`).
  Stream<Set<String>> watchFavoriteIds();

  /// Добавить/убрать (optimistic + outbox `favorite.add|remove` — у реализации, FAV-002).
  Future<Result<void>> setFavorite(String productId, {required bool favorite});

  /// Недавние товары (`GET /catalog/products/recent`, офлайн — кэш), новые первыми.
  Future<Result<List<RecentProduct>>> recentProducts({int limit = 5});

  /// «Очистить» недавние (`DELETE /catalog/products/recent`; офлайн — локально + outbox `recent.clear`).
  Future<Result<void>> clearRecent();
}

/// Корзина для «+ Добавить» на карточке (02 ч. B §2.3; `cartProvider` — RM-F-005).
/// Без реализации «+ Добавить» открывает карточку товара SCR-14 (EQ-CAT-04).
abstract interface class CatalogCartPort {
  /// Добавить шаг товара в корзину (вариант по умолчанию; INV-004/005 — у корзины). Отказ — корзина не изменена
  /// (например, сервер отклонил 201-ю строку, 10 CART-024): снекбар «Добавлено» не показывается.
  Future<Result<void>> add(ProductSummary product);

  /// Текст снекбара для отказа [failure] из [add] («Слишком много позиций (максимум 200)…», 02 SCR-20.8);
  /// `null` — общий текст ошибки.
  String? rejectionText(Failure failure, AppLocalizations l10n);
}

/// Порт избранного/недавних; `null` — блоки сайдбара и звёзды скрыты.
final catalogShelfPortProvider = Provider<CatalogShelfPort?>((ref) => null);

/// Порт корзины; `null` — «+ Добавить» ведёт в SCR-14.
final catalogCartPortProvider = Provider<CatalogCartPort?>((ref) => null);

/// Имя пользователя для шапки (`GET /me`); `null` — показывается только роль.
final catalogViewerNameProvider = Provider<String?>((ref) => null);

/// Идентификатор пользователя сессии — область данных «только для текущего пользователя» (история поиска,
/// 02 SCR-10.4.A): смена значения (выход, `SESSION_REVOKED`, вход другого пользователя) их сбрасывает.
/// Корень подставляет пользователя сессии; `null` — сессии нет.
final catalogSessionUserProvider = Provider<String?>((ref) => null);

/// Число непрочитанных уведомлений (`NotificationBell`, D-41); фича notifications подставит поток.
final catalogUnreadNotificationsProvider = Provider<int>((ref) => 0);

/// Есть непрочитанная ошибка синхронизации (`notifications_active`).
final catalogSyncErrorNotificationProvider = Provider<bool>((ref) => false);

/// Popover центра уведомлений под колокольчиком на expanded/large (02 SCR-44.2, UI-44-003); подставляет корень
/// (catalog ↛ notifications, 06 §6.1). `null` — колокольчик всегда открывает SCR-44 маршрутом.
final catalogNotificationsPopoverProvider = Provider<Future<void> Function(BuildContext context)?>((ref) => null);

/// `SyncIndicator` шапки (03 §9.40, UI-10-004; staff): виджет строит корень из `syncIndicatorProvider`
/// core/sync (агент офлайна); `null` — индикатор не показывается (EQ-CAT-02).
final catalogSyncIndicatorProvider = Provider<WidgetBuilder?>((ref) => null);

/// Количество в корзине-черновике по варианту (ключ — `variantId`; для товара без вариантов — `defaultVariantId`)
/// для кнопки карточки «В корзине · N — ещё +1» (прототип 2026-10-29, ADR-112). Только строки базовой единицы, без
/// строк, скрытых на время «Отменить». Корень подставляет черновик фичи cart (catalog ↛ cart); по умолчанию пусто —
/// карточки показывают «+ Добавить». Карточка подписывается на своё значение (`select`), а не на всю карту.
final catalogCartQuantitiesProvider = Provider<Map<String, Qty>>((ref) => const <String, Qty>{});

/// Кнопка-итог корзины в шапке medium+ (`TopAppBarCartButton`, 02 UI-10-041; ADR-112): строит корень из корзины
/// (фича cart, catalog ↛ cart по данным UI; в приложении — `CartHeaderButtonView`: итог сервера, drawer корзины 420
/// по нажатию и `F4`/`F8`/`F9`, слушатель фоновых событий корзины). `null` — кнопки нет (тесты оболочки и экранов без
/// корзины). Показывается только у ролей с корзиной (seller, senior_seller, cashier, admin; не owner и не customer).
/// Заменяет порт постоянной CP expanded (`catalogCartPanelProvider`, удалён в редакции 1.16, ADR-112).
final catalogCartButtonProvider = Provider<WidgetBuilder?>((ref) => null);

/// «Заблокировать» в меню аватара шапки (SCR-08, ручная блокировка сессии — как Ctrl+L, 02 SCR-10.3 A9);
/// корень подставляет `sessionController.lock(manual)`. `null` — пункта нет.
final catalogHeaderLockProvider = Provider<VoidCallback?>((ref) => null);

/// Запрос фокуса в поле поиска каталога (поиск начат в шапке оболочки на другой ветке → SCR-11, ввод
/// продолжается в поле каталога). Каждое увеличение значения — один запрос; слушает `CatalogWorkspace`.
final catalogSearchFocusRequestProvider = NotifierProvider<CatalogSearchFocusRequest, int>(
  CatalogSearchFocusRequest.new,
);

/// Счётчик запросов фокуса в поле поиска каталога ([catalogSearchFocusRequestProvider]).
class CatalogSearchFocusRequest extends Notifier<int> {
  @override
  int build() => 0;

  /// Попросить каталог поставить фокус в поле поиска (курсор — в конец строки).
  void request() => state++;
}

/// `CartFab` на compact и у `customer` на medium (02 UI-20-019 / UI-10-040 редакции 1.16; RM-F-005): строит корень
/// из корзины (фича cart); `null` — панели-итога нет.
final catalogCartFabProvider = Provider<WidgetBuilder?>((ref) => null);

/// Доступность сервера для `OfflineBanner` каталога. По умолчанию `unknown` — офлайн определяется по
/// `NetworkFailure` запросов списка; корень подставляет `onlineStatusProvider` (core/di) — EQ-CAT-02.
final catalogOnlineStatusProvider = Provider<OnlineStatus>((ref) => OnlineStatus.unknown);

/// Избранное (id) из порта; без порта — пусто.
final catalogFavoriteIdsProvider = StreamProvider<Set<String>>((ref) {
  final CatalogShelfPort? port = ref.watch(catalogShelfPortProvider);
  return port == null ? Stream<Set<String>>.value(const <String>{}) : port.watchFavoriteIds();
});
