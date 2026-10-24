// Привязки режима клиента-покупателя (RM-E-017; ядро v1.9 §24.2; 02 SCR-50, ч. B — вариант `customer`)
// для композиционного корня `app/di/overrides.dart` (`...customerModeOverrides`).
//
// Фичи не импортируют друг друга сверх DAG 06 §6.1 (FL-03): корень связывает
// - SCR-50 (фича home) с содержимым `CustomerHomeView` (фича catalog; EQ-FEF-07, EQ-HOME-01);
// - показ остатков клиенту (`customer_stock_display`) и флаг `customerSelfService` из `GET /settings/public`
//   (core/config, RM-D-015) с портами catalog / product_details и guard-ом маршрутов (EQ-FEF-08, EQ-DREST-15);
// - «Мой кабинет» SCR-50 с `GET /me` (`customerLink`);
// - избранное и недавние каталога (`CatalogShelfPort`, EQ-CAT-02) с фичей favorites и outbox core/sync;
// - статус сети каталога с `onlineStatusProvider`;
// - этап G (RM-G-014): «Мой кабинет» — заказы в работе (`GET /orders`, `totalEstimate`) и свой долг
//   (`GET /customers/{id}/receivables` только при `confirmed`, только память сессии — CASH-015); своя привязка
//   для экранов клиента SCR-32…SCR-35 (`GET /me`, фича profile → порт фичи customers); цели уведомлений
//   клиента (`order_status` → свой заказ, без служебных разделов).
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/app/router/app_router.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart' as public_settings;
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/core/session/session_controller.dart' show sessionControllerProvider;
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/core/utils/customer_display_name.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart' as catalog;
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/catalog/presentation/providers/customer_mode_ports.dart';
import 'package:optomstroy/features/catalog/presentation/screens/customer_home_view.dart';
import 'package:optomstroy/features/customers/customers_providers.dart';
import 'package:optomstroy/features/customers/domain/entities/receivable.dart';
import 'package:optomstroy/features/customers/domain/repositories/receivables_repository.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart';
import 'package:optomstroy/features/favorites/favorites_providers.dart';
import 'package:optomstroy/features/home/home_providers.dart';
import 'package:optomstroy/features/notifications/presentation/notification_targets.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/repositories/orders_repository.dart';
import 'package:optomstroy/features/orders/orders_providers.dart';
import 'package:optomstroy/features/product_details/product_details_providers.dart' as product_details;
import 'package:optomstroy/features/profile/domain/entities/user_profile.dart';
import 'package:optomstroy/features/profile/profile_providers.dart';

/// Содержимое SCR-50 (`/home?view=&sort=`).
Widget customerHomeBody(BuildContext context, CustomerHomeArgs args) =>
    CustomerHomeView(view: args.view, sort: args.sort);

/// Переопределения режима клиента и общих портов каталога (подключаются в `appOverrides`).
final List<Override> customerModeOverrides = <Override>[
  customerHomeBodyProvider.overrideWithValue(customerHomeBody),
  // `customer_stock_display`: `status` (по умолчанию) — без чисел, `quantity` — доступное количество.
  catalogCustomerStockDisplayProvider.overrideWith(
    (Ref ref) => ref.watch(public_settings.customerStockDisplayProvider),
  ),
  product_details.customerStockDisplayProvider.overrideWith(
    (Ref ref) => ref.watch(public_settings.customerStockDisplayProvider),
  ),
  // `features.customerSelfService`: сервер → флаг сборки → `true` (08 §4.23.1); guard G-8 и UI-50-015.
  catalogCustomerSelfServiceProvider.overrideWith(
    (Ref ref) => ref.watch(public_settings.publicCustomerSelfServiceProvider),
  ),
  customerSelfServiceEnabledProvider.overrideWith(
    (Ref ref) => ref.watch(public_settings.publicCustomerSelfServiceProvider),
  ),
  // Этап G: guard-ы G-8 возвратов (`features.returnsFromPos`) и режима SCR-38 «по долгу» (`debtPaymentsFromPos`).
  routeFeaturesProvider.overrideWith(
    (Ref ref) => routeFeaturesFrom(ref.watch(public_settings.publicFeatureFlagsProvider)),
  ),
  customerHomePortProvider.overrideWith(
    (Ref ref) => MeCustomerHomePort(
      ref.watch(dioProvider),
      // Репозитории читаются при запросе сводки (не при сборке порта): тесты SCR-50 без привязок G не падают.
      receivables: () => ref.read(receivablesRepositoryProvider),
      orders: () => ref.read(ordersRepositoryProvider),
    ),
  ),
  // RM-G-014: своя привязка `customer` для SCR-32…SCR-35 (свои долг, история, скидки — только при `confirmed`).
  customerSelfLinkProvider.overrideWith(customerSelfLink),
  customersSelfServiceProvider.overrideWith((Ref ref) => ref.watch(public_settings.publicCustomerSelfServiceProvider)),
  // RM-G-014: уведомления клиента ведут только в разделы клиента (`order_status` → свой заказ SCR-24).
  notificationsCustomerModeProvider.overrideWith(
    (Ref ref) => ref.watch(catalog.catalogViewerRoleProvider) == RoleCode.customer,
  ),
  catalogShelfPortProvider.overrideWith(FavoritesCatalogShelf.new),
  // Звезда избранного SCR-14 — тот же адаптер над favorites/outbox (порт product_details, EQ-PD-03).
  product_details.productFavoritePortProvider.overrideWith(FavoritesCatalogShelf.new),
  catalogOnlineStatusProvider.overrideWith((Ref ref) => ref.watch(onlineStatusProvider).value ?? OnlineStatus.unknown),
];

/// Своя привязка клиента-покупателя по `GET /me` (фича profile); сотрудникам — `null`. Ошибка `/me` — `null`
/// (fail-closed: свои долг и история закрыты, 10 CUST-025). ПДн не сохраняются — только память процесса.
Future<CustomerSelfLink?> customerSelfLink(Ref ref) async {
  ref.watch(sessionControllerProvider.select((s) => s.userId));
  if (ref.watch(catalog.catalogViewerRoleProvider) != RoleCode.customer) return null;
  final Result<UserProfile> r = await ref.watch(profileRepositoryProvider).me();
  final ProfileCustomerLink? link = r.valueOrNull?.customerLink;
  if (link == null) return null;
  final CustomerLinkStatus? status = CustomerLinkStatus.tryParse(link.status?.value);
  return CustomerSelfLink(status: status, customerId: link.isConfirmed ? link.customerId : null);
}

/// Статусы заказа «в работе» для карточки «Мои заказы» SCR-50 (UI-50-004): от отправки до отгрузки.
const Set<OrderStatus> customerActiveOrderStatuses = <OrderStatus>{
  OrderStatus.submitting,
  OrderStatus.pendingApproval,
  OrderStatus.awaitingPayment,
  OrderStatus.approved,
  OrderStatus.awaitingShipment,
};

/// «Мой кабинет» SCR-50: `GET /me` (`customerLink`: статус привязки, маскированное название, `customerId`), заказы в
/// работе (`GET /orders?status=…&limit=1` → `totalEstimate`, UI-50-004; свои — по `order.read.own`) и свой долг
/// (`GET /customers/{id}/receivables` — только при `confirmed`, UI-50-005; DEBT-009: нет данных — «Нет данных из
/// 1С», не «0 сом»). Ошибки заказов и долга не ломают сводку: соответствующие карточки — без чисел.
final class MeCustomerHomePort implements CustomerHomePort {
  MeCustomerHomePort(this._dio, {ReceivablesRepository Function()? receivables, OrdersRepository Function()? orders})
    : _receivables = receivables,
      _orders = orders;

  final Dio _dio;
  final ReceivablesRepository Function()? _receivables;
  final OrdersRepository Function()? _orders;

  @override
  Future<Result<CustomerHomeSummary>> summary() => ErrorMapper.guard<CustomerHomeSummary>(() async {
    final Response<Map<String, Object?>> res = await _dio.get<Map<String, Object?>>('/me', options: apiOptions());
    final CustomerHomeSummary base = summaryFromMe(res.data ?? const <String, Object?>{});
    return withOrdersAndDebt(base, receivables: _receivables, orders: _orders);
  });

  /// Дополнить сводку [base] заказами в работе и своим долгом (долг — только при `confirmed`).
  static Future<CustomerHomeSummary> withOrdersAndDebt(
    CustomerHomeSummary base, {
    ReceivablesRepository Function()? receivables,
    OrdersRepository Function()? orders,
  }) async {
    int? active;
    bool hasActive = false;
    if (orders != null) {
      try {
        final Result<OrdersPage> r = await orders().list(
          const OrdersQuery(statuses: customerActiveOrderStatuses, limit: 1),
        );
        final OrdersPage? page = r.valueOrNull;
        if (page != null) {
          hasActive = page.page.items.isNotEmpty;
          active = page.page.totalEstimate ?? (hasActive ? null : 0);
        }
      } on Object {
        // Порт не подключён / сбой — карточка без числа.
      }
    }
    Receivable? debt;
    final String? customerId = base.linked ? base.customerId : null;
    if (customerId != null && receivables != null) {
      try {
        debt = (await receivables().get(customerId)).valueOrNull;
      } on Object {
        debt = null;
      }
    }
    final Money? balance = debt?.balance;
    return CustomerHomeSummary(
      linkStatus: base.linkStatus,
      linkName: base.linkName,
      customerId: base.customerId,
      activeOrders: active,
      hasActiveOrders: hasActive,
      debt: balance,
      debtAsOf: balance == null ? null : debt?.asOf,
    );
  }

  /// Разбор `Me.customerLink` (08 §4.3; ПДн — только в памяти, в лог не пишутся).
  static CustomerHomeSummary summaryFromMe(Map<String, Object?> me) {
    final Object? link = me['customerLink'];
    if (link is! Map) {
      return const CustomerHomeSummary();
    }
    final CustomerLinkStatus? status = CustomerLinkStatus.tryParse(link['status'] as String?);
    return CustomerHomeSummary(
      linkStatus: status,
      // Единый presenter наименования (D PR-09): маска до `confirmed`, затем полное наименование.
      linkName: CustomerDisplayName.of(
        confirmed: status == CustomerLinkStatus.confirmed,
        displayName: link['displayName'] as String?,
        displayNameMasked: link['displayNameMasked'] as String?,
      ),
      customerId: status == CustomerLinkStatus.confirmed ? link['customerId'] as String? : null,
    );
  }
}

/// `CatalogShelfPort` (и `ProductFavoritePort` SCR-14) над фичей favorites и outbox core/sync (D-32):
/// звезда и «Очистить» — сразу локально + запись `favorite.add|remove` / `recent.clear`; список недавних — `GET /catalog/products/recent`.
final class FavoritesCatalogShelf implements CatalogShelfPort, product_details.ProductFavoritePort {
  FavoritesCatalogShelf(this._ref);

  final Ref _ref;

  @override
  Stream<Set<String>> watchFavoriteIds() => _ref.read(favoritesRepositoryProvider).watchCachedIds();

  @override
  Future<Result<void>> setFavorite(String productId, {required bool favorite}) =>
      _ref.read(offlineActionsProvider).setFavorite(productId, favorite: favorite);

  @override
  Future<Result<List<RecentProduct>>> recentProducts({int limit = 5}) =>
      _ref.read(recentProductsRepositoryProvider).list(limit: limit);

  @override
  Future<Result<void>> clearRecent() => _ref.read(offlineActionsProvider).clearRecent();
}
