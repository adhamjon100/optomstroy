// Интеграция этапа G (RM-G-009 Flutter-часть, RM-G-010): порты presentation фич cashier, transactions, returns,
// customers → сессия, флаги `GET /settings/public`, корзина, печать, список сотрудников (06 §6.1: фичи не импортируют
// друг друга сверх DAG — связь только здесь, в композиционном корне `app/di/overrides.dart`).
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/di/customer_orders_tab.dart';
import 'package:optomstroy/app/di/overrides.dart' show sessionUserIdProvider;
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/error_texts.dart';
import 'package:optomstroy/core/models/pos_common.dart' show UserRef;
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/layout/window_class.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/admin/admin_providers.dart';
import 'package:optomstroy/features/admin/domain/users/admin_user.dart';
import 'package:optomstroy/features/auth/auth_providers.dart' as auth;
import 'package:optomstroy/features/cart/cart_providers.dart' as cart;
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/cart/domain/sync/cart_sync.dart';
import 'package:optomstroy/features/cashier/cashier_providers.dart';
import 'package:optomstroy/features/cashier/presentation/providers/cashier_ports.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart' as catalog;
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_logo.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_logout.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart';
import 'package:optomstroy/features/orders/presentation/providers/orders_ports.dart' show OrderDocumentPrinter;
import 'package:optomstroy/features/returns/presentation/providers/returns_ports.dart';
import 'package:optomstroy/features/sync_status/presentation/widgets/sync_connected_widgets.dart';
import 'package:optomstroy/features/transactions/presentation/providers/transactions_ports.dart';
import 'package:uuid/uuid.dart';

/// Переопределения этапа G; [printer] — принтер документов заказа корня (`appOrderDocumentPrinterProvider`, точка
/// подмены integration_test).
List<Override> stageGOverrides(Provider<OrderDocumentPrinter?> printer) => <Override>[
  // RM-G-013 (Q-152, R1 — «нет»): «Принять оплату по долгу» SCR-32 и пункт меню — только при
  // `features.debtPaymentsFromPos=true` от сервера (до ответа — закрыто, fail-closed).
  customerDebtPaymentsEnabledProvider.overrideWith((Ref ref) => ref.watch(debtPaymentsFromPosProvider)),
  // UI-32-011 «В заказ»: `POST /cart/customer` (замена другого клиента — `ConfirmDialog`) → корзина.
  customerToCartActionProvider.overrideWith(customerToCartActionFor),
  // UI-32-007 «Заказы и операции»: `GET /orders?customerId=` и `GET /transactions?customerId=`.
  customerOrdersTabBuilderProvider.overrideWithValue(customerOrdersTab),
  // SCR-39: роль и пользователь сессии (без роли — только просмотр, fail-closed).
  returnsViewerProvider.overrideWith(
    (Ref ref) =>
        ReturnsViewer(role: ref.watch(catalog.catalogViewerRoleProvider), userId: ref.watch(sessionUserIdProvider)),
  ),
  // Роль экранов кассы и журнала — из профиля входа (как каталог); `syncViewerRoleProvider` — та же роль.
  cashierViewerRoleProvider.overrideWith((Ref ref) => ref.watch(catalog.catalogViewerRoleProvider)),
  // Шапка SCR-30 (UI-30-013): имя из профиля входа (ПДн — только память), логотип и `SyncIndicator` как у SCR-10,
  // «Выйти» — сценарий SCR-10 (ConfirmDialog, предупреждение о неотправленных изменениях FLOW-009.E1).
  cashierViewerNameProvider.overrideWith(
    (Ref ref) => ref.watch(auth.authSessionProvider.select((s) => s.profile.displayName)),
  ),
  cashierLogoProvider.overrideWithValue((BuildContext context) => const CatalogLogo(markSize: 28, wordmark: false)),
  cashierSyncIndicatorProvider.overrideWithValue((BuildContext context) => const ConnectedSyncIndicator()),
  cashierLogoutProvider.overrideWithValue((BuildContext context, WidgetRef ref) async {
    await confirmCatalogLogout(context, ref);
  }),
  transactionsViewerRoleProvider.overrideWith((Ref ref) => ref.watch(catalog.catalogViewerRoleProvider)),
  // Печать товарного чека SCR-38 (UI-38-006) и «Печать» SCR-37 — тот же принтер, что у SCR-24 (пакет `printing`).
  cashierReceiptPrinterProvider.overrideWith((Ref ref) {
    final OrderDocumentPrinter? p = ref.watch(printer);
    return p?.print;
  }),
  transactionsDocumentPrinterProvider.overrideWith((Ref ref) {
    final OrderDocumentPrinter? p = ref.watch(printer);
    return p?.print;
  }),
  // Фильтр «Сотрудник» SCR-36 (`admin`/`owner`): сотрудники из `GET /admin/users` (фича admin; GQ-FECASH-07).
  transactionsActorsProvider.overrideWith(transactionsActorsFor),
];

/// «В заказ» для роли сессии: `seller`, `cashier`, `senior_seller`, `admin` (02 SCR-32 UI-32-011); прочим — нет.
CustomerToCartAction? customerToCartActionFor(Ref ref) {
  final RoleCode? role = ref.watch(catalog.catalogViewerRoleProvider);
  const Set<RoleCode> allowed = <RoleCode>{RoleCode.seller, RoleCode.cashier, RoleCode.seniorSeller, RoleCode.admin};
  if (!allowed.contains(role)) return null;
  return (BuildContext context, String customerId) => assignCustomerToCart(
    context,
    customerId,
    sync: ref.read(cart.cartSyncProvider),
    repository: ref.read(cart.cartRepositoryProvider),
  );
}

/// Назначить клиента [customerId] активной корзине и открыть её (compact — SCR-20, иначе SCR-10 с панелью корзины).
/// В корзине другой клиент — `ConfirmDialog` «Заменить клиента в корзине?» (отказ — без запроса).
Future<void> assignCustomerToCart(
  BuildContext context,
  String customerId, {
  required CartSync sync,
  required CartRepository repository,
  String Function()? keyFactory,
}) async {
  final AppLocalizations l10n = AppLocalizations.of(context);
  void fail(Failure f) {
    if (!context.mounted) return;
    AppSnackbar.show(
      context,
      message: ErrorTexts.message(l10n, UiErrorMapper.fromFailure(f)),
      variant: AppSnackbarVariant.error,
    );
  }

  final Result<Cart> current = await sync.refresh();
  if (!context.mounted) return;
  final Cart? c = current.valueOrNull;
  if (c == null) return fail(current.failureOrNull ?? const UnknownFailure());
  final Customer? existing = c.customer;
  if (existing?.id != customerId) {
    if (existing != null) {
      final bool replace = await ConfirmDialog.show(
        context,
        title: l10n.customer_card_replace_title,
        message: l10n.customer_card_replace_body(existing.title),
        confirmLabel: l10n.customer_card_replace_cta,
      );
      if (!replace || !context.mounted) return;
    }
    final String key = (keyFactory ?? const Uuid().v4)();
    final Result<Cart> r = await sync.direct<Cart>(
      (int rowVersion) => repository.setCustomer(customerId, rowVersion: rowVersion, idempotencyKey: key),
      cartOf: (Cart cart) => cart,
    );
    if (!context.mounted) return;
    final Failure? f = r.failureOrNull;
    if (f != null) return fail(f);
  }
  GoRouter.of(context).go(context.windowClass == WindowClass.compact ? '/cart' : '/catalog');
}

/// Сотрудники для фильтра SCR-36: только `admin`/`owner` (`user.read`), иначе — нет источника.
TransactionsActorsSource? transactionsActorsFor(Ref ref) {
  final RoleCode? role = ref.watch(catalog.catalogViewerRoleProvider);
  if (role != RoleCode.admin && role != RoleCode.owner) return null;
  return () async {
    final Result<AdminPage<AdminUser>> r = await ref
        .read(adminUsersRepositoryProvider)
        .listUsers(const AdminUsersQuery(limit: 200));
    return switch (r) {
      Success<AdminPage<AdminUser>>(:final AdminPage<AdminUser> value) => Success<List<UserRef>>(<UserRef>[
        for (final AdminUser u in value.items)
          if (u.kind == 'staff')
            UserRef(
              id: u.id,
              displayName: (u.fullName?.isNotEmpty ?? false) ? u.fullName! : (u.phone ?? u.id),
              role: u.roles.isEmpty ? null : RoleCode.tryParse(u.roles.first),
            ),
      ]),
      FailureResult<AdminPage<AdminUser>>(:final Failure failure) => FailureResult<List<UserRef>>(failure),
    };
  };
}
