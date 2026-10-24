// Строка клиента списков SCR-31 / SCR-40 (02 UI-31-003, UI-31-004, UI-31-006, UI-40-003): `CustomerCard.row` +
// `ReceivableBadge.compact` («Есть долг» / «Просрочка» без суммы — для всех ролей, ядро §22.13 п.1) + `FavoriteToggle`
// (только `favorites.customers.manage`). Телефон — полный у ролей с правом, иначе маска с сервера. Долгое нажатие /
// правый клик — меню «Открыть», «Скопировать телефон» (роли с полным номером), «В избранное / Убрать».
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_list_tile.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/customer_card.dart';
import 'package:optomstroy/design_system/components/favorite_toggle.dart';
import 'package:optomstroy/design_system/components/receivable_badge.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/presentation/customers_format.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart';
import 'package:optomstroy/features/customers/presentation/state/customer_favorites_controller.dart';

/// Ключи (тесты).
abstract final class CustomerRowKeys {
  static Key row(String id) => ValueKey<String>('customer-row-$id');
  static Key star(String id) => ValueKey<String>('customer-row-star-$id');
  static Key debt(String id) => ValueKey<String>('customer-row-debt-$id');
}

/// Строка клиента.
class CustomerListRow extends ConsumerWidget {
  /// Создаёт строку.
  const CustomerListRow({
    super.key,
    required this.customer,
    required this.onOpen,
    this.selected = false,
    this.onFavoriteChanged,
  });

  final Customer customer;
  final VoidCallback onOpen;
  final bool selected;

  /// Звезда переключена (оптимистично) — экран решает, скрыть ли строку и какой показать снекбар.
  final void Function(Customer customer, bool value)? onFavoriteChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final CustomersViewer viewer = ref.watch(customersViewerProvider);
    final bool online = ref.watch(customersOnlineProvider);
    final Customer c = customer;
    final bool favorite =
        ref.watch(customerFavoritesProvider.select((Map<String, bool> m) => m[c.id])) ?? c.isFavorite ?? false;
    final Widget? debt = c.isOverdue == true
        ? ReceivableBadge.compact(
            key: CustomerRowKeys.debt(c.id),
            overdue: true,
            label: l10n.customers_search_overdue_flag,
            tooltip: l10n.ds_receivable_details_hint,
          )
        : (c.hasDebt == true
              ? ReceivableBadge.compact(
                  key: CustomerRowKeys.debt(c.id),
                  overdue: false,
                  label: l10n.customers_search_has_debt,
                  tooltip: l10n.ds_receivable_details_hint,
                )
              : null);
    final bool star = viewer.canManageFavorites;
    final Widget? trailing = debt == null && !star
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ?debt,
              if (star)
                FavoriteToggle(
                  key: CustomerRowKeys.star(c.id),
                  selected: favorite,
                  semanticLabel: favorite ? l10n.ds_favorite_on_a11y : l10n.ds_favorite_add_a11y,
                  onChanged: online ? (bool v) => onFavoriteChanged?.call(c, v) : null,
                ),
            ],
          );
    return CustomerCard.row(
      key: CustomerRowKeys.row(c.id),
      name: c.title,
      phone: CustomersFormat.customerPhone(c),
      meta: CustomersTexts.code(l10n, c),
      pendingLabel: CustomersTexts.pendingOnec(c) ? l10n.customers_search_pending_onec : null,
      priceListLabel: c.priceList?.name,
      rowHeight: CustomerCard.rowHeightFor(context.windowClass),
      selected: selected,
      trailing: trailing,
      onTap: onOpen,
      onLongPress: () => unawaited(_menu(context, l10n, viewer, online, favorite)),
    );
  }

  Future<void> _menu(BuildContext context, AppLocalizations l10n, CustomersViewer viewer, bool online, bool favorite) {
    final Customer c = customer;
    final String? phone = c.phones.isEmpty ? null : c.phones.first.valueE164;
    return AppBottomSheet.show<void>(
      context,
      title: c.title,
      body: Builder(
        builder: (BuildContext sheet) => Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AppListTile(
              leadingIcon: Icons.open_in_new_rounded,
              title: l10n.ds_button_open,
              onTap: () {
                Navigator.of(sheet).pop();
                onOpen();
              },
            ),
            if (phone != null)
              AppListTile(
                leadingIcon: Icons.copy_rounded,
                title: l10n.ds_copy_phone,
                onTap: () {
                  Navigator.of(sheet).pop();
                  unawaited(Clipboard.setData(ClipboardData(text: phone)));
                  AppSnackbar.show(context, message: l10n.ds_copied);
                },
              ),
            if (viewer.canManageFavorites && online)
              AppListTile(
                leadingIcon: favorite ? Icons.star_rounded : Icons.star_outline_rounded,
                title: favorite ? l10n.favorites_star_remove_tooltip : l10n.ds_favorite_add_a11y,
                onTap: () {
                  Navigator.of(sheet).pop();
                  onFavoriteChanged?.call(c, !favorite);
                },
              ),
          ],
        ),
      ),
    );
  }
}
