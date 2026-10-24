import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:go_router/go_router.dart';
import 'package:logging/logging.dart';
import 'package:optomstroy/app/di/catalog_cart_adapter.dart';
import 'package:optomstroy/app/di/checkout_prefs_drift_store.dart';
import 'package:optomstroy/app/di/file_selector_document_saver.dart';
import 'package:optomstroy/app/di/order_repeat_cart_adapter.dart';
import 'package:optomstroy/app/di/printer_settings_port.dart';
import 'package:optomstroy/app/di/printer_test_page_pdf.dart';
import 'package:optomstroy/app/di/scan_cart_adapter.dart';
import 'package:optomstroy/app/di/scan_catalog_adapter.dart';
import 'package:optomstroy/app/di/stage_g_overrides.dart';
import 'package:optomstroy/app/router/app_router.dart';
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/app/router/shells/customer_mode_bindings.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart' show OnlineStatus;
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/settings_dao.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/pending_logout.dart' show pendingLogoutServiceProvider;
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/sync/auth_logout_outbox.dart';
import 'package:optomstroy/core/sync/outbox_handlers.dart';
import 'package:optomstroy/core/sync/outbox_queue.dart' show OutboxActionHandler;
import 'package:optomstroy/core/sync/sync_journal_api.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/design_system/components/date_range_picker.dart' show DsBishkekTime;
import 'package:optomstroy/features/admin/data/admin_bindings.dart';
import 'package:optomstroy/features/auth/auth_providers.dart' as auth;
import 'package:optomstroy/features/auth/data/auth_bindings.dart';
import 'package:optomstroy/features/auth/domain/entities/verify_outcome.dart' as auth_domain;
import 'package:optomstroy/features/cart/cart_providers.dart' as cart;
import 'package:optomstroy/features/cart/data/cart_bindings.dart';
import 'package:optomstroy/features/cart/data/draft/cart_draft_bindings.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart' show CartRepository;
import 'package:optomstroy/features/cart/presentation/providers/cart_banner_port.dart';
import 'package:optomstroy/features/cart/presentation/providers/cart_submission_port.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_fab_view.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_panel_view.dart';
import 'package:optomstroy/features/cashier/data/cashier_bindings.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart' as catalog;
import 'package:optomstroy/features/catalog/data/local/catalog_offline_bindings.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart' as catalog_ports;
import 'package:optomstroy/features/checkout/data/checkout_bindings.dart';
import 'package:optomstroy/features/checkout/presentation/controllers/order_submission_recovery.dart';
import 'package:optomstroy/features/checkout/presentation/providers/checkout_ports.dart' as checkout_ports;
import 'package:optomstroy/features/checkout/presentation/providers/checkout_printing.dart';
import 'package:optomstroy/features/checkout/presentation/widgets/order_submission_overlay.dart';
import 'package:optomstroy/features/customers/data/customers_bindings.dart';
import 'package:optomstroy/features/customers/presentation/new/new_customer_controller.dart'
    show newCustomerViewerRoleProvider;
import 'package:optomstroy/features/favorites/data/favorites_bindings.dart';
import 'package:optomstroy/features/notifications/data/notifications_bindings.dart';
import 'package:optomstroy/features/notifications/presentation/notifiers/notifications_center_controller.dart';
import 'package:optomstroy/features/notifications/presentation/widgets/notification_announcements.dart';
import 'package:optomstroy/features/notifications/presentation/widgets/notifications_connected.dart';
import 'package:optomstroy/features/orders/data/orders_bindings.dart';
import 'package:optomstroy/features/orders/presentation/providers/orders_ports.dart' as orders_ports;
import 'package:optomstroy/features/orders/presentation/providers/printing_document_printer.dart';
import 'package:optomstroy/features/product_details/presentation/widgets/variant_replace_sheet.dart';
import 'package:optomstroy/features/profile/data/profile_bindings.dart';
import 'package:optomstroy/features/registration/data/registration_bindings.dart';
import 'package:optomstroy/features/registration/registration_providers.dart' as reg;
import 'package:optomstroy/features/reports/data/reports_bindings.dart';
import 'package:optomstroy/features/returns/data/returns_bindings.dart';
import 'package:optomstroy/features/scan/domain/scan_lookup.dart' show ScanCartPort;
import 'package:optomstroy/features/scan/presentation/scanner_settings_section.dart';
import 'package:optomstroy/features/scan/scan_providers.dart' as scan;
import 'package:optomstroy/features/settings/data/settings_bindings.dart';
import 'package:optomstroy/features/settings/presentation/widgets/printer_section.dart';
import 'package:optomstroy/features/settings/settings_providers.dart' as settings;
import 'package:optomstroy/features/sync_status/presentation/widgets/sync_connected_widgets.dart';
import 'package:optomstroy/features/transactions/data/transactions_bindings.dart';

final Logger _log = Logger('app.di');

/// Единый композиционный корень (06 §6.10, правило L-8).
///
/// Сюда добавляются списки переопределений фич из
/// `features/<f>/data/<f>_bindings.dart` (провайдер-интерфейс → реализация data).
/// Это единственное место вне фичи, которому разрешён импорт `features/*/data/**`
/// (проверка FL-06 в `scripts/check_layers.py`).
///
/// Этап D (RM-D-012): вход (auth), регистрация и криптопривязка биометрии (registration),
/// администрирование пользователей (admin); переходы регистрации — [AppRegistrationNavigator].
final List<Override> appOverrides = <Override>[
  // Локальная БД пользователя (07 §11.1 п. 2): открывается после входа/разблокировки по `sub` access-токена,
  // закрывается при завершении сессии. Без неё кэш каталога, черновик корзины, избранное и outbox не работают.
  appDatabaseProvider.overrideWith(userDatabase),
  ...authBindings,
  ...registrationOverrides,
  ...adminOverrides,
  // Этап E: каталог, поиск, остатки, офлайн-кэш и статус синхронизации; избранное и недавние.
  // RM-E-009: `catalogBindings` + композиция «кэш → сеть» и порты core/sync (замена, не дополнение списка).
  ...catalogOfflineFirstBindings,
  ...favoritesBindings,
  // SCR-42 «Настройки»: сессии, защита входа, отображение, «О приложении» (RM-D-009).
  ...settingsBindings,
  // SCR-42 «Принтер» (UI-42-014, UI-42-020…022; RM-G-008): формат и автопечать — `/me/settings`, адрес и порт ESC/POS —
  // устройство, тестовая печать 80 мм — ESC/POS по TCP, A4 — системный диалог с PDF-образцом.
  settings.settingsPrinterSectionProvider.overrideWith(appPrinterSectionBuilder),
  // SCR-42 «Сканер штрихкодов» — секция фичи scan; окончание скана сохраняется в `Settings.scanner.suffix`.
  settings.settingsScannerSectionProvider.overrideWith(
    (Ref ref) =>
        (BuildContext context) => ScannerSettingsSection(
          showHeader: false,
          onSuffixChanged: (suffix) => unawaited(
            ref.read(settings.loginProtectionRepositoryProvider).patchSettings(<String, Object?>{
              'scanner': <String, Object?>{'suffix': suffix.apiValue},
            }),
          ),
        ),
  ),
  // Этап E (RM-E-008): локальная корзина-черновик («В корзину» на SCR-14); полная корзина — этап F.
  ...cartDraftBindings,
  // Этап F (основа): серверная корзина, заказы и платежи, оформление (+ черновик `checkout_draft`), клиенты
  // (поиск, карточка, SCR-26), уведомления. Кодеки вложенных Customer/Cart/Order — через порты фич (FL-06).
  ...customersBindings,
  ...cartBindings,
  ...ordersBindings,
  ...checkoutBindings,
  ...notificationsBindings,
  // Этап G (основа): дашборд кассира, журнал операций, заявки на возврат, отчёты руководителя, профиль (SCR-30, SCR-36…
  // SCR-39, SCR-41, SCR-48); справочник клиентов, долги и избранные клиенты — в `customersBindings`, SCR-46/SCR-47 —
  // в `adminOverrides`. Кодеки вложенных Customer/OrderSummary/Payment — через порты фич (FL-06).
  ...cashierBindings,
  ...transactionsBindings,
  ...returnsBindings,
  ...reportsBindings,
  ...profileBindings,
  // RM-F-005 (F-fe-cart): очередь `cart.sync`, роль/пользователь корзины, CartPanel/CartFab и «+ Добавить» каталога.
  ...cartUiOverrides,
  // RM-F-011 (интеграция F): роль/сеть/печать/«Скачать PDF»/«Повторить заказ» SCR-24/25, роль, печать и
  // предпочтения SCR-21/22, бейдж и popover уведомлений, баннеры уведомлений SCR-20/21/24.
  ...stageFOverrides,
  // RM-G-009/RM-G-010 (интеграция G): долг из флага сервера, «В заказ» и «Заказы и операции» SCR-32, роль SCR-39,
  // печать SCR-37/SCR-38, сотрудники фильтра SCR-36 (app/di/stage_g_overrides.dart).
  ...stageGOverrides(appOrderDocumentPrinterProvider),
  // RM-G-008, SCR-43 полный режим (FLOW-033.S6): ошибки прогона и очередь «в 1С» с ручным повтором.
  syncJournalPortProvider.overrideWith((Ref ref) => DioSyncJournal(ref.watch(dioProvider))),
  // RM-E-017: режим клиента (SCR-50, `customer_stock_display`, `customerSelfService`), избранное/недавние
  // и статус сети каталога (EQ-CAT-02).
  ...customerModeOverrides,
  catalog.catalogViewerRoleProvider.overrideWith(catalogViewerRole),
  // Шапка SCR-10: имя пользователя из профиля входа (ПДн — только память) и `SyncIndicator` core/sync (тап → SCR-43).
  catalog_ports.catalogViewerNameProvider.overrideWith(
    (Ref ref) => ref.watch(auth.authSessionProvider.select((s) => s.profile.displayName)),
  ),
  // История поиска — только текущего пользователя (02 SCR-10.4.A): выход, `SESSION_REVOKED`, смена пользователя
  // меняют пользователя сессии и очищают её.
  catalog_ports.catalogSessionUserProvider.overrideWith((Ref ref) => ref.watch(sessionUserIdProvider)),
  // Вид — по классу окна: compact — только иконка, иначе иконка + «обновлено HH:MM» (02 SCR-10.3 A6).
  catalog_ports.catalogSyncIndicatorProvider.overrideWithValue(
    (BuildContext context) => const ConnectedSyncIndicator(),
  ),
  // RM-E-010: поиск по штрихкоду (SCR-17, HID в оболочке) — `SearchRepository` каталога (кэш → сеть).
  scan.scanBarcodeLookupProvider.overrideWith(
    (Ref ref) => CatalogScanBarcodeLookup(ref.watch(catalog.searchRepositoryProvider)),
  ),
  ...scanCartOverrides,
  reg.registrationNavigatorProvider.overrideWith(AppRegistrationNavigator.new),
];

/// Корзина SCR-20 в приложении (RM-F-005, RM-F-013, RM-F-015):
/// - `outboxHandlersProvider` — обработчики core/sync (избранное, «очистить недавние») + `cart.sync` фичи cart
///   (07 §11.2) и `notification.read` фичи notifications; новые типы очереди дополняют этот же список;
/// - роль и пользователь сессии для корзины (`customer` — режим клиента; «своя» отложенная на вкладке «Все»);
/// - каталог: постоянная `CartPanel` на expanded (зона E SCR-10), `CartFab` на compact/medium, «+ Добавить».
final List<Override> cartUiOverrides = <Override>[
  outboxHandlersProvider.overrideWith(
    (Ref ref) => <OutboxActionHandler>[
      FavoriteOutboxHandler(dio: () => ref.read(dioProvider), database: () => ref.read(appDatabaseProvider)),
      RecentClearOutboxHandler(dio: () => ref.read(dioProvider)),
      // Отложенный выход (ядро §19.4, RC-1/SS-07) — как в списке core/sync по умолчанию.
      AuthLogoutOutboxHandler(service: () => ref.read(pendingLogoutServiceProvider), dio: () => ref.read(dioProvider)),
      ref.watch(cartOutboxHandlerProvider),
      // `notification.read` (F-fe-notif, RM-F-008).
      ...notificationsOutboxHandlers(ref),
      // `profile.settings` (EQ-DREST-07, FQ-TRN-06): офлайн-изменения настроек SCR-42.
      ...settingsOutboxHandlers(ref),
    ],
  ),
  cart.cartViewerRoleProvider.overrideWith((Ref ref) => ref.watch(catalog.catalogViewerRoleProvider)),
  cart.cartViewerUserIdProvider.overrideWith((Ref ref) => ref.watch(sessionUserIdProvider)),
  // FQ-CHK-06 / FIX-FE-08: ФИО пользователя сессии для «Подтвердил: {name}» (UI-20-033) и «Разрешено: {name}»
  // (UI-21-028) — профиль сессии фичи auth (только память).
  cart.cartViewerNameProvider.overrideWith(
    (Ref ref) => ref.watch(auth.authSessionProvider.select((auth.AuthSessionState s) => s.profile.displayName)),
  ),
  checkout_ports.checkoutViewerNameProvider.overrideWith(
    (Ref ref) => ref.watch(auth.authSessionProvider.select((auth.AuthSessionState s) => s.profile.displayName)),
  ),
  catalog_ports.catalogCartPanelProvider.overrideWithValue((BuildContext context) => const CartPanelView()),
  catalog_ports.catalogCartFabProvider.overrideWithValue((BuildContext context) => const CartFabView()),
  catalog_ports.catalogCartPortProvider.overrideWith(catalogCartPortFor),
  // CART-005 / UI-20-007: «Вариант» строки корзины → SCR-15 в режиме смены (лист фичи product_details).
  cart.cartVariantPickerProvider.overrideWithValue(showVariantReplaceSheet),
];

/// Интеграция этапа F (RM-F-011): порты presentation фич orders, checkout, catalog, cart → сессия, сеть, печать,
/// сохранение файла, уведомления (06 §6.1: фичи не импортируют друг друга, связь — только здесь).
final List<Override> stageFOverrides = <Override>[
  // SCR-24/25: роль и пользователь сессии; показ QR — при `QR_PROVIDER≠none` (клиенту — только `onec`, §24.4).
  orders_ports.ordersViewerProvider.overrideWith((Ref ref) {
    final RoleCode? role = ref.watch(catalog.catalogViewerRoleProvider);
    final QrProviderMode qr = ref.watch(publicFeatureFlagsProvider.select((PublicFeatureFlags f) => f.qrProvider));
    return orders_ports.OrdersViewer(
      role: role,
      userId: ref.watch(sessionUserIdProvider),
      qrShowEnabled: role == RoleCode.customer ? qr == QrProviderMode.onec : qr != QrProviderMode.none,
    );
  }),
  orders_ports.ordersOnlineStatusProvider.overrideWith(
    (Ref ref) => ref.watch(onlineStatusProvider).value ?? OnlineStatus.unknown,
  ),
  // Печать/просмотр PDF (RM-F-004, пакет `printing`; FQ-FEORD-09 снят dependency_overrides image 4.8.0).
  orders_ports.orderDocumentPrinterProvider.overrideWith((Ref ref) => ref.watch(appOrderDocumentPrinterProvider)),
  // «Скачать PDF» — системный диалог «Сохранить как…» (file_selector; Android/iOS — скрыто, FQ-INT-F-01).
  orders_ports.orderDocumentSaverProvider.overrideWith(
    (Ref ref) => fileSelectorSaveSupported(defaultTargetPlatform) ? const FileSelectorOrderDocumentSaver() : null,
  ),
  // «Повторить заказ» → активная корзина (`owner` — без корзины).
  orders_ports.orderRepeatPortProvider.overrideWith((Ref ref) {
    final RoleCode? role = ref.watch(catalog.catalogViewerRoleProvider);
    if (role == null || role == RoleCode.owner) return null;
    return CartSyncOrderRepeatPort(ref.watch(cart.cartSyncProvider), ref.watch(cart.cartRepositoryProvider));
  }),
  // «Открыть восстановленную корзину» SCR-24 (UI-24-015, ORD-027): SCR-20 или SCR-23.
  orders_ports.orderRestoredCartLocatorProvider.overrideWith((Ref ref) {
    final RoleCode? role = ref.watch(catalog.catalogViewerRoleProvider);
    if (role == null || role == RoleCode.owner) return null;
    final CartRepository repository = ref.watch(cart.cartRepositoryProvider);
    return (String orderId) => restoredCartLocation(repository, orderId);
  }),
  orders_ports.orderNotificationBannerProvider.overrideWithValue(
    (BuildContext context, String orderId) => NotificationBannerSlot(scope: NotificationBannerScope.order, id: orderId),
  ),
  // SCR-21/22/26: роль из профиля входа (FQ-CHK-08), печать (FQ-CHK-07), предпочтения устройства (FQ-CHK-12).
  checkout_ports.checkoutViewerRoleProvider.overrideWith((Ref ref) => ref.watch(catalog.catalogViewerRoleProvider)),
  // SCR-26: «Всё равно создать» (`customer.create.force` — cashier, senior_seller, admin) и проверка ИНН до создания —
  // по роли из профиля входа (02 SCR-26; 11 §4.3; FQ-CHK-12).
  newCustomerViewerRoleProvider.overrideWith((Ref ref) => ref.watch(catalog.catalogViewerRoleProvider)),
  // UI-20-020: результат `POST /orders` неизвестен — корзина заблокирована оверлеем фичи checkout (CART-022 (а)).
  cartSubmissionLockedProvider.overrideWith(
    (Ref ref) => ref.watch(orderSubmissionRecoveryProvider.select((OrderSubmissionState s) => s.locked)),
  ),
  cartSubmissionOverlayProvider.overrideWithValue((BuildContext context) => const OrderSubmissionOverlay()),
  checkout_ports.checkoutPrinterProvider.overrideWith((Ref ref) => ref.watch(appCheckoutPrinterProvider)),
  checkout_ports.checkoutPrefsStoreProvider.overrideWith((Ref ref) {
    final AppDatabase? db = ref.watch(appDatabaseProvider);
    if (db == null) return checkout_ports.InMemoryCheckoutPrefsStore();
    final Clock clock = ref.watch(clockProvider);
    return DriftCheckoutPrefsStore(SettingsDao(db), nowMs: clock.nowMillis);
  }),
  checkout_ports.checkoutNotificationBannerProvider.overrideWithValue(
    (BuildContext context, String cartId) =>
        NotificationBannerSlot(scope: NotificationBannerScope.checkout, id: cartId, showOpenAction: true),
  ),
  cartNotificationBannerProvider.overrideWithValue(
    (BuildContext context, String cartId) => NotificationBannerSlot(scope: NotificationBannerScope.cart, id: cartId),
  ),
  // Колокольчик каталога (SCR-10, SCR-50): бейдж непрочитанных и ошибка синхронизации (UI-44-005), popover на
  // expanded (UI-44-003).
  catalog_ports.catalogUnreadNotificationsProvider.overrideWith(
    (Ref ref) => ref.watch(notificationsBadgeProvider.select((b) => b.unread)),
  ),
  catalog_ports.catalogSyncErrorNotificationProvider.overrideWith(
    (Ref ref) => ref.watch(notificationsBadgeProvider.select((b) => b.syncError)),
  ),
  catalog_ports.catalogNotificationsPopoverProvider.overrideWithValue(NotificationsPopover.show),
  // UI-44-011: снекбар о новых уведомлениях `severity=error` на экранах оболочки (02 SCR-44.4; FQ-NOTIF-08).
  notificationAnnouncementsEnabledProvider.overrideWithValue(true),
];

/// Печать/просмотр документов заказа в приложении (пакет `printing`). Отдельный провайдер корня — точка подмены для
/// integration_test (`bootstrap(overrides: …)`: провайдер порта уже переопределён в [stageFOverrides], а дважды
/// переопределять один провайдер Riverpod не позволяет).
final appOrderDocumentPrinterProvider = Provider<orders_ports.OrderDocumentPrinter?>(
  (Ref ref) => const PrintingOrderDocumentPrinter(),
);

/// Печать документов SCR-22 (счёт при появлении номера 1С — PRINT-009, «Печать») — системный диалог пакета `printing`.
/// Отдельный провайдер корня — точка подмены для integration_test (как [appOrderDocumentPrinterProvider]): системный
/// диалог печати Windows блокирует прогон.
final appCheckoutPrinterProvider = Provider<checkout_ports.CheckoutPrinter>((Ref ref) => printingCheckoutPrinter);

/// «+ Добавить» каталога для роли сессии: корзина пользователя; `owner` и неизвестная роль — без порта (карточка).
catalog_ports.CatalogCartPort? catalogCartPortFor(Ref ref) {
  final RoleCode? role = ref.watch(catalog.catalogViewerRoleProvider);
  if (role == null || role == RoleCode.owner) return null;
  return CartSyncCatalogCartPort(ref.watch(cart.cartSyncProvider));
}

/// Режим «сразу в корзину» для скана (ядро §19.4; 13 RM-E-014 п. 5):
/// - `scanAddsToCartProvider` — `Settings.scanAddsToCart` пользователя (SCR-42), без значения — умолчание роли
///   (`cashier` — вкл., прочие — выкл.);
/// - `scanCartPortProvider` — строка пишется в локальную корзину-черновик (RM-E-008); `owner` и `customer` — без
///   добавления сканом (скан открывает карточку). Отправка черновика на сервер — этап F.
final List<Override> scanCartOverrides = <Override>[
  scan.scanAddsToCartProvider.overrideWith(
    (Ref ref) =>
        ref.watch(settings.userScanAddsToCartProvider) ??
        scanAddsToCartByDefault(ref.watch(catalog.catalogViewerRoleProvider)),
  ),
  scan.scanCartPortProvider.overrideWith(scanCartPortFor),
];

/// Переходы экранов регистрации в графе приложения.
///
/// Отличие от навигатора фичи по умолчанию — «Готово»: сессия уже установлена в этом процессе
/// (`SessionController.establish`), поэтому переход сразу на главный экран режима (SCR-10/SCR-30/SCR-50),
/// а не через Splash (Splash ведёт `staff` на SCR-08 `cold` — это для холодного старта, 02 SCR-00.6).
/// Первый вход сотрудника: после установки PIN профиль входа переводится в `signedIn`.
final class AppRegistrationNavigator implements reg.RegistrationNavigator {
  /// Навигатор для [ref] (провайдер `registrationNavigatorProvider`).
  AppRegistrationNavigator(this._ref);

  final Ref _ref;
  static const reg.RegistrationNavigator _base = reg.GoRouterRegistrationNavigator();

  @override
  void toSecurity(BuildContext context) => _base.toSecurity(context);

  @override
  void backToForm(BuildContext context) => _base.backToForm(context);

  @override
  void toPhone(BuildContext context, reg.RegistrationExitReason reason) => _base.toPhone(context, reason);

  @override
  void toCustomerLink(BuildContext context) => _base.toCustomerLink(context);

  @override
  void toPendingActivation(BuildContext context) => _base.toPendingActivation(context);

  @override
  void toHome(BuildContext context) {
    final auth.AuthSessionState session = _ref.read(auth.authSessionProvider);
    if (session.status == auth.AuthSessionStatus.pinSetupRequired) {
      _ref.read(auth.authSessionProvider.notifier).signedIn(session.profile);
    }
    context.go(homeLocationFor(_ref.read(appModeProvider)));
  }
}

/// Владелец локальной БД — `sub` access-токена текущей сессии (`SessionState.userId`); копию держит
/// [featureBridgesProvider], чтобы [userDatabase] не зависел от контроллера сессии.
final sessionUserIdProvider = NotifierProvider<SessionUserIdNotifier, String?>(SessionUserIdNotifier.new);

/// Хранилище [sessionUserIdProvider].
final class SessionUserIdNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  /// Пользователь сессии сменился (вход, разблокировка, выход).
  void set(String? userId) => state = userId;
}

/// Мосты корня: пользователь сессии → [sessionUserIdProvider]; между фичами без межфичевого импорта (06 §6.1) —
/// билет регистрации после
/// `/auth/otp/verify → registration_required` (фича auth) передаётся фиче registration (SCR-03/04).
/// Билет — только память процесса (09 §7.1, ядро §19.3).
final featureBridgesProvider = Provider<void>((ref) {
  // Пользователь сессии → БД пользователя (`appDatabaseProvider`, см. [userDatabase]).
  // Начальное значение — после построения (провайдер не может менять другой провайдер во время build).
  ref.listen<String?>(
    sessionControllerProvider.select((s) => s.userId),
    (_, String? next) => ref.read(sessionUserIdProvider.notifier).set(next),
  );
  // Первый вход сотрудника (PIN ещё не задан, `pinSetupRequired`) и ожидание активации клиента: БД уже открыта,
  // но `GET /catalog/sync/*` отвечает 403 — первичная загрузка кэша повторяется сразу после перехода в `signedIn`,
  // а не через период планировщика (5 мин).
  ref.listen<auth.AuthSessionStatus>(auth.authSessionProvider.select((s) => s.status), (
    auth.AuthSessionStatus? previous,
    auth.AuthSessionStatus next,
  ) {
    if (next != auth.AuthSessionStatus.signedIn || previous == auth.AuthSessionStatus.signedIn) return;
    if (ref.read(appDatabaseProvider) == null) return;
    unawaited(ref.read(syncSchedulerProvider).onSignedIn());
  });
  final String? initialUserId = ref.read(sessionControllerProvider).userId;
  if (initialUserId != null) {
    scheduleMicrotask(() {
      if (ref.mounted) ref.read(sessionUserIdProvider.notifier).set(ref.read(sessionControllerProvider).userId);
    });
  }
  ref.listen<auth_domain.RegistrationTicket?>(auth.registrationTicketProvider, (
    _,
    auth_domain.RegistrationTicket? next,
  ) {
    if (next == null) {
      return;
    }
    ref
        .read(reg.registrationTicketProvider.notifier)
        .start(
          reg.RegistrationTicket(
            registrationToken: next.token,
            expiresAt: next.expiresAt,
            phoneE164: next.phoneE164,
            phoneMasked: next.phoneMasked,
          ),
        );
    // Билет фичи auth больше не нужен: владелец дальнейшего потока — registration.
    ref.read(auth.registrationTicketProvider.notifier).clear();
  }, fireImmediately: true);
});

/// Порт «сразу в корзину» для роли сессии: черновик корзины; `owner`, `customer` и неизвестная роль — `null`.
ScanCartPort? scanCartPortFor(Ref ref) {
  final RoleCode? role = ref.watch(catalog.catalogViewerRoleProvider);
  if (role == null || role == RoleCode.owner || role == RoleCode.customer) return null;
  return CartDraftScanCartPort(
    ref.watch(cart.cartDraftRepositoryProvider),
    // Этап F: изменение черновика сразу уходит в очередь `cart.sync` (RM-F-005).
    onChanged: () {
      try {
        unawaited(ref.read(cart.cartSyncProvider).sync());
      } on Object {
        // Синхронизация не подключена (тесты корня без cartBindings) — черновик отправит корзина позже.
      }
    },
  );
}

/// «Сразу добавлять в корзину» по умолчанию для роли (ядро §19.4): `cashier` — да, остальные — нет.
bool scanAddsToCartByDefault(RoleCode? role) => role == RoleCode.cashier;

/// Роль для экранов каталога: клиент сессии — `customer`, иначе главная роль профиля входа (фича auth).
RoleCode? catalogViewerRole(Ref ref) {
  if (ref.watch(sessionControllerProvider.select((s) => s.userKind)) == UserKind.customer) return RoleCode.customer;
  return ref.watch(auth.authSessionProvider.select((s) => s.profile.primaryRole));
}

/// БД текущего пользователя (`AppDatabase.forUser`, файл `pos_<userId>.db`); `null` — пользователь неизвестен
/// (до входа, после выхода, холодный старт до разблокировки). Смена пользователя закрывает прежнюю БД.
///
/// Зависит только от [sessionUserIdProvider], а не от `sessionControllerProvider`: контроллер сессии зависит от
/// `dioProvider`, а интерсепторы Dio читают `appDatabaseProvider` (`app_meta`) — прямая зависимость дала бы
/// цикл провайдеров (`CircularDependencyError` на первом же ответе API).
AppDatabase? userDatabase(Ref ref) {
  final String? userId = ref.watch(sessionUserIdProvider);
  if (userId == null) return null;
  final AppDatabase db;
  try {
    db = AppDatabase.forUser(userId);
  } on ArgumentError {
    _log.warning('userDatabase: идентификатор пользователя не UUID — локальная БД не открыта');
    return null;
  }
  // Закрытие — после текущего такта: подписки потоков drift (корзина, уведомления) успевают отписаться при
  // уничтожении контейнера, иначе `StreamQueryStore.close` ловит ConcurrentModificationError.
  ref.onDispose(() => unawaited(Future<void>.delayed(Duration.zero, db.close)));
  return db;
}

/// Построитель секции «Принтер» SCR-42 (порт создаётся один раз на сессию провайдера; тексты — локаль экрана).
settings.SettingsSectionBuilder appPrinterSectionBuilder(Ref ref) {
  final AppDatabase? db = ref.watch(appDatabaseProvider);
  final Clock clock = ref.watch(clockProvider);
  final orders_ports.OrderDocumentPrinter? printer = ref.watch(appOrderDocumentPrinterProvider);
  final AppPrinterSettingsPort port = AppPrinterSettingsPort(
    settings: ref.watch(settings.loginProtectionRepositoryProvider),
    dao: db == null ? null : SettingsDao(db),
    send: sendEscPosTcp,
    systemPrint: printer?.print,
    a4Sample: buildA4TestPage,
    stamp: () => DsBishkekTime.dateTime(clock.nowUtc()),
    device: _deviceName(),
    nowMs: clock.nowMillis,
  );
  return (BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    port.texts = PrinterTestTexts(
      title: l10n.settings_print_test_page_title,
      noAddress: l10n.settings_printer_address_error,
      notSent: l10n.ds_button_cancel,
    );
    return PrinterSettingsSection(port: port);
  };
}

String _deviceName() {
  try {
    return Platform.localHostname;
  } on Object {
    return Platform.operatingSystem;
  }
}
