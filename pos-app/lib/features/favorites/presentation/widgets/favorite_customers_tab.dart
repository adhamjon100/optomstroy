// SCR-40 вкладка «Клиенты» (02 UI-40-003, UI-40-004, UI-40-006, UI-40-008; 08 §4.14 `GET/PUT/DELETE
// /favorites/customers`; FAV-006). Строка — `CustomerCard.row` + `ReceivableBadge.compact` (без сумм) + звезда; тап →
// SCR-32 (`go` в ветку Клиенты). Фильтр — локально по имени/телефону (≤ 100 символов, debounce 300 мс); если загружены
// не все страницы — догрузка (≤ 200, 08 §4.13.1). Снятие звезды — оптимистично + «Отменить» 8 с; ошибка — возврат и
// `favorites_remove_error`. Только онлайн; данные — память виджета.
import 'dart:async';

import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart' show OnlineStatus;
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/customer_card.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/favorite_toggle.dart';
import 'package:optomstroy/design_system/components/receivable_badge.dart';
import 'package:optomstroy/design_system/components/search_bar.dart';
import 'package:optomstroy/design_system/formats/ds_phone_format.dart';
import 'package:optomstroy/design_system/layout/window_class.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/customers/customers_providers.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/repositories/favorite_customers_repository.dart';
import 'package:uuid/uuid.dart';

/// Ключи (тесты).
abstract final class FavoriteCustomersKeys {
  static const Key filter = ValueKey<String>('favorites-customers-filter');
  static const Key empty = ValueKey<String>('favorites-customers-empty');
  static Key row(String id) => ValueKey<String>('favorites-customer-$id');
  static Key star(String id) => ValueKey<String>('favorites-customer-star-$id');
}

/// Вкладка «Клиенты».
class FavoriteCustomersTab extends ConsumerStatefulWidget {
  /// Создаёт вкладку.
  const FavoriteCustomersTab({this.onCount, super.key});

  /// Счётчик вкладки (`count` ответа).
  final ValueChanged<int>? onCount;

  @override
  ConsumerState<FavoriteCustomersTab> createState() => _FavoriteCustomersTabState();
}

enum _Phase { loading, ready, error, offline }

class _FavoriteCustomersTabState extends ConsumerState<FavoriteCustomersTab> {
  static const int _pageSize = 50;
  static const int _filterLimit = 200;

  final TextEditingController _filter = TextEditingController();
  Timer? _debounce;
  String _query = '';
  _Phase _phase = _Phase.loading;
  Failure? _failure;
  List<Customer> _items = const <Customer>[];
  String? _cursor;
  int _count = 0;
  int _gen = 0;

  Timer? _firstStatus;

  @override
  void initState() {
    super.initState();
    // Статус сети ещё неизвестен (первое значение потока) — загрузка после него (не дольше 1 с).
    if (ref.read(onlineStatusProvider).hasValue) {
      unawaited(_load());
    } else {
      _firstStatus = Timer(const Duration(seconds: 1), () => unawaited(_load()));
    }
  }

  /// Смена сети: первое значение — загрузка; сеть вернулась — перезагрузка из состояния «офлайн».
  void _onStatus(AsyncValue<OnlineStatus>? prev, AsyncValue<OnlineStatus> next) {
    if (!next.hasValue) return;
    if (_firstStatus != null) {
      _firstStatus!.cancel();
      _firstStatus = null;
      unawaited(_load());
      return;
    }
    if (next.value != OnlineStatus.offline && _phase == _Phase.offline) unawaited(_load());
  }

  @override
  void dispose() {
    _firstStatus?.cancel();
    _debounce?.cancel();
    _filter.dispose();
    super.dispose();
  }

  bool get _online => ref.read(onlineStatusProvider).value != OnlineStatus.offline;

  Future<Result<FavoriteCustomersPage>> _page(String? cursor) async {
    try {
      return await ref.read(favoriteCustomersRepositoryProvider).list(limit: _pageSize, cursor: cursor);
    } on Object catch (e) {
      return FailureResult<FavoriteCustomersPage>(UnknownFailure(cause: e));
    }
  }

  Future<void> _load() async {
    final int gen = ++_gen;
    if (!_online) {
      setState(() => _phase = _Phase.offline);
      return;
    }
    setState(() => _phase = _Phase.loading);
    final Result<FavoriteCustomersPage> r = await _page(null);
    if (!mounted || gen != _gen) return;
    switch (r) {
      case Success<FavoriteCustomersPage>(:final FavoriteCustomersPage value):
        setState(() {
          _items = value.page.items;
          _cursor = value.page.hasMore ? value.page.nextCursor : null;
          _count = value.count;
          _phase = _Phase.ready;
        });
        widget.onCount?.call(value.count);
      case FailureResult<FavoriteCustomersPage>(:final Failure failure):
        setState(() {
          _failure = failure;
          _phase = failure is NetworkFailure && failure.kind == NetworkFailureKind.offline
              ? _Phase.offline
              : _Phase.error;
        });
    }
  }

  /// Догрузить страницы перед фильтрацией (≤ 200).
  Future<void> _loadAll() async {
    while (_cursor != null && _items.length < _filterLimit && mounted) {
      final int gen = _gen;
      final Result<FavoriteCustomersPage> r = await _page(_cursor);
      if (!mounted || gen != _gen) return;
      if (r case Success<FavoriteCustomersPage>(:final FavoriteCustomersPage value)) {
        final Set<String> seen = <String>{for (final Customer c in _items) c.id};
        setState(() {
          _items = <Customer>[
            ..._items,
            for (final Customer c in value.page.items)
              if (seen.add(c.id)) c,
          ];
          _cursor = value.page.hasMore ? value.page.nextCursor : null;
        });
      } else {
        return;
      }
    }
  }

  void _onFilter(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _query = v.trim().toLowerCase());
      if (_query.isNotEmpty) unawaited(_loadAll());
    });
  }

  List<Customer> get _visible {
    if (_query.isEmpty) return _items;
    final String digits = _query.replaceAll(RegExp(r'\D'), '');
    return <Customer>[
      for (final Customer c in _items)
        if (c.title.toLowerCase().contains(_query) ||
            (digits.isNotEmpty &&
                <String>[
                  for (final CustomerPhone p in c.phones) p.valueE164,
                  ?c.phoneMasked,
                ].any((String p) => p.replaceAll(RegExp(r'\D'), '').contains(digits))))
          c,
    ];
  }

  Future<void> _remove(Customer c) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final int index = _items.indexWhere((Customer x) => x.id == c.id);
    setState(() {
      _items = <Customer>[
        for (final Customer x in _items)
          if (x.id != c.id) x,
      ];
      _count = _count > 0 ? _count - 1 : 0;
    });
    widget.onCount?.call(_count);
    AppSnackbar.show(
      context,
      message: l10n.favorites_customer_removed_snackbar,
      actionLabel: l10n.ds_button_undo,
      onAction: () => unawaited(_undo(c, index)),
    );
    final Result<void> r = await ref.read(favoriteCustomersRepositoryProvider).remove(c.id);
    if (!mounted) return;
    if (r is FailureResult<void>) {
      _restore(c, index);
      AppSnackbar.show(context, message: l10n.favorites_remove_error, variant: AppSnackbarVariant.error);
    }
  }

  void _restore(Customer c, int index) {
    if (_items.any((Customer x) => x.id == c.id)) return;
    setState(() {
      final List<Customer> next = <Customer>[..._items]..insert(index.clamp(0, _items.length), c);
      _items = next;
      _count++;
    });
    widget.onCount?.call(_count);
  }

  Future<void> _undo(Customer c, int index) async {
    _restore(c, index);
    final Result<void> r = await ref
        .read(favoriteCustomersRepositoryProvider)
        .add(c.id, idempotencyKey: const Uuid().v4());
    if (!mounted) return;
    if (r is FailureResult<void>) {
      setState(() {
        _items = <Customer>[
          for (final Customer x in _items)
            if (x.id != c.id) x,
        ];
        _count = _count > 0 ? _count - 1 : 0;
      });
      widget.onCount?.call(_count);
      AppSnackbar.show(
        context,
        message: AppLocalizations.of(context).catalog_favorite_error,
        variant: AppSnackbarVariant.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<OnlineStatus>>(onlineStatusProvider, _onStatus);
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool online = ref.watch(onlineStatusProvider).value != OnlineStatus.offline;
    switch (_phase) {
      case _Phase.loading:
        return ListView(
          children: <Widget>[for (int i = 0; i < 4; i++) const CustomerCard.row(name: '', loading: true)],
        );
      case _Phase.offline:
        return EmptyState(variant: EmptyStateVariant.offlineNoCache, title: l10n.customers_search_offline);
      case _Phase.error:
        return ErrorState.fullScreen(
          title: l10n.error_internal,
          message: l10n.customers_search_error,
          requestId: _failure?.requestId,
          onRetry: () => unawaited(_load()),
        );
      case _Phase.ready:
        break;
    }
    if (_items.isEmpty && _query.isEmpty) {
      return EmptyState(
        key: FavoriteCustomersKeys.empty,
        variant: EmptyStateVariant.customers,
        title: l10n.favorites_empty_customers_title,
        body: l10n.favorites_empty_customers_body,
        actionLabel: l10n.favorites_empty_customers_action,
        onAction: () => GoRouter.maybeOf(context)?.go('/customers'),
      );
    }
    final List<Customer> shown = _visible;
    final WindowClass wc = context.windowClass;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.all(context.space.s4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: wc == WindowClass.compact ? double.infinity : 360, // money-double: allow — ширина поля (lp)
              child: SearchBar(
                key: FavoriteCustomersKeys.filter,
                variant: SearchBarVariant.customers,
                controller: _filter,
                placeholder: l10n.favorites_filter_customers_hint,
                semanticLabel: l10n.favorites_filter_customers_hint,
                onChanged: _onFilter,
              ),
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: shown.isEmpty
                ? ListView(
                    children: <Widget>[
                      EmptyState(
                        variant: EmptyStateVariant.search,
                        title: l10n.ds_empty_search_title(_filter.text.trim()),
                      ),
                    ],
                  )
                : ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (BuildContext context, int i) => _row(context, l10n, shown[i], online),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, AppLocalizations l10n, Customer c, bool online) {
    final Widget? debt = c.isOverdue == true
        ? ReceivableBadge.compact(overdue: true, label: l10n.customers_search_overdue_flag)
        : (c.hasDebt == true ? ReceivableBadge.compact(overdue: false, label: l10n.customers_search_has_debt) : null);
    final String? phone = c.phones.isNotEmpty ? DsPhoneFormat.display(c.phones.first.valueE164) : c.phoneMasked;
    return CustomerCard.row(
      key: FavoriteCustomersKeys.row(c.id),
      name: c.title,
      phone: phone,
      rowHeight: CustomerCard.rowHeightFor(context.windowClass),
      pendingLabel: c.onecStatus == CustomerOnecStatus.pending ? l10n.customers_search_pending_onec : null,
      onTap: () => GoRouter.maybeOf(context)?.go('/customers/${Uri.encodeComponent(c.id)}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ?debt,
          Tooltip(
            message: l10n.favorites_star_remove_tooltip,
            child: FavoriteToggle(
              key: FavoriteCustomersKeys.star(c.id),
              selected: true,
              semanticLabel: l10n.favorites_star_remove_tooltip,
              onChanged: online ? (bool _) => unawaited(_remove(c)) : null,
            ),
          ),
        ],
      ),
    );
  }
}
