// SCR-20 «Корзина» (02 ч. C SCR-20; 03 §9.27–§9.31; RM-F-005, RM-F-013, RM-F-015): содержимое `CartPanel` для всех
// классов окна — `panel` (expanded, постоянная третья колонка SCR-10), `overlay` (medium, side sheet), `screen`
// (compact, `/cart`). Зоны: A шапка и счётчики → C баннер → B клиент и склад → D строки → E скидка → F итоги →
// G причина недоступности и действия.
//
// Итоги — только с сервера (D-23): пока изменения не подтверждены, «Итого» помечено «предварительно», суммы строк —
// «≈». Режим клиента (ядро §24.2, AC-UI-20-030): без клиента, склада, скидки, «Отложить» и «Отложенные»; CTA
// «Отправить заявку». Клавиатура Windows (03 A11Y-009): F4 — фокус в корзину, F9 — «Создать заказ», F8 — «Отложить
// заказ»; в панели ↑/↓ — строка, `+`/`−` — количество, `Delete` — удалить, `Ctrl+Z` — «Отменить».
// Результат `POST /orders` неизвестен — оверлей UI-20-020 поверх зон D–G (порт корня `cartSubmissionOverlayProvider`),
// все изменяющие действия недоступны (02 SCR-20.3 «H — оверлеи»).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/error_texts.dart';
import 'package:optomstroy/core/utils/debouncer.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/cart_line.dart' as ds;
import 'package:optomstroy/design_system/components/cart_panel.dart';
import 'package:optomstroy/design_system/components/cart_summary.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/discount_input.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/quantity_numpad_sheet.dart';
import 'package:optomstroy/design_system/components/quantity_stepper.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/unit_selector.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/sync/cart_sync.dart';
import 'package:optomstroy/features/cart/presentation/cart_formats.dart';
import 'package:optomstroy/features/cart/presentation/providers/cart_banner_port.dart';
import 'package:optomstroy/features/cart/presentation/providers/cart_controller.dart';
import 'package:optomstroy/features/cart/presentation/providers/cart_step_up_port.dart';
import 'package:optomstroy/features/cart/presentation/providers/cart_submission_port.dart';
import 'package:optomstroy/features/cart/presentation/screens/parked_carts_screen.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_customer_picker.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_dialogs.dart';
import 'package:uuid/uuid.dart';

/// Названия склада и вида цены корзины (кэш каталога).
final cartPlaceLabelsProvider = FutureProvider.autoDispose.family<CartPlaceLabels, (String?, String?)>(
  (Ref ref, (String?, String?) ids) =>
      ref.watch(cartSyncProvider).placeLabels(warehouseId: ids.$1, priceListId: ids.$2),
);

/// Ключи элементов SCR-20 (тесты).
abstract final class CartKeys {
  static const Key panel = ValueKey<String>('cart-panel');
  static const Key createOrder = ValueKey<String>('cart-create-order');
  static const Key park = ValueKey<String>('cart-park');
  static const Key clear = ValueKey<String>('cart-clear');
  static const Key parked = ValueKey<String>('cart-parked');
  static const Key reason = ValueKey<String>('cart-cta-reason');
  static const Key banner = ValueKey<String>('cart-banner');
  static const Key bannerAction = ValueKey<String>('cart-banner-action');
  static const Key warehouse = ValueKey<String>('cart-warehouse');
  static const Key customer = ValueKey<String>('cart-customer');
  static const Key saveState = ValueKey<String>('cart-save-state');
  static const Key discountApplyLimit = ValueKey<String>('cart-discount-apply-limit');
  static const Key discountHow = ValueKey<String>('cart-discount-how');
  static const Key lockOverlay = ValueKey<String>('cart-submission-lock');
  static const Key discountApprove = ValueKey<String>('cart-discount-approve');

  static Key line(CartLineKey k) => ValueKey<String>('cart-line-${k.variantId}-${k.packagingId ?? ''}');

  static Key reduce(CartLineKey k) => ValueKey<String>('cart-line-reduce-${k.variantId}-${k.packagingId ?? ''}');
}

/// Содержимое корзины SCR-20.
class CartPanelView extends ConsumerStatefulWidget {
  /// Создаёт корзину варианта [variant].
  const CartPanelView({super.key, this.variant = CartPanelVariant.panel, this.onClose});

  final CartPanelVariant variant;

  /// Крестик `overlay`.
  final VoidCallback? onClose;

  @override
  ConsumerState<CartPanelView> createState() => _CartPanelViewState();
}

class _CartPanelViewState extends ConsumerState<CartPanelView> {
  final TextEditingController _discount = TextEditingController();
  final FocusNode _discountFocus = FocusNode(debugLabel: 'cart-discount');
  final FocusNode _panelFocus = FocusNode(debugLabel: 'cart-panel');
  final Debouncer _discountDebounce = Debouncer(Debouncer.cart);
  String? _discountError;
  Percent? _discountShown;
  int? _selected;
  CartLineKey? _lastRemoved;
  String? _parkKey;
  bool _conflictOpen = false;
  StreamSubscription<CartSyncEvent>? _events;
  StreamSubscription<CartNotice>? _notices;

  static bool _anyConflictDialog = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onGlobalKey);
    _events = ref.read(cartSyncProvider).events.listen(_onSyncEvent, onError: (Object _) {});
    _notices = ref.read(cartControllerProvider.notifier).watchNotices().listen(_onNotice);
    // Конфликт, обнаруженный до открытия корзины (в том числе восстановленный после перезапуска), — диалог сразу.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final CartVersionConflict? c = ref.read(cartControllerProvider).conflict;
      if (c != null) unawaited(_showConflict(c));
    });
  }

  void _onNotice(CartNotice n) {
    // Снекбар показывает одна корзина на экране (панель на expanded или экран/лист).
    if (!mounted || !TickerMode.of(context)) return;
    final AppLocalizations l10n = AppLocalizations.of(context);
    switch (n.kind) {
      case CartNoticeKind.updatedFromServer:
        AppSnackbar.show(context, message: l10n.cart_updated_from_server(n.count));
      case CartNoticeKind.maxItems:
        AppSnackbar.show(context, message: l10n.cart_max_items('${n.count}'), variant: AppSnackbarVariant.error);
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    unawaited(_events?.cancel());
    unawaited(_notices?.cancel());
    _discountDebounce.dispose();
    _discount.dispose();
    _discountFocus.dispose();
    _panelFocus.dispose();
    super.dispose();
  }

  CartController get _cart => ref.read(cartControllerProvider.notifier);

  /// Блокировка UI-20-020: результат `POST /orders` неизвестен.
  bool get _locked => ref.read(cartSubmissionLockedProvider);

  bool get _offline {
    final OnlineStatus s = ref.read(cartOnlineStatusProvider);
    return s == OnlineStatus.offline || s == OnlineStatus.serverDown;
  }

  // ---------------------------------------------------------------------------
  // Клавиатура
  // ---------------------------------------------------------------------------

  /// Экран активен для F8/F9: ветка на экране (`TickerMode`), поверх нет диалога/листа (`PopupRoute`).
  bool get _keysActive {
    if (!mounted || !TickerMode.of(context)) return false;
    final BuildContext? fc = FocusManager.instance.primaryFocus?.context;
    if (fc != null && ModalRoute.of(fc) is PopupRoute) return false;
    if (widget.variant != CartPanelVariant.panel && !(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    return true;
  }

  bool _onGlobalKey(KeyEvent e) {
    if (e is! KeyDownEvent || !_keysActive) return false;
    if (e.logicalKey == LogicalKeyboardKey.f4) {
      // F4 — фокус в корзину (03 A11Y-009, §9.27); строка выбирается стрелками.
      _panelFocus.requestFocus();
      return true;
    }
    if (_locked) return false;
    if (e.logicalKey == LogicalKeyboardKey.f9) {
      unawaited(_createOrder());
      return true;
    }
    if (e.logicalKey == LogicalKeyboardKey.f8) {
      if (!cartPermissionsFor(ref.read(cartViewerRoleProvider)).canPark) return false;
      unawaited(_park());
      return true;
    }
    return false;
  }

  KeyEventResult _onPanelKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (_locked) return KeyEventResult.ignored;
    final BuildContext? fc = FocusManager.instance.primaryFocus?.context;
    if (fc != null && fc.findAncestorStateOfType<EditableTextState>() != null) return KeyEventResult.ignored;
    final List<CartLineView> lines = ref.read(cartControllerProvider).lines;
    final LogicalKeyboardKey k = e.logicalKey;
    if (k == LogicalKeyboardKey.keyZ && HardwareKeyboard.instance.isControlPressed) {
      final CartLineKey? last = _lastRemoved;
      if (last != null) {
        _cart.undoRemove(last);
        _lastRemoved = null;
        ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (lines.isEmpty) return KeyEventResult.ignored;
    final int current = (_selected ?? -1).clamp(-1, lines.length - 1);
    if (k == LogicalKeyboardKey.arrowDown) {
      setState(() => _selected = (current + 1).clamp(0, lines.length - 1));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      setState(() => _selected = (current - 1).clamp(0, lines.length - 1));
      return KeyEventResult.handled;
    }
    if (current < 0) return KeyEventResult.ignored;
    final CartLineView line = lines[current];
    if (k == LogicalKeyboardKey.add || k == LogicalKeyboardKey.numpadAdd || k == LogicalKeyboardKey.equal) {
      if (line.canIncrement) unawaited(_cart.increment(line));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.minus || k == LogicalKeyboardKey.numpadSubtract) {
      unawaited(_decrement(line));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.delete) {
      _remove(line);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---------------------------------------------------------------------------
  // Действия
  // ---------------------------------------------------------------------------

  void _onSyncEvent(CartSyncEvent e) {
    if (!mounted || e is! CartSyncRejected) return;
    _snackError(e.failure);
  }

  void _snackError(Failure f) {
    if (!mounted) return;
    final AppLocalizations l10n = AppLocalizations.of(context);
    AppSnackbar.show(
      context,
      message: ErrorTexts.message(l10n, UiErrorMapper.fromFailure(f)),
      variant: AppSnackbarVariant.error,
    );
  }

  Future<void> _decrement(CartLineView line) async {
    final bool done = await _cart.decrement(line);
    if (!done && mounted) await _confirmDelete(line);
  }

  /// Удаление строки с подтверждением (CART-003/012): «−» на минимуме, 0 в нампаде, «Уменьшить до 0».
  Future<void> _confirmDelete(CartLineView line) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool ok = await ConfirmDialog.show(
      context,
      title: l10n.cart_line_delete_dialog_title(line.title),
      message: l10n.cart_line_delete_confirm,
      confirmLabel: l10n.qty_delete,
      variant: ConfirmDialogVariant.destructive,
    );
    if (ok) await _cart.setQuantity(line.key, Qty.zero);
  }

  /// Крестик / свайп / `Delete` (UI-20-010): без диалога, «Позиция удалена · Отменить» (UI-20-028).
  void _remove(CartLineView line) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    _cart.removeWithUndo(line.key, previous: line.quantity);
    _lastRemoved = line.key;
    AppSnackbar.show(
      context,
      message: l10n.cart_line_deleted_snackbar,
      actionLabel: l10n.ds_button_undo,
      onAction: () {
        _cart.undoRemove(line.key);
        _lastRemoved = null;
      },
    );
  }

  /// «Вариант» строки (UI-20-007, CART-005): SCR-15 в режиме смены → «Заменить вариант». Новый вариант уже в
  /// корзине (та же упаковка) — `ConfirmDialog` «Вариант уже в корзине. Объединить количества?» с итоговым
  /// количеством; «Отмена» — корзина не меняется, лист остаётся открытым (T-CART-004).
  Future<void> _changeVariant(CartLineView line, CartVariantPicker picker) async {
    final String? productId = line.productId;
    if (productId == null) return;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String unit = line.unitLabel ?? '';
    await picker(
      context,
      CartVariantChange(
        productId: productId,
        currentVariantId: line.key.variantId,
        packagingId: line.key.packagingId,
        quantity: line.quantity,
        productName: line.title,
        unitLabel: line.unitLabel,
        warehouseId: ref.read(cartControllerProvider).server?.warehouseId,
      ),
      (CartVariantChoice choice) async {
        if (!mounted || choice.variantId == line.key.variantId) return false;
        final CartLineView? existing = _cart.lineFor(choice.variantId, line.key.packagingId);
        if (existing != null) {
          final String merged = CartFormats.qty(existing.quantity + line.quantity);
          final bool ok = await ConfirmDialog.show(
            context,
            title: l10n.variant_merge_confirm,
            message: '${CartFormats.qty(existing.quantity)} + ${CartFormats.qty(line.quantity)} = $merged $unit'.trim(),
            confirmLabel: l10n.variant_replace_cta,
          );
          if (!ok || !mounted) return false;
        }
        final Failure? f = await _cart.replaceVariant(line, choice.variantId, priceSnapshot: choice.priceSnapshot);
        if (f != null) {
          _snackError(f);
          return false;
        }
        return true;
      },
    );
  }

  Future<void> _numpad(CartLineView line) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String unitId = line.unitId ?? 'unit';
    final QuantityNumpadResult? r = await QuantityNumpadSheet.show(
      context,
      title: l10n.qty_sheet_title(line.title),
      initialInput: CartFormats.qtyInput(line.quantity),
      units: <UnitOption>[UnitOption(id: unitId, label: line.unitLabel ?? '')],
      selectedUnitId: unitId,
      decimalsFor: (_) => line.precision,
      validate: (String input, String _) {
        final Qty? q = parseLineQuantity(input, line.precision);
        return NumpadValidation(
          canSubmit: q != null,
          error: q == null ? l10n.cart_qty_invalid(CartFormats.qty(line.step), line.unitLabel ?? '') : null,
        );
      },
    );
    if (r == null || !mounted) return;
    final Qty? q = parseLineQuantity(r.input, line.precision);
    if (q == null) return;
    if (q.isZero) {
      await _confirmDelete(line);
    } else {
      await _cart.setQuantity(line.key, q);
    }
  }

  /// «Уменьшить до {available}» (UI-20-025).
  Future<void> _reduce(CartLineView line) async {
    final Qty? target = line.reduceTarget;
    if (target == null) return;
    if (target.isZero) {
      await _confirmDelete(line);
    } else {
      await _cart.setQuantity(line.key, target);
    }
  }

  bool _ctaEnabled(CartState s) =>
      _ctaReason(AppLocalizations.of(context), s, offline: _offline) == null && s.conflict == null;

  /// «Создать заказ →» / «Отправить заявку» (UI-20-016, F9): изменения отправляются, затем SCR-21; повтор во время
  /// подготовки игнорируется. Предпроверку `POST /cart/checkout-preview` выполняет SCR-21 (FQ-CART-01).
  Future<void> _createOrder() async {
    final CartState s = ref.read(cartControllerProvider);
    if (_locked || s.isBusy(CartOp.checkout) || !_ctaEnabled(s)) return;
    // AC-UI-20-016: подготовка завершается до следующего кадра, и второе нажатие того же кадра открыло бы SCR-21
    // повторно (две предпроверки) — после перехода повтор игнорируется [_checkoutGuard].
    final DateTime? opened = _checkoutOpenedAt;
    if (opened != null && DateTime.now().difference(opened) < _checkoutGuard) return;
    final bool ok = await _cart.prepareCheckout();
    if (!ok || !mounted) return;
    final DateTime? again = _checkoutOpenedAt;
    if (again != null && DateTime.now().difference(again) < _checkoutGuard) return;
    _checkoutOpenedAt = DateTime.now();
    final String? cartId = ref.read(cartControllerProvider).server?.id;
    if (widget.variant == CartPanelVariant.overlay) widget.onClose?.call();
    unawaited(GoRouter.of(context).push<void>(CartPaths.checkout(cartId)));
  }

  /// Окно, в котором повторное «Создать заказ →» после перехода в SCR-21 игнорируется.
  static const Duration _checkoutGuard = Duration(seconds: 1);
  DateTime? _checkoutOpenedAt;

  /// «Отложить заказ» (UI-20-015, F8): диалог → `POST /cart/park` с ключом, созданным при подтверждении.
  Future<void> _park() async {
    final CartState s = ref.read(cartControllerProvider);
    if (_locked || s.isBusy(CartOp.park) || s.lines.isEmpty || _offline || s.server == null) return;
    final ParkDialogResult? r = await showParkDialog(context);
    if (r == null || !mounted) return;
    await _doPark(r.name);
  }

  Future<void> _doPark(String? name) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String key = _parkKey ??= const Uuid().v4();
    final Failure? f = await _cart.park(name: name, idempotencyKey: key);
    if (!mounted) return;
    if (f == null) {
      _parkKey = null;
      ref.invalidate(cartParkedCountProvider);
      AppSnackbar.show(
        context,
        message: l10n.cart_parked_snackbar,
        actionLabel: l10n.cart_parked_snackbar_open,
        onAction: () => unawaited(_openParked()),
      );
      return;
    }
    // Сетевой сбой — тот же ключ при повторе (08 §2.7); иной отказ — новая попытка с новым ключом.
    if (f is! NetworkFailure) _parkKey = null;
    _snackError(f);
  }

  Future<void> _clear() async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final CartState s = ref.read(cartControllerProvider);
    Failure? result;
    final bool ok = await ConfirmDialog.show(
      context,
      title: l10n.cart_clear_dialog_title,
      message: l10n.cart_clear_dialog_body(s.lines.length),
      confirmLabel: l10n.cart_clear_dialog_confirm,
      variant: ConfirmDialogVariant.destructive,
      onConfirm: (String? _) async {
        result = await _cart.clear();
        if (result != null && result is! ConflictFailure) throw StateError('clear failed');
      },
    );
    if (!mounted) return;
    if (result is ConflictFailure) {
      AppSnackbar.show(context, message: l10n.cart_version_conflict_title, variant: AppSnackbarVariant.error);
    } else if (ok) {
      _selected = null;
    }
  }

  Future<void> _openParked() async {
    final WindowClass wc = context.windowClass;
    if (wc == WindowClass.compact) {
      unawaited(GoRouter.of(context).push<void>(CartPaths.parked));
      return;
    }
    await AppBottomSheet.showSide<void>(context, width: parkedSheetWidth, body: const ParkedCartsBody(asSheet: true));
    ref.invalidate(cartParkedCountProvider);
  }

  /// UI-20-004: поиск клиента → `POST /cart/customer` (цены по условиям клиента, CART-020); «Розничный
  /// покупатель» → `DELETE /cart/customer`; «+ Новый клиент» → SCR-26 и выбор созданного.
  Future<void> _pickCustomer(Cart server) async {
    final RoleCode? role = ref.read(cartViewerRoleProvider);
    final CartCustomerChoice? choice = await showCartCustomerPicker(
      context,
      role: role,
      online: !_offline,
      retailSelected: server.customer == null || server.customer!.isRetailDefault,
    );
    if (choice == null || !mounted) return;
    Failure? f;
    switch (choice) {
      case CartCustomerSelected(:final String customerId):
        f = await _cart.setCustomer(customerId);
      case CartCustomerRetail():
        if (server.customer != null) f = await _cart.clearCustomer();
      case CartCustomerCreateNew():
        final String? id = await GoRouter.of(context).push<String>(CartPaths.newCustomer);
        if (id != null && mounted) f = await _cart.setCustomer(id);
    }
    if (f != null) _snackError(f);
  }

  Future<void> _changeWarehouse(Cart server) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final List<CartWarehouseOption> options =
        (await ref.read(cartSyncProvider).warehouses()).valueOrNull ?? const <CartWarehouseOption>[];
    if (!mounted || options.isEmpty) return;
    final CartWarehouseOption? picked = await showWarehouseMenu(
      context,
      options: options,
      currentId: server.warehouseId,
    );
    if (picked == null || picked.id == server.warehouseId || !mounted) return;
    final Result<Cart> r = await _cart.setWarehouse(picked.id);
    if (!mounted) return;
    switch (r) {
      case Success<Cart>(:final Cart value):
        final int short = value.warnings.where((CartConflict c) => c.kind == CartConflictKind.stockInsufficient).length;
        AppSnackbar.show(
          context,
          message: short > 0
              ? l10n.cart_warehouse_change_warnings(short, picked.name)
              : l10n.cart_warehouse_changed(picked.name),
        );
      case FailureResult<Cart>(:final Failure failure):
        _snackError(failure);
    }
  }

  void _onDiscountChanged(String text) {
    _cart.clearDiscountRejection();
    final Percent? p = CartFormats.parsePercent(text);
    setState(() => _discountError = p == null ? AppLocalizations.of(context).cart_discount_invalid : null);
    if (p == null) {
      _discountDebounce.cancel();
      return;
    }
    _discountDebounce(() => unawaited(_applyDiscount(p)));
  }

  void _onDiscountSubmitted(String text) {
    _discountDebounce.cancel();
    final Percent? p = CartFormats.parsePercent(text);
    if (p == null) {
      setState(() => _discountError = AppLocalizations.of(context).cart_discount_invalid);
      return;
    }
    unawaited(_applyDiscount(p));
  }

  Future<void> _applyDiscount(Percent p) async {
    final CartState s = ref.read(cartControllerProvider);
    if (s.isBusy(CartOp.discount)) return;
    if (s.server?.requestedDiscountPercent?.hundredths == p.hundredths && s.discountRejection == null) return;
    final Failure? f = await _cart.applyDiscount(p);
    if (!mounted) return;
    if (f != null && !(f is ServerFailure && f.code == 'DISCOUNT_LIMIT_EXCEEDED')) _snackError(f);
  }

  /// Override старшего (UI-20-033) показывается только `senior_seller`/`admin` в возобновлённой чужой корзине
  /// (`Cart.audit.createdBy` ≠ текущий пользователь), если запрошенная скидка не больше лимита подтверждающего.
  bool _canApproveDiscount(Cart server, CartDiscountRejection rej) {
    final Percent? approver = cartApproverLimit(ref.read(cartViewerRoleProvider));
    final String? me = ref.read(cartViewerUserIdProvider);
    final String? author = server.createdById;
    if (approver == null || me == null || author == null || author == me) return false;
    return rej.requested.hundredths <= approver.hundredths;
  }

  /// «Подтвердить скидку {p} %»: причина (обязательно, ≤ 200) → StepUpDialog → `POST /cart/discount` с override.
  Future<void> _approveDiscount(Percent percent) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    String? reason;
    final bool ok = await ConfirmDialog.show(
      context,
      title: l10n.cart_discount_approve_button(CartFormats.percent(percent)),
      message: l10n.cart_discount_override_reason_required,
      confirmLabel: l10n.cart_discount_approve_button(CartFormats.percent(percent)),
      variant: ConfirmDialogVariant.withReason,
      reasonLabel: l10n.cart_discount_override_reason_label,
      onConfirm: (String? r) async => reason = r,
    );
    final String? why = reason?.trim();
    if (!ok || why == null || why.isEmpty || !mounted) return;
    final String? token = await ref.read(cartStepUpProvider)('discount.approve.over_limit');
    if (token == null || !mounted) return;
    final Failure? f = await _cart.approveDiscount(percent, reason: why, stepUpToken: token);
    if (!mounted) return;
    if (f != null) {
      _snackError(f);
    } else {
      setState(() => _approvedPercent = percent);
    }
  }

  /// Скидка, подтверждённая override в этой сессии (UI-20-033) — «Подтвердил: {name}», пока она применена.
  Percent? _approvedPercent;

  Future<void> _applyLimit(Percent limit) async {
    _discount.text = CartFormats.percent(limit);
    _discountShown = limit;
    await _applyDiscount(limit);
  }

  Future<void> _showConflict(CartVersionConflict c) async {
    if (_conflictOpen || _anyConflictDialog) return;
    _conflictOpen = true;
    _anyConflictDialog = true;
    try {
      final bool? mine = await showVersionConflictDialog(context, c);
      if (mine == null || !mounted) return;
      final Failure? f = await _cart.resolveConflict(applyMine: mine);
      if (f != null) _snackError(f);
    } finally {
      _conflictOpen = false;
      _anyConflictDialog = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Построение
  // ---------------------------------------------------------------------------

  /// Причина недоступности CTA по приоритету (UI-20-022).
  static String? _ctaReason(AppLocalizations l10n, CartState s, {required bool offline}) {
    if (s.lines.isEmpty) return l10n.cart_cta_reason_empty;
    if (offline) return l10n.cart_cta_reason_offline;
    if (s.hasPriceChanges) return l10n.cart_cta_reason_accept_prices;
    if (s.hasStockShortage) return l10n.cart_cta_reason_reduce_qty;
    if (s.hasUnavailable) return l10n.cart_cta_reason_remove_unavailable;
    if (s.server == null || (s.staleAtOpen && s.refreshing)) return l10n.cart_cta_reason_refreshing;
    return null;
  }

  void _syncDiscountField(CartState s) {
    final Percent? requested = s.server?.requestedDiscountPercent ?? s.server?.appliedDiscountPercent;
    if (_discountFocus.hasFocus || s.discountRejection != null || requested == null) return;
    if (_discountShown?.hundredths == requested.hundredths) return;
    _discountShown = requested;
    _discount.text = requested.hundredths == 0 ? '' : CartFormats.percent(requested);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final CartState s = ref.watch(cartControllerProvider);
    final OnlineStatus online = ref.watch(cartOnlineStatusProvider);
    final bool offline = online == OnlineStatus.offline || online == OnlineStatus.serverDown;
    final CartPermissions can = cartPermissionsFor(ref.watch(cartViewerRoleProvider));
    final int? parkedCount = can.canPark ? ref.watch(cartParkedCountProvider).value : null;
    final bool locked = ref.watch(cartSubmissionLockedProvider);
    final CartSubmissionOverlayBuilder? lockOverlay = ref.watch(cartSubmissionOverlayProvider);
    ref.listen<CartVersionConflict?>(cartControllerProvider.select((CartState v) => v.conflict), (
      CartVersionConflict? previous,
      CartVersionConflict? next,
    ) {
      if (next != null && !identical(previous, next)) unawaited(_showConflict(next));
    });
    _syncDiscountField(s);

    final List<CartLineView> lines = s.lines;
    final Cart? server = s.server;
    final bool empty = lines.isEmpty;
    final bool compactLines = widget.variant == CartPanelVariant.panel;
    final String? reason = _ctaReason(l10n, s, offline: offline);

    // Зона A — шапка.
    final List<Widget> actions = <Widget>[
      if (can.canPark)
        AppIconButton(
          key: CartKeys.parked,
          icon: Icons.bookmarks_outlined,
          semanticLabel: l10n.cart_parked_tooltip,
          onPressed: locked ? null : () => unawaited(_openParked()),
          badge: parkedCount == null || parkedCount == 0 ? null : _CountBadge(count: parkedCount),
        ),
      AppIconButton(
        key: CartKeys.clear,
        icon: Icons.delete_sweep_outlined,
        semanticLabel: l10n.cart_clear_tooltip,
        tooltip: offline ? l10n.parked_offline_tooltip : null,
        onPressed: empty || offline || locked || server == null || s.isBusy(CartOp.clear)
            ? null
            : () => unawaited(_clear()),
      ),
    ];
    final String? counter = empty
        ? null
        : l10n.cart_counter_units(l10n.cart_positions_short(s.positions), s.unitsText('').trim());

    // Зона C — баннер (один, по приоритету): собственный баннер корзины, иначе — уведомление центра (RM-F-008).
    final CartNotificationBannerBuilder? notificationBanner = ref.watch(cartNotificationBannerProvider);
    final Widget? banner =
        _banner(l10n, s, offline: offline) ??
        (notificationBanner == null || server == null ? null : notificationBanner(context, server.id));

    // Зона B — клиент и склад (не для клиента).
    final Widget? place = can.customer || server == null ? null : _placeRow(l10n, c, s, server, can, offline: offline);
    final Widget? top = place == null || !locked ? place : IgnorePointer(child: place);

    // Зона D — строки.
    final Widget body;
    if (s.restoring && empty) {
      body = ListView(
        padding: EdgeInsets.all(context.space.s3),
        children: <Widget>[
          for (int i = 0; i < 3; i++)
            Padding(
              padding: EdgeInsets.only(bottom: context.space.s2),
              child: const SkeletonBox(height: 64),
            ),
        ],
      );
    } else if (empty && s.loadFailure != null) {
      final Failure lf = s.loadFailure!;
      body = Center(
        child: ErrorState.inline(
          // `503 catalog_not_loaded` (08 §4.7.1 п. 2): каталог 1С на сервере ещё не загружен — не «заказ будет
          // отправлен позже»; повтор — сам через `Retry-After` (CartController) или «Повторить».
          message: lf is OnecUnavailableFailure && lf.catalogNotLoaded
              ? l10n.catalog_error_title
              : ErrorTexts.message(l10n, UiErrorMapper.fromFailure(lf)),
          onRetry: () => unawaited(_cart.refresh()),
          retrying: s.refreshing,
        ),
      );
    } else if (empty) {
      body = Center(
        child: SingleChildScrollView(
          child: EmptyState(
            variant: EmptyStateVariant.cart,
            title: l10n.cart_empty_title,
            body: l10n.cart_empty_body,
            actionLabel: widget.variant == CartPanelVariant.screen ? l10n.cart_empty_to_catalog : null,
            onAction: widget.variant == CartPanelVariant.screen
                ? () => GoRouter.of(context).go(can.customer ? CartPaths.home : CartPaths.catalog)
                : null,
            secondaryActionLabel: parkedCount != null && parkedCount > 0 ? l10n.cart_empty_parked(parkedCount) : null,
            onSecondaryAction: parkedCount != null && parkedCount > 0 ? () => unawaited(_openParked()) : null,
          ),
        ),
      );
    } else {
      body = ListView.builder(
        itemCount: lines.length,
        itemBuilder: (BuildContext context, int i) =>
            _line(l10n, c, lines[i], selected: _selected == i, dense: compactLines, offline: offline, can: can),
      );
    }

    // Зоны E–F — скидка и итоги.
    final Widget? bottom = empty
        ? null
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (can.canDiscount && server != null)
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: context.space.s5),
                  child: _discountInput(l10n, s, server, offline: offline),
                ),
              CartSummary(
                rows: <CartSummaryRow>[
                  CartSummaryRow(label: l10n.cart_summary_items(s.positions), amount: server?.subtotal),
                  if (server != null &&
                      ((server.appliedDiscountPercent?.hundredths ?? 0) > 0 || (server.discountTotal?.tyiyn ?? 0) > 0))
                    CartSummaryRow(
                      label: l10n.cart_summary_discount(
                        CartFormats.percent(server.appliedDiscountPercent ?? Percent.zero),
                      ),
                      amount: server.discountTotal,
                      negative: true,
                    ),
                ],
                totalLabel: l10n.cart_summary_total,
                total: server?.total,
                loading: server == null && s.refreshing,
                large: widget.variant == CartPanelVariant.panel,
                preliminaryLabel: s.preliminary || offline ? l10n.cart_summary_preliminary : null,
              ),
            ],
          );

    // Зона G — действия.
    final bool parkEnabled = !empty && !offline && server != null && s.conflict == null;
    final Widget footer = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (reason != null && !empty)
          Padding(
            padding: EdgeInsets.only(bottom: context.space.s2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(Icons.info_outline_rounded, size: 16, color: offline ? c.warning : c.textSecondary),
                SizedBox(width: context.space.s1),
                Flexible(
                  child: Text(
                    reason,
                    key: CartKeys.reason,
                    textAlign: TextAlign.center,
                    style: context.text.caption.copyWith(color: offline ? c.warning : c.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        if (can.canPark && !empty) ...<Widget>[
          AppButton(
            key: CartKeys.park,
            label: l10n.cart_cta_park,
            icon: Icons.bookmark_outline_rounded,
            variant: AppButtonVariant.outlined,
            expand: true,
            loading: s.isBusy(CartOp.park),
            onPressed: parkEnabled ? () => unawaited(_park()) : null,
          ),
          SizedBox(height: context.space.s2),
        ],
        if (!empty)
          AppButton(
            key: CartKeys.createOrder,
            label: can.customer ? l10n.cart_customer_submit : l10n.cart_cta_create_order,
            trailingIcon: Icons.arrow_forward_rounded,
            size: AppButtonSize.l,
            expand: true,
            loading: s.isBusy(CartOp.checkout),
            onPressed: _ctaEnabled(s) ? () => unawaited(_createOrder()) : null,
          ),
      ],
    );

    return Focus(
      key: CartKeys.panel,
      focusNode: _panelFocus,
      onKeyEvent: _onPanelKey,
      child: CartPanel(
        variant: widget.variant,
        title: l10n.cart_title,
        count: s.positions,
        countLabel: l10n.cart_a11y_positions(s.positions),
        counter: counter,
        counterTrailing: _saveState(l10n, c, s, offline: offline, empty: empty),
        actions: actions,
        banner: banner,
        top: top,
        body: body,
        bottom: bottom,
        footer: empty ? null : footer,
        overlay: locked
            ? KeyedSubtree(key: CartKeys.lockOverlay, child: lockOverlay?.call(context) ?? const _LockFallback())
            : null,
        onClose: widget.onClose,
        closeLabel: l10n.ds_button_close,
      ),
    );
  }

  Widget? _saveState(AppLocalizations l10n, DsColors c, CartState s, {required bool offline, required bool empty}) {
    final TextStyle style = context.text.caption.copyWith(color: c.textSecondary);
    final bool failed = s.syncStatus.dead > 0 || s.lines.any((CartLineView l) => l.failed);
    if (failed) {
      return InkWell(
        key: CartKeys.saveState,
        onTap: () => unawaited(_cart.retryFailed()),
        child: Text(l10n.cart_save_state_failed, style: style.copyWith(color: c.error)),
      );
    }
    if (s.syncStatus.queued > 0 || s.hasUnconfirmed) {
      final int queued = s.syncStatus.queued > 0 ? s.syncStatus.queued : 1;
      return Text(
        offline ? l10n.cart_save_state_queued(queued) : l10n.cart_save_state_saving,
        key: CartKeys.saveState,
        style: style,
      );
    }
    if (empty || s.server == null) return null;
    return Text(l10n.cart_save_state_saved, key: CartKeys.saveState, style: style);
  }

  Widget? _banner(AppLocalizations l10n, CartState s, {required bool offline}) {
    if (offline) {
      return _CartBanner(tone: ErrorStateTone.warning, icon: Icons.cloud_off_rounded, text: l10n.cart_banner_offline);
    }
    final Cart? server = s.server;
    final int prices = s.lines.where((CartLineView l) => l.priceChanged).length;
    if (prices > 0) {
      return _CartBanner(
        tone: ErrorStateTone.warning,
        icon: Icons.warning_amber_rounded,
        text: l10n.cart_banner_prices_changed(prices),
        actionLabel: l10n.cart_banner_accept_prices,
        actionLoading: s.isBusy(CartOp.acceptPrices),
        onAction: () async {
          final Failure? f = await _cart.acceptPrices();
          if (f != null) _snackError(f);
        },
      );
    }
    final int stock = s.lines.where((CartLineView l) => l.stockInsufficient && !l.unavailable).length;
    if (stock > 0) {
      return _CartBanner(
        tone: ErrorStateTone.error,
        icon: Icons.inventory_2_outlined,
        text: l10n.cart_banner_stock(stock),
      );
    }
    final String? restored = server?.restoredFromOrderId;
    if (restored != null) {
      // `Cart.restoredFromOrder {number, reason}` (OpenAPI 1.2.0, 08 §3.8 «Уточнения» п. 4; pos-api передаёт с
      // закрытия F); `null` — номер серверу неизвестен: номер из названия корзины, причина опускается (FQ-CART-05).
      final CartRestoredFromOrder? from = server?.restoredFromOrder;
      final String number = from?.number ?? RegExp(r'№\s*(\S+)').firstMatch(server?.name ?? '')?.group(1) ?? restored;
      final String? reason = from?.reason?.trim();
      final String text = reason != null && reason.isNotEmpty
          ? l10n.cart_banner_restored_from_order(number, reason)
          : l10n.cart_banner_restored_from_order(number, '').replaceFirst(RegExp(r':\s*$'), '');
      return _CartBanner(
        tone: ErrorStateTone.info,
        icon: Icons.history_rounded,
        text: text,
        onAction: () => GoRouter.of(context).push<void>(CartPaths.order(restored)),
      );
    }
    final DateTime? at = s.local?.serverSyncedAt;
    if (s.staleAtOpen && at != null) {
      return _CartBanner(
        tone: ErrorStateTone.info,
        icon: Icons.schedule_rounded,
        text: l10n.cart_banner_stale(CartFormats.time(at)),
      );
    }
    return null;
  }

  Widget _placeRow(
    AppLocalizations l10n,
    DsColors c,
    CartState s,
    Cart server,
    CartPermissions can, {
    required bool offline,
  }) {
    final TextStyle caption = context.text.caption.copyWith(color: c.textSecondary);
    final String? customerName = server.customer == null
        ? null
        : (server.customer!.displayName ?? server.customer!.name);
    final AsyncValue<CartPlaceLabels> labels = ref.watch(
      cartPlaceLabelsProvider((server.warehouseId, server.priceListId)),
    );
    final CartPlaceLabels? names = labels.value;
    final bool canChange =
        can.canChangeWarehouse && !offline && !s.isBusy(CartOp.warehouse) && server.warehouseId != null;
    final Widget warehouse = server.warehouseId == null
        ? const SizedBox.shrink()
        : Tooltip(
            message: offline ? l10n.cart_warehouse_readonly_tooltip : '',
            child: InkWell(
              key: CartKeys.warehouse,
              onTap: canChange ? () => unawaited(_changeWarehouse(server)) : null,
              // Строка 32 lp, цель нажатия 48 (02 UI-20-005, D-18).
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        l10n.cart_warehouse_label(names?.priceList ?? '—', names?.warehouse ?? '—'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: caption,
                      ),
                    ),
                    if (s.isBusy(CartOp.warehouse))
                      const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    else if (can.canChangeWarehouse)
                      Icon(Icons.expand_more_rounded, size: 16, color: canChange ? c.textSecondary : c.disabledText),
                  ],
                ),
              ),
            ),
          );
    return Container(
      padding: EdgeInsets.fromLTRB(context.space.s5, context.space.s2, context.space.s3, context.space.s1),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (can.canChooseCustomer)
            InkWell(
              key: CartKeys.customer,
              onTap: offline || s.isBusy(CartOp.customer) ? null : () => unawaited(_pickCustomer(server)),
              child: SizedBox(
                height: 40,
                child: Row(
                  children: <Widget>[
                    Icon(Icons.person_outline_rounded, size: 20, color: c.textSecondary),
                    SizedBox(width: context.space.s2),
                    Expanded(
                      child: Text(
                        customerName ?? l10n.cart_customer_empty,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.text.body.copyWith(
                          fontWeight: FontWeight.w500,
                          color: customerName == null ? c.textSecondary : c.textPrimary,
                        ),
                      ),
                    ),
                    if (s.isBusy(CartOp.customer))
                      const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    else if (customerName != null)
                      AppIconButton(
                        icon: Icons.close_rounded,
                        small: true,
                        iconSize: 20,
                        semanticLabel: l10n.ds_button_reset,
                        onPressed: offline
                            ? null
                            : () async {
                                final Failure? f = await _cart.clearCustomer();
                                if (f != null) _snackError(f);
                              },
                      )
                    else
                      Icon(Icons.chevron_right_rounded, size: 20, color: offline ? c.disabledText : c.textSecondary),
                  ],
                ),
              ),
            ),
          warehouse,
        ],
      ),
    );
  }

  Widget _discountInput(AppLocalizations l10n, CartState s, Cart server, {required bool offline}) {
    final CartDiscountRejection? rej = s.discountRejection;
    final Percent applied = server.appliedDiscountPercent ?? Percent.zero;
    final Percent? limit = rej?.limit ?? server.discountLimitPercent;
    String? message = _discountError;
    final List<Widget> actions = <Widget>[];
    final String? approver = ref.watch(cartViewerNameProvider);
    if (message == null &&
        rej == null &&
        approver != null &&
        _approvedPercent != null &&
        applied.hundredths == _approvedPercent!.hundredths) {
      message = l10n.cart_discount_approved_by(approver);
    }
    if (rej != null && message == null) {
      message = l10n.cart_discount_over_limit(
        CartFormats.percent(applied),
        limit == null ? '—' : CartFormats.percent(limit),
      );
      if (rej.overCeiling) {
        message = '$message\n${l10n.cart_discount_over_max(CartFormats.percent(cartDiscountCeiling))}';
      }
      if (limit != null) {
        actions.add(
          AppButton(
            key: CartKeys.discountApplyLimit,
            label: l10n.cart_discount_apply_limit(CartFormats.percent(limit)),
            variant: AppButtonVariant.tonal,
            size: AppButtonSize.s,
            loading: s.isBusy(CartOp.discount),
            onPressed: () => unawaited(_applyLimit(limit)),
          ),
        );
      }
      if (_canApproveDiscount(server, rej)) {
        actions.add(
          AppButton(
            key: CartKeys.discountApprove,
            label: l10n.cart_discount_approve_button(CartFormats.percent(rej.requested)),
            variant: AppButtonVariant.tonal,
            size: AppButtonSize.s,
            loading: s.isBusy(CartOp.discount),
            onPressed: offline ? null : () => unawaited(_approveDiscount(rej.requested)),
          ),
        );
      } else if (!rej.overCeiling && _canPark()) {
        actions.add(
          AppButton(
            key: CartKeys.discountHow,
            label: l10n.cart_discount_approval_how,
            variant: AppButtonVariant.text,
            size: AppButtonSize.s,
            onPressed: () async {
              final bool park = await showDiscountApprovalDialog(
                context,
                limit: limit == null ? '—' : CartFormats.percent(limit),
              );
              if (park && mounted) await _park();
            },
          ),
        );
      }
    }
    final bool error = message != null && (rej != null || _discountError != null);
    return DiscountInput(
      label: l10n.cart_discount_label,
      controller: _discount,
      focusNode: _discountFocus,
      amount: server.discountTotal,
      limitTooltip: server.discountLimitPercent == null
          ? null
          : l10n.cart_discount_limit_tooltip(CartFormats.percent(server.discountLimitPercent!)),
      state: s.isBusy(CartOp.discount)
          ? DiscountInputState.loading
          : (error ? DiscountInputState.error : DiscountInputState.normal),
      message: message,
      actions: actions,
      enabled: !offline,
      onChanged: _onDiscountChanged,
      onSubmitted: _onDiscountSubmitted,
    );
  }

  /// Право на «Отложить» (эскалация скидки через откладывание — только при наличии кнопки).
  bool _canPark() => cartPermissionsFor(ref.read(cartViewerRoleProvider)).canPark;

  Widget _line(
    AppLocalizations l10n,
    DsColors c,
    CartLineView line, {
    required bool selected,
    required bool dense,
    required bool offline,
    required CartPermissions can,
  }) {
    final String unit = line.unitLabel ?? '';
    final List<String> meta = <String>[
      if (line.sku != null) l10n.catalog_card_sku(line.sku!),
      if (line.unitPrice != null) '${PriceText.format(line.unitPrice!)} ${l10n.product_price_unit(unit)}'.trim(),
    ];
    ds.CartLineTone tone = ds.CartLineTone.normal;
    String? message;
    final List<Widget> actions = <Widget>[];
    if (line.unavailable) {
      tone = ds.CartLineTone.unavailable;
      message = l10n.cart_line_unavailable;
      actions.add(
        AppButton(
          label: l10n.cart_line_remove_unavailable,
          variant: AppButtonVariant.text,
          size: AppButtonSize.s,
          onPressed: () => _remove(line),
        ),
      );
    } else if (line.stockInsufficient) {
      tone = ds.CartLineTone.error;
      final Qty? target = line.reduceTarget;
      if (line.available == null) {
        // Клиент при `customer_stock_display=status` — без чисел (AC-UI-20-030; `cart_line_stock_short_customer`,
        // 03 §16.8, FQ-CART-06).
        message = l10n.cart_line_stock_short_customer;
      } else {
        message = l10n.cart_line_stock_available(CartFormats.qty(line.available!), unit);
      }
      if (target != null) {
        actions.add(
          AppButton(
            key: CartKeys.reduce(line.key),
            label: l10n.cart_line_reduce_to(CartFormats.qty(target)),
            variant: AppButtonVariant.text,
            size: AppButtonSize.s,
            onPressed: offline ? null : () => unawaited(_reduce(line)),
          ),
        );
      }
    } else if (line.priceChanged && line.oldPrice != null && line.newPrice != null) {
      tone = ds.CartLineTone.warning;
      message = l10n.cart_line_price_changed(PriceText.format(line.newPrice!), PriceText.formatAmount(line.oldPrice!));
    } else if (line.failed) {
      tone = ds.CartLineTone.error;
      message = l10n.cart_save_state_failed;
    }
    final Widget stepper = QuantityStepper(
      value: CartFormats.qty(line.quantity),
      unit: unit.isEmpty ? null : unit,
      size: dense ? QuantityStepperSize.sm : QuantityStepperSize.md,
      increaseLabel: l10n.ds_qty_increase_a11y,
      decreaseLabel: l10n.ds_qty_decrease_a11y,
      error: line.stockInsufficient,
      onIncrement: line.canIncrement ? () => unawaited(_cart.increment(line)) : null,
      onDecrement: line.unavailable ? null : () => unawaited(_decrement(line)),
      onValueTap: line.unavailable ? null : () => unawaited(_numpad(line)),
    );
    final String? productId = line.productId;
    // UI-20-007: «Вариант» — только у товара с вариантами (подпись варианта есть) и при наличии порта SCR-15;
    // офлайн и при блокировке UI-20-020 — disabled (смена — онлайн-операция, CART-005).
    final CartVariantPicker? picker = ref.watch(cartVariantPickerProvider);
    final bool variantChangeable = picker != null && productId != null && line.variantName != null && !line.unavailable;
    Widget tile = ds.CartLine(
      key: CartKeys.line(line.key),
      title: line.title,
      variantLabel: line.variantName,
      variantActionLabel: variantChangeable ? l10n.variant_replace_cta : null,
      onVariantTap:
          variantChangeable &&
              !offline &&
              line.unitId != null &&
              !_locked &&
              !ref.watch(cartControllerProvider).isBusy(CartOp.variant)
          ? () => unawaited(_changeVariant(line, picker))
          : null,
      subtitle: meta.isEmpty ? null : meta.join(' · '),
      imageUrl: line.imageUrl,
      quantity: stepper,
      lineTotal: line.preliminary ? (line.serverQuantity == null ? null : line.lineTotal) : line.lineTotal,
      preliminary: line.preliminary,
      pending: line.pending && !offline,
      tone: tone,
      message: message,
      actions: actions,
      onOpen: productId == null
          ? null
          : () =>
                unawaited(GoRouter.of(context).push<void>(CartPaths.product(productId, variantId: line.key.variantId))),
      onRemove: () => _remove(line),
      removeLabel: l10n.qty_delete,
      selected: selected,
      dense: dense,
    );
    if (widget.variant != CartPanelVariant.panel) {
      // Свайп удаления на тач-экранах (UI-20-018, A11Y-017).
      tile = Dismissible(
        key: ValueKey<String>('swipe-${line.key.variantId}-${line.key.packagingId ?? ''}'),
        direction: DismissDirection.endToStart,
        dismissThresholds: _swipeThresholds,
        background: Container(
          color: c.error,
          alignment: AlignmentDirectional.centerEnd,
          padding: EdgeInsetsDirectional.only(end: context.space.s5),
          child: Icon(Icons.delete_outline_rounded, color: c.onError),
        ),
        onDismissed: (_) => _remove(line),
        child: tile,
      );
    }
    return tile;
  }
}

/// Доля ширины строки (не деньги).
typedef _Fraction = double; // money-double: allow — доля ширины жеста

/// Порог свайпа удаления — 40 % ширины (UI-20-018).
const Map<DismissDirection, _Fraction> _swipeThresholds = <DismissDirection, _Fraction>{
  DismissDirection.endToStart: 0.4,
};

/// Бейдж «Отложенные (n)» (`surfaceVariant`/`textPrimary`).
class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Container(
      constraints: const BoxConstraints(minWidth: 18),
      height: 18,
      padding: const EdgeInsets.symmetric(horizontal: 5),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.surfaceVariant, borderRadius: BorderRadius.all(context.radii.full)),
      child: Text(
        count > 99 ? '99+' : '$count',
        textScaler: TextScaler.noScaling,
        style: context.text.micro.copyWith(color: c.textPrimary, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Баннер зоны C (UI-20-012): иконка + текст + действие (A11Y-004).
class _CartBanner extends StatelessWidget {
  const _CartBanner({
    required this.tone,
    required this.icon,
    required this.text,
    this.actionLabel,
    this.onAction,
    this.actionLoading = false,
  });

  final ErrorStateTone tone;
  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool actionLoading;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final (Color bg, Color fg) = switch (tone) {
      ErrorStateTone.warning => (c.warningContainer, c.warning),
      ErrorStateTone.error => (c.errorContainer, c.error),
      ErrorStateTone.success => (c.successContainer, c.success),
      ErrorStateTone.info => (c.infoContainer, c.info),
    };
    final Widget content = Container(
      key: CartKeys.banner,
      color: bg,
      padding: EdgeInsets.symmetric(horizontal: context.space.s4, vertical: context.space.s3),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 20, color: fg),
          SizedBox(width: context.space.s2),
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(text, style: context.text.body.copyWith(color: c.textPrimary)),
            ),
          ),
          if (actionLabel != null) ...<Widget>[
            SizedBox(width: context.space.s2),
            AppButton(
              key: CartKeys.bannerAction,
              label: actionLabel!,
              variant: AppButtonVariant.tonal,
              size: AppButtonSize.s,
              loading: actionLoading,
              onPressed: onAction,
            ),
          ],
        ],
      ),
    );
    if (actionLabel == null && onAction != null) {
      return InkWell(onTap: onAction, child: content);
    }
    return content;
  }
}

/// Ширина side sheet корзины на medium (02 SCR-20.2: 320).
const double cartOverlayWidth = DsBreakpoints.cartNarrow; // money-double: allow — геометрия UI (lp)

/// Блокировка без оверлея корня: фон `surface` 0,9 и индикатор (UI-20-020).
class _LockFallback extends StatelessWidget {
  const _LockFallback();

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.colors.surface.withValues(alpha: 0.9),
    child: const Center(child: AppProgress.circular(size: 32)),
  );
}
