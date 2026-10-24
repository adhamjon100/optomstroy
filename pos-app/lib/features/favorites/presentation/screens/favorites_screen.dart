// SCR-40 «Избранное» (02 SCR-40; RM-G-004, RM-G-007 — избранные клиенты; FAV-001…008). Вкладки «Товары · N» /
// «Клиенты · M» (вкладка клиентов — только `favorites.customers.manage`: cashier, senior_seller, admin; у остальных
// вкладок нет, `?tab=customers` открывает товары без ошибки — AC-UI-40-001). Счётчики — `count` ответов API.
// Снятие звезды — оптимистично, снекбар «… · Отменить» 8 с; ошибка онлайн — элемент возвращается, `favorites_remove_error`.
// Избранные клиенты — только онлайн (в `outbox_actions` не входят — основа G); сумм долга в строках нет (индикатор).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_tabs.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart' show catalogViewerRoleProvider;
import 'package:optomstroy/features/favorites/presentation/widgets/favorite_customers_tab.dart';
import 'package:optomstroy/features/favorites/presentation/widgets/favorite_products_tab.dart';

/// Вкладка SCR-40.
enum FavoritesTab { products, customers }

/// SCR-40. Избранное `/favorites?tab=products|customers` (staff; `customer` — товары).
class FavoritesScreen extends ConsumerStatefulWidget {
  /// Экран SCR-40.
  const FavoritesScreen({this.tab, super.key});

  /// ID экрана (02 §4.1).
  static const String screenId = 'SCR-40';

  /// `products|customers` (клиенты — cashier, senior_seller, admin).
  final String? tab;

  /// Право `favorites.customers.manage` (11 §4.4, FAV-006).
  static bool customersAllowed(RoleCode? role) =>
      role == RoleCode.cashier || role == RoleCode.seniorSeller || role == RoleCode.admin;

  @override
  ConsumerState<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends ConsumerState<FavoritesScreen> {
  late FavoritesTab _tab = widget.tab == 'customers' ? FavoritesTab.customers : FavoritesTab.products;
  int? _productsCount;
  int? _customersCount;

  @override
  void didUpdateWidget(FavoritesScreen old) {
    super.didUpdateWidget(old);
    if (old.tab != widget.tab) _tab = widget.tab == 'customers' ? FavoritesTab.customers : FavoritesTab.products;
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool customers = FavoritesScreen.customersAllowed(ref.watch(catalogViewerRoleProvider));
    final FavoritesTab tab = customers ? _tab : FavoritesTab.products;
    final Widget products = FavoriteProductsTab(onCount: (int n) => _setCount(products: n));
    final Widget body = !customers
        ? products
        : Column(
            children: <Widget>[
              AppTabs<FavoritesTab>(
                key: const ValueKey<String>('favorites-tabs'),
                value: tab,
                onChanged: (FavoritesTab t) => setState(() => _tab = t),
                tabs: <AppTab<FavoritesTab>>[
                  AppTab<FavoritesTab>(
                    key: const ValueKey<String>('favorites-tab-products'),
                    value: FavoritesTab.products,
                    label: _productsCount == null
                        ? l10n.favorites_title
                        : l10n.favorites_tab_products_count(_productsCount!),
                  ),
                  AppTab<FavoritesTab>(
                    key: const ValueKey<String>('favorites-tab-customers'),
                    value: FavoritesTab.customers,
                    label: _customersCount == null
                        ? l10n.cashier_favorites_title
                        : l10n.favorites_tab_customers_count(_customersCount!),
                  ),
                ],
              ),
              Expanded(
                child: IndexedStack(
                  index: tab.index,
                  children: <Widget>[
                    products,
                    FavoriteCustomersTab(onCount: (int n) => _setCount(customers: n)),
                  ],
                ),
              ),
            ],
          );
    return Scaffold(
      key: const ValueKey<String>('stub-SCR-40'),
      appBar: AppBar(title: Text(l10n.favorites_title)),
      body: body,
    );
  }

  void _setCount({int? products, int? customers}) {
    if (!mounted) return;
    if ((products == null || products == _productsCount) && (customers == null || customers == _customersCount)) return;
    setState(() {
      _productsCount = products ?? _productsCount;
      _customersCount = customers ?? _customersCount;
    });
  }
}
