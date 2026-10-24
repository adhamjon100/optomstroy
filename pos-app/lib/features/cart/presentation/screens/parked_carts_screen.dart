// SCR-23 «Отложенные заказы» (`/cart/parked`; роли seller, cashier, senior_seller, admin; owner — просмотр всех по 02 —
// guard пока закрывает owner по navigation.md §14.7, FQ-FND-04). Владелец реализации — агент F-fe-cart (RM-F-005,
// RM-F-013). compact — экран ветки `cart`; medium/expanded — side sheet 400 поверх корзины ([ParkedCartsBody] в
// `AppBottomSheet.showSide`).
//
// Карточка: название, клиент, «{count} позиций · {total} (предварительно)», автор (вкладка «Все»), срок хранения,
// метка «Восстановлен из заказа № …» (→ SCR-24); «Продолжить» (`resume`, при непустой активной — UI-23-010) и
// «Удалить» (UI-23-013; своя — `cart.manage.own`, чужая — `cart.parked.resume.any`, ядро §19.2).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/error_texts.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/app_tabs.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/cart/presentation/cart_formats.dart';
import 'package:optomstroy/features/cart/presentation/providers/cart_controller.dart';
import 'package:optomstroy/features/cart/presentation/providers/parked_carts_controller.dart';

/// Ключи SCR-23 (тесты).
abstract final class ParkedKeys {
  static const Key tabs = ValueKey<String>('parked-tabs');
  static const Key ownerNote = ValueKey<String>('parked-owner-note');

  static Key card(String id) => ValueKey<String>('parked-card-$id');

  static Key resume(String id) => ValueKey<String>('parked-resume-$id');

  static Key delete(String id) => ValueKey<String>('parked-delete-$id');

  static Key restored(String id) => ValueKey<String>('parked-restored-$id');
}

/// SCR-23.
class ParkedCartsScreen extends StatelessWidget {
  /// Экран SCR-23.
  const ParkedCartsScreen({super.key});

  /// Ключ экрана (тесты маршрутов): `stub-SCR-23`.
  static const ValueKey<String> stubKey = ValueKey<String>('stub-SCR-23');

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Scaffold(
      key: stubKey,
      backgroundColor: context.colors.surface,
      appBar: AppBar(
        title: Text(l10n.parked_title),
        backgroundColor: context.colors.surface,
        foregroundColor: context.colors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: const SafeArea(top: false, child: ParkedCartsBody()),
    );
  }
}

/// Содержимое SCR-23 (экран compact и side sheet 400 на medium/expanded).
class ParkedCartsBody extends ConsumerStatefulWidget {
  /// Создаёт список; [asSheet] — внутри side sheet (свой заголовок и закрытие).
  const ParkedCartsBody({super.key, this.asSheet = false});

  final bool asSheet;

  @override
  ConsumerState<ParkedCartsBody> createState() => _ParkedCartsBodyState();
}

class _ParkedCartsBodyState extends ConsumerState<ParkedCartsBody> {
  final ScrollController _scroll = ScrollController();
  int? _selected;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 200) {
        unawaited(ref.read(parkedCartsProvider.notifier).loadMore());
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  ParkedCartsController get _ctl => ref.read(parkedCartsProvider.notifier);

  void _snack(String message, {AppSnackbarVariant variant = AppSnackbarVariant.info}) {
    if (mounted) AppSnackbar.show(context, message: message, variant: variant);
  }

  bool _isOwn(CartParkedSummary c, ParkedScope scope) {
    if (scope == ParkedScope.own) return true;
    final String? me = ref.read(cartViewerUserIdProvider);
    final String? owner = c.ownerId ?? c.owner?.id;
    return me != null && owner == me;
  }

  bool _canDelete(CartParkedSummary c, ParkedScope scope, CartPermissions can) =>
      !can.readOnlyParked && (_isOwn(c, scope) || can.canResumeAny);

  bool _canResume(CartParkedSummary c, ParkedScope scope, CartPermissions can) =>
      !can.readOnlyParked && !can.customer && (_isOwn(c, scope) || can.canResumeAny);

  Future<void> _resume(CartParkedSummary c, ParkedScope scope) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    ParkedResumeOutcome outcome = await _ctl.resume(c);
    if (!mounted) return;
    if (outcome == ParkedResumeOutcome.activeNotEmpty) {
      final int count = ref.read(cartControllerProvider).lines.length;
      final bool replace = await ConfirmDialog.show(
        context,
        title: l10n.parked_resume,
        message: l10n.parked_active_not_empty_body(count),
        confirmLabel: l10n.parked_active_not_empty_confirm,
      );
      if (!replace || !mounted) return;
      outcome = await _ctl.resume(c, replaceActive: true);
      if (!mounted) return;
    }
    switch (outcome) {
      case ParkedResumeOutcome.resumed:
        if (!_isOwn(c, scope)) {
          _snack(l10n.parked_resumed_foreign_snackbar(c.name ?? '', c.owner?.displayName ?? ''));
        }
        ref.invalidate(cartParkedCountProvider);
        if (widget.asSheet) {
          unawaited(Navigator.of(context).maybePop());
        } else {
          GoRouter.of(context).go(CartPaths.cart);
        }
      case ParkedResumeOutcome.notAvailable:
        _snack(l10n.parked_not_available);
      case ParkedResumeOutcome.failed:
        final Failure? f = ref.read(parkedCartsProvider).lastFailure;
        if (f != null) {
          _snack(ErrorTexts.message(l10n, UiErrorMapper.fromFailure(f)), variant: AppSnackbarVariant.error);
        }
      case ParkedResumeOutcome.activeNotEmpty || ParkedResumeOutcome.ignored:
        break;
    }
  }

  Future<void> _delete(CartParkedSummary c, ParkedScope scope) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String body = l10n.parked_delete_dialog_body(c.itemsCount ?? 0, c.name ?? '');
    final bool foreign = !_isOwn(c, scope) && c.owner != null;
    final bool ok = await ConfirmDialog.show(
      context,
      title: l10n.parked_delete_dialog_title,
      message: foreign ? '$body\n${l10n.parked_delete_dialog_author(c.owner!.displayName)}' : body,
      confirmLabel: l10n.parked_delete_dialog_confirm,
      variant: ConfirmDialogVariant.destructive,
    );
    if (!ok || !mounted) return;
    final ParkedDeleteOutcome outcome = await _ctl.delete(c);
    if (!mounted) return;
    switch (outcome) {
      case ParkedDeleteOutcome.deleted:
        _snack(l10n.parked_deleted_snackbar);
      case ParkedDeleteOutcome.notAvailable:
        _snack(l10n.parked_not_available);
      case ParkedDeleteOutcome.conflict:
        _snack(l10n.parked_delete_conflict);
      case ParkedDeleteOutcome.failed:
        final Failure? f = ref.read(parkedCartsProvider).lastFailure;
        if (f != null) {
          _snack(ErrorTexts.message(l10n, UiErrorMapper.fromFailure(f)), variant: AppSnackbarVariant.error);
        }
      case ParkedDeleteOutcome.ignored:
        break;
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e, ParkedCartsState s, CartPermissions can) {
    if (e is! KeyDownEvent || s.items.isEmpty) return KeyEventResult.ignored;
    final int current = (_selected ?? -1).clamp(-1, s.items.length - 1);
    final LogicalKeyboardKey k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.arrowUp) {
      final int next = (k == LogicalKeyboardKey.arrowDown ? current + 1 : current - 1).clamp(0, s.items.length - 1);
      setState(() => _selected = next);
      return KeyEventResult.handled;
    }
    if (current < 0) return KeyEventResult.ignored;
    final CartParkedSummary c = s.items[current];
    if (k == LogicalKeyboardKey.enter && _canResume(c, s.scope, can)) {
      unawaited(_resume(c, s.scope));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.delete && _canDelete(c, s.scope, can)) {
      unawaited(_delete(c, s.scope));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final ParkedCartsState s = ref.watch(parkedCartsProvider);
    final CartPermissions can = cartPermissionsFor(ref.watch(cartViewerRoleProvider));
    final OnlineStatus net = ref.watch(cartOnlineStatusProvider);
    final bool offline = net == OnlineStatus.offline || net == OnlineStatus.serverDown;
    final DateTime now = ref.watch(clockProvider).nowUtc();

    final Widget list;
    if (s.loading) {
      list = ListView(
        padding: EdgeInsets.all(context.space.s4),
        children: <Widget>[
          for (int i = 0; i < 3; i++)
            Padding(
              padding: EdgeInsets.only(bottom: context.space.s3),
              child: const SkeletonBox(height: 72),
            ),
        ],
      );
    } else if (s.failure != null && s.items.isEmpty) {
      list = Center(
        child: ErrorState.inline(
          message: ErrorTexts.message(l10n, UiErrorMapper.fromFailure(s.failure!)),
          onRetry: () => unawaited(_ctl.reload()),
        ),
      );
    } else if (s.items.isEmpty) {
      list = Center(
        child: SingleChildScrollView(
          child: EmptyState(
            variant: EmptyStateVariant.parked,
            title: l10n.parked_empty_title,
            body: l10n.parked_empty_body,
            actionLabel: can.readOnlyParked ? null : l10n.parked_empty_back_to_cart,
            onAction: can.readOnlyParked
                ? null
                : () {
                    if (widget.asSheet) {
                      unawaited(Navigator.of(context).maybePop());
                    } else {
                      GoRouter.of(context).go(CartPaths.cart);
                    }
                  },
          ),
        ),
      );
    } else {
      list = RefreshIndicator(
        onRefresh: _ctl.reload,
        child: ListView.builder(
          controller: _scroll,
          itemCount: s.items.length + (s.loadingMore ? 1 : 0),
          itemBuilder: (BuildContext context, int i) {
            if (i >= s.items.length) {
              return Padding(padding: EdgeInsets.all(context.space.s4), child: const SkeletonBox(height: 72));
            }
            return _card(l10n, c, s.items[i], s, can, offline: offline, now: now, selected: _selected == i);
          },
        ),
      );
    }

    return Focus(
      autofocus: true,
      onKeyEvent: (FocusNode node, KeyEvent e) => _onKey(node, e, s, can),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (widget.asSheet)
            Padding(
              padding: EdgeInsetsDirectional.only(start: context.space.s5, end: context.space.s2),
              child: SizedBox(
                height: 56,
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        l10n.parked_title,
                        style: context.text.title.copyWith(fontWeight: FontWeight.w600, color: c.textPrimary),
                      ),
                    ),
                    AppIconButton(
                      icon: Icons.close_rounded,
                      semanticLabel: l10n.ds_button_close,
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ),
            ),
          if (can.canSeeAllParked && !can.readOnlyParked)
            // UI-23-002 / AC-UI-23-013: `AppTabs` `fixed`, 2 вкладки, высота 48 (03 §9.49).
            AppTabs<ParkedScope>(
              key: ParkedKeys.tabs,
              value: s.scope,
              tabs: <AppTab<ParkedScope>>[
                AppTab<ParkedScope>(
                  key: ValueKey<String>('parked-tab-${ParkedScope.own.value}'),
                  value: ParkedScope.own,
                  label: l10n.parked_scope_mine,
                ),
                AppTab<ParkedScope>(
                  key: ValueKey<String>('parked-tab-${ParkedScope.all.value}'),
                  value: ParkedScope.all,
                  label: l10n.parked_scope_all,
                ),
              ],
              onChanged: (ParkedScope scope) {
                setState(() => _selected = null);
                // AC-UI-23-013: новая вкладка — первая страница и прокрутка с начала.
                if (_scroll.hasClients) _scroll.jumpTo(0);
                unawaited(_ctl.load(scope));
              },
            ),
          if (can.readOnlyParked)
            Container(
              key: ParkedKeys.ownerNote,
              color: c.infoContainer,
              padding: EdgeInsets.all(context.space.s3),
              child: Text(l10n.parked_owner_readonly, style: context.text.body.copyWith(color: c.textPrimary)),
            ),
          Expanded(child: list),
        ],
      ),
    );
  }

  Widget _card(
    AppLocalizations l10n,
    DsColors c,
    CartParkedSummary p,
    ParkedCartsState s,
    CartPermissions can, {
    required bool offline,
    required DateTime now,
    required bool selected,
  }) {
    final bool resuming = s.resuming == p.id;
    final bool deleting = s.deleting.contains(p.id);
    final String? customer = p.customer == null ? null : (p.customer!.displayName ?? p.customer!.name);
    final DateTime? parkedAt = p.parkedAt;
    final String title = p.name ?? customer ?? (parkedAt == null ? p.id : CartFormats.time(parkedAt));
    final TextStyle meta = context.text.caption.copyWith(color: c.textSecondary);
    Widget? expires;
    final DateTime? until = p.expiresAt;
    if (until != null) {
      final Duration left = until.difference(now);
      final bool tomorrow = left <= const Duration(days: 1);
      final int days = (left.inHours + 23) ~/ 24;
      expires = Text.rich(
        TextSpan(
          children: <InlineSpan>[
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: EdgeInsetsDirectional.only(end: context.space.s1),
                child: Icon(Icons.schedule_rounded, size: 14, color: tomorrow ? c.warning : c.textSecondary),
              ),
            ),
            TextSpan(
              text: tomorrow ? l10n.parked_card_expires_tomorrow : l10n.parked_card_expires('${days < 1 ? 1 : days}'),
            ),
          ],
        ),
        style: meta.copyWith(color: tomorrow ? c.warning : c.textSecondary),
      );
    }
    final String? restored = p.restoredFromOrderId;
    final bool canResume = _canResume(p, s.scope, can);
    final bool canDelete = _canDelete(p, s.scope, can);
    final List<Widget> buttons = <Widget>[
      if (canDelete)
        Tooltip(
          message: offline ? l10n.parked_offline_tooltip : l10n.parked_delete_tooltip,
          child: AppIconButton(
            key: ParkedKeys.delete(p.id),
            icon: Icons.delete_outline_rounded,
            iconSize: 20,
            semanticLabel: l10n.parked_delete_tooltip,
            tooltip: '',
            loading: deleting,
            onPressed: offline || resuming || deleting ? null : () => unawaited(_delete(p, s.scope)),
          ),
        ),
      if (canResume)
        AppButton(
          key: ParkedKeys.resume(p.id),
          label: l10n.parked_resume,
          loading: resuming,
          onPressed: offline || deleting || (s.resuming != null && !resuming)
              ? null
              : () => unawaited(_resume(p, s.scope)),
        ),
    ];
    return Container(
      key: ParkedKeys.card(p.id),
      padding: EdgeInsets.symmetric(horizontal: context.space.s4, vertical: context.space.s3),
      decoration: BoxDecoration(
        color: selected ? c.surfaceHover : c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.text.body.copyWith(fontWeight: FontWeight.w600, color: c.textPrimary),
          ),
          if (restored != null)
            Padding(
              padding: EdgeInsets.symmetric(vertical: context.space.s1),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: InkWell(
                  key: ParkedKeys.restored(p.id),
                  onTap: () => unawaited(GoRouter.of(context).push<void>(CartPaths.order(restored))),
                  child: StatusChip(
                    label: l10n.parked_restored_chip(
                      RegExp(r'№\s*(\S+)').firstMatch(p.name ?? '')?.group(1) ?? restored,
                    ),
                    variant: StatusChipVariant.warning,
                    dense: true,
                  ),
                ),
              ),
            ),
          if (customer != null && customer != title)
            Text(customer, maxLines: 1, overflow: TextOverflow.ellipsis, style: meta),
          Text(
            l10n.parked_card_items_total(
              p.itemsCount ?? 0,
              p.total == null ? '—' : PriceText.format(p.total!, fixed2: true),
            ),
            style: meta.copyWith(fontFeatures: const <FontFeature>[FontFeature.tabularFigures()]),
          ),
          if (s.scope == ParkedScope.all && p.owner != null)
            Text(p.owner!.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: meta),
          Row(
            children: <Widget>[
              Expanded(
                child: Wrap(
                  spacing: context.space.s3,
                  runSpacing: context.space.s1,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    if (parkedAt != null) Text(CartFormats.time(parkedAt), style: meta),
                    ?expires,
                  ],
                ),
              ),
              ...buttons.expand((Widget b) => <Widget>[SizedBox(width: context.space.s2), b]),
            ],
          ),
        ],
      ),
    );
  }
}
