// SCR-31 «Поиск клиентов» (02 SCR-31; RM-G-007): поле поиска с порогами по ролям (ядро §19.4), чипы «Все · Избранные ·
// С долгом · С просрочкой» по ролям, подпись типа совпадения, строки `CustomerCard.row` с индикатором долга без суммы,
// звезда избранного (cashier, senior_seller, admin), «+ Новый клиент» (SCR-26; номер из поиска — только память, N-3),
// подгрузка по курсору. expanded — мастер-деталь: список 400 слева, SCR-32 справа. Офлайн — «Поиск клиентов
// недоступен без сети» (кэша клиентов на устройстве нет).
import 'dart:async';

import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/category_chip.dart';
import 'package:optomstroy/design_system/components/customer_card.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/search_bar.dart';
import 'package:optomstroy/design_system/layout/window_class.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/presentation/customers_format.dart';
import 'package:optomstroy/features/customers/presentation/customers_ports.dart';
import 'package:optomstroy/features/customers/presentation/state/customer_favorites_controller.dart';
import 'package:optomstroy/features/customers/presentation/state/customers_search_controller.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_card_view.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_list_row.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_states.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customers_nav.dart';

/// Ключи (тесты).
abstract final class CustomersSearchKeys {
  static const Key field = ValueKey<String>('customers-search-field');
  static const Key match = ValueKey<String>('customers-search-match');
  static const Key hint = ValueKey<String>('customers-search-hint');
  static const Key empty = ValueKey<String>('customers-search-empty');
  static const Key error = ValueKey<String>('customers-search-error');
  static const Key newCustomer = ValueKey<String>('customers-search-new');
  static const Key detailEmpty = ValueKey<String>('customers-search-detail-empty');
  static Key filter(CustomersFilter f) => ValueKey<String>('customers-search-filter-${f.name}');
}

/// SCR-31. Поиск клиентов `/customers?q=&favorites=1&withDebt=1` (staff).
class CustomersSearchScreen extends ConsumerStatefulWidget {
  /// Экран SCR-31.
  const CustomersSearchScreen({this.q, this.favoritesOnly = false, this.withDebtOnly = false, super.key});

  /// ID экрана (02 §4.1).
  static const String screenId = 'SCR-31';

  /// Строка поиска (`?q=`; в `lastLocation` не сохраняется — navigation.md §14.5).
  final String? q;

  /// `?favorites=1`.
  final bool favoritesOnly;

  /// `?withDebt=1`.
  final bool withDebtOnly;

  @override
  ConsumerState<CustomersSearchScreen> createState() => _CustomersSearchScreenState();
}

class _CustomersSearchScreenState extends ConsumerState<CustomersSearchScreen> {
  late final TextEditingController _query = TextEditingController(text: widget.q ?? '');
  final FocusNode _focus = FocusNode(debugLabel: 'customers-search');
  final ScrollController _scroll = ScrollController();
  String? _selected;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    final CustomersFilter filter = widget.favoritesOnly
        ? CustomersFilter.favorites
        : (widget.withDebtOnly ? CustomersFilter.debt : CustomersFilter.all);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(customersSearchProvider.notifier).start(q: widget.q, filter: filter);
    });
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final ScrollPosition p = _scroll.position;
    if (p.pixels >= p.maxScrollExtent * .8) unawaited(ref.read(customersSearchProvider.notifier).loadMore());
  }

  bool get _wide {
    final WindowClass wc = context.windowClass;
    return wc == WindowClass.expanded || wc == WindowClass.large;
  }

  void _open(Customer c) {
    if (_wide) {
      if (_selected != c.id) setState(() => _selected = c.id);
      return;
    }
    CustomersNav.openCard(context, c.id);
  }

  Future<void> _newCustomer() async {
    ref.read(customerNewPrefillProvider).put(CustomersFormat.phoneQuery(_query.text));
    final String? id = await CustomersNav.newCustomer(context);
    if (!mounted) return;
    ref.read(customerNewPrefillProvider).put(null);
    if (id == null) return;
    unawaited(ref.read(customersSearchProvider.notifier).reload());
    if (_wide) {
      setState(() => _selected = id);
    } else {
      CustomersNav.openCard(context, id);
    }
  }

  Future<void> _favorite(Customer c, bool value) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final CustomersSearchController search = ref.read(customersSearchProvider.notifier);
    final CustomerFavoritesController fav = ref.read(customerFavoritesProvider.notifier);
    final CustomersSearchState s = ref.read(customersSearchProvider);
    final bool favoritesList =
        s.filter == CustomersFilter.favorites || (s.filter == CustomersFilter.all && !s.textSearch);
    final int index = s.items.indexWhere((Customer x) => x.id == c.id);
    if (!value && favoritesList) search.hide(c.id);
    final FavoriteOutcome outcome = await fav.set(c.id, value, server: c.isFavorite);
    if (!mounted) return;
    switch (outcome) {
      case FavoriteSaved(value: final bool saved) when saved == value:
        AppSnackbar.show(
          context,
          message: saved ? l10n.customer_card_favorite_added : l10n.customer_card_favorite_removed,
          actionLabel: l10n.ds_button_undo,
          onAction: () {
            if (!saved && favoritesList) search.restore(c, index);
            unawaited(fav.set(c.id, !saved, server: saved));
          },
        );
      case FavoriteSaved():
        break;
      case FavoriteFailed(:final failure):
        if (!value && favoritesList) search.restore(c, index);
        AppSnackbar.show(context, message: CustomerStates.message(l10n, failure), variant: AppSnackbarVariant.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final CustomersViewer viewer = ref.watch(customersViewerProvider);
    final bool online = ref.watch(customersOnlineProvider);
    final CustomersSearchState s = ref.watch(customersSearchProvider);
    final CustomersSearchController ctl = ref.read(customersSearchProvider.notifier);
    final bool wide = _wide;
    final Widget? newButton = viewer.canCreateCustomer
        ? AppButton(
            key: CustomersSearchKeys.newCustomer,
            label: l10n.customers_search_new,
            icon: Icons.person_add_alt_rounded,
            variant: AppButtonVariant.outlined,
            size: wide ? AppButtonSize.m : AppButtonSize.l,
            expand: !wide,
            onPressed: online ? () => unawaited(_newCustomer()) : null,
          )
        : null;
    final Widget list = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(context.space.s4, context.space.s3, context.space.s4, context.space.s2),
          child: SearchBar(
            key: CustomersSearchKeys.field,
            variant: SearchBarVariant.customers,
            controller: _query,
            focusNode: _focus,
            placeholder: l10n.customers_search_placeholder,
            semanticLabel: l10n.customers_search_placeholder,
            loading: s.phase == CustomersSearchPhase.loading,
            onChanged: ctl.setQuery,
            onSubmitted: (_) => unawaited(ctl.submit()),
          ),
        ),
        _Filters(state: s, viewer: viewer, onFilter: (CustomersFilter f) => unawaited(ctl.setFilter(f))),
        if (s.phase == CustomersSearchPhase.results && s.matchType != null)
          Padding(
            padding: EdgeInsets.fromLTRB(context.space.s4, 0, context.space.s4, context.space.s2),
            child: Text(
              CustomersTexts.match(l10n, s.matchType!, s.matchCount),
              key: CustomersSearchKeys.match,
              style: context.text.caption.copyWith(color: context.colors.textSecondary),
            ),
          ),
        Expanded(child: _body(context, l10n, s, ctl, viewer, wide)),
        if (newButton != null && !wide)
          Padding(
            padding: EdgeInsets.all(context.space.s4),
            child: SafeArea(top: false, child: newButton),
          ),
      ],
    );
    final Widget content = wide
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              SizedBox(width: context.windowClass == WindowClass.large ? 400 : 380, child: list),
              VerticalDivider(width: 1, color: context.colors.border),
              Expanded(
                child: _selected == null
                    ? EmptyState(
                        key: CustomersSearchKeys.detailEmpty,
                        variant: EmptyStateVariant.customers,
                        title: l10n.customers_search_detail_empty,
                      )
                    : CustomerCardView(
                        key: ValueKey<String>('detail-$_selected'),
                        customerId: _selected!,
                        inMaster: true,
                      ),
              ),
            ],
          )
        : list;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): _focus.requestFocus,
        if (viewer.canCreateCustomer && online)
          const SingleActivator(LogicalKeyboardKey.keyN, control: true): () => unawaited(_newCustomer()),
      },
      child: Scaffold(
        key: const ValueKey<String>('stub-SCR-31'),
        appBar: AppBar(
          title: Text(l10n.customers_search_title),
          actions: <Widget>[
            if (wide && newButton != null)
              Padding(
                padding: EdgeInsets.only(right: context.space.s4),
                child: newButton,
              ),
          ],
        ),
        body: content,
      ),
    );
  }

  Widget _body(
    BuildContext context,
    AppLocalizations l10n,
    CustomersSearchState s,
    CustomersSearchController ctl,
    CustomersViewer viewer,
    bool wide,
  ) {
    final DsColors c = context.colors;
    Widget hint(String text) => Padding(
      key: CustomersSearchKeys.hint,
      padding: EdgeInsets.all(context.space.s4),
      child: Text(text, style: context.text.body.copyWith(color: c.textSecondary)),
    );
    switch (s.phase) {
      case CustomersSearchPhase.idle:
        return hint(viewer.searchesByName ? l10n.customers_search_hint_idle : l10n.customers_search_seller_hint);
      case CustomersSearchPhase.sellerHint:
        return hint(l10n.customers_search_seller_hint);
      case CustomersSearchPhase.phoneFullHint:
        return hint(l10n.customers_search_phone_full_hint);
      case CustomersSearchPhase.offline:
        return CustomerStates.offline(l10n.customers_search_offline);
      case CustomersSearchPhase.loading:
        return ListView(
          children: <Widget>[for (int i = 0; i < 3; i++) const CustomerCard.row(name: '', loading: true)],
        );
      case CustomersSearchPhase.error:
        return Padding(
          padding: EdgeInsets.all(context.space.s4),
          child: Align(
            alignment: Alignment.topCenter,
            child: ErrorState.inline(
              key: CustomersSearchKeys.error,
              message: l10n.customers_search_error,
              onRetry: () => unawaited(ctl.retry()),
            ),
          ),
        );
      case CustomersSearchPhase.empty:
        if (!s.textSearch && s.filter == CustomersFilter.all) {
          return hint(l10n.customers_search_hint_idle);
        }
        return EmptyState(
          key: CustomersSearchKeys.empty,
          variant: EmptyStateVariant.customers,
          title: s.textSearch ? l10n.customers_search_empty(s.query.trim()) : l10n.ds_empty_search_title(''),
          actionLabel: viewer.canCreateCustomer && s.textSearch ? l10n.customers_search_new : null,
          onAction: viewer.canCreateCustomer ? () => unawaited(_newCustomer()) : null,
        );
      case CustomersSearchPhase.results:
        return ListView.builder(
          key: const PageStorageKey<String>('customers-search-list'),
          controller: _scroll,
          itemCount: s.items.length + (s.loadingMore || s.loadMoreFailed ? 1 : 0),
          itemBuilder: (BuildContext context, int i) {
            if (i >= s.items.length) {
              return s.loadMoreFailed
                  ? Padding(
                      padding: EdgeInsets.all(context.space.s4),
                      child: ErrorState.inline(
                        message: l10n.customers_search_error,
                        onRetry: () => unawaited(ctl.loadMore()),
                      ),
                    )
                  : const CustomerCard.row(name: '', loading: true);
            }
            final Customer item = s.items[i];
            return CustomerListRow(
              customer: item,
              selected: wide && item.id == _selected,
              onOpen: () => _open(item),
              onFavoriteChanged: (Customer c, bool v) => unawaited(_favorite(c, v)),
            );
          },
        );
    }
  }
}

class _Filters extends StatelessWidget {
  const _Filters({required this.state, required this.viewer, required this.onFilter});

  final CustomersSearchState state;
  final CustomersViewer viewer;
  final ValueChanged<CustomersFilter> onFilter;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final List<(CustomersFilter, String)> chips = <(CustomersFilter, String)>[
      (CustomersFilter.all, l10n.customers_search_filter_all),
      if (viewer.canManageFavorites) (CustomersFilter.favorites, l10n.customers_search_filter_favorites),
      if (viewer.canFilterDebt) ...<(CustomersFilter, String)>[
        (CustomersFilter.debt, l10n.customers_search_filter_debt),
        (CustomersFilter.overdue, l10n.customers_search_filter_overdue),
      ],
    ];
    if (chips.length < 2) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.fromLTRB(context.space.s4, 0, context.space.s4, context.space.s2),
      child: Row(
        children: <Widget>[
          for (final (CustomersFilter f, String label) in chips) ...<Widget>[
            CategoryChip(
              key: CustomersSearchKeys.filter(f),
              label: label,
              variant: CategoryChipVariant.filter,
              selected: state.filter == f,
              onTap: () => onFilter(f),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}
