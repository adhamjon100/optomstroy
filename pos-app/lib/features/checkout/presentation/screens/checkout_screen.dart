// SCR-21 «Оформление заказа» (`/checkout?cartId=&step=`; роли seller, cashier, senior_seller, admin + customer —
// упрощённое «Получение · Оплата · Завершение»). RM-F-006, RM-F-013, RM-F-015; 02 SCR-21; макет IMG_7090.
//
// expanded — модальное окно ≈ 60 % ширины (≤ 1000 lp) поверх затемнения: степпер, колонки «Клиент» / «Получение» /
// «Состав заказа» + печать, «Оплата» под колонками 1–2, футер «Отмена · 🔒 подпись о 1С · Создать заказ…»;
// medium — диалог ≈ 90 % в 2 колонки; compact — 4 (у клиента — 3) последовательных шага.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/error_texts.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_progress.dart';
import 'package:optomstroy/design_system/components/checkout_stepper.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/offline_banner.dart';
import 'package:optomstroy/design_system/layout/window_class.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout_draft.dart';
import 'package:optomstroy/features/checkout/presentation/checkout_formats.dart';
import 'package:optomstroy/features/checkout/presentation/controllers/checkout_controller.dart';
import 'package:optomstroy/features/checkout/presentation/providers/checkout_ports.dart';
import 'package:optomstroy/features/checkout/presentation/widgets/checkout_sections.dart';

/// SCR-21.
class CheckoutScreen extends ConsumerStatefulWidget {
  /// Экран SCR-21.
  const CheckoutScreen({this.cartId, this.step, super.key});

  /// Корзина (`Cart.id`; обязателен по navigation.md §3 — без него экран берёт активную).
  final String? cartId;

  /// Шаг на compact: `customer|delivery|payment|done`.
  final String? step;

  /// Ключ заглушки (тесты маршрутов): `stub-SCR-21`.
  static const ValueKey<String> stubKey = ValueKey<String>('stub-SCR-21');

  /// Ключ CTA «Создать заказ…».
  static const ValueKey<String> ctaKey = ValueKey<String>('checkout-cta');

  /// Ключ «Далее» (compact).
  static const ValueKey<String> nextKey = ValueKey<String>('checkout-next');

  @override
  ConsumerState<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends ConsumerState<CheckoutScreen> {
  final CheckoutFormControllers _form = CheckoutFormControllers();
  final ScrollController _scroll = ScrollController();
  final Map<CheckoutStep, GlobalKey> _anchors = <CheckoutStep, GlobalKey>{
    for (final CheckoutStep s in CheckoutStep.values) s: GlobalKey(debugLabel: 'checkout-${s.value}'),
  };

  CheckoutController get _ctl => ref.read(checkoutControllerProvider(widget.cartId).notifier);

  CheckoutState get _state => ref.read(checkoutControllerProvider(widget.cartId));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_open()));
  }

  @override
  void dispose() {
    _form.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    if (!mounted) return;
    final CheckoutCreated? existing = await _ctl.open();
    if (!mounted) return;
    if (existing != null) {
      ref.read(checkoutNavigatorProvider).orderCreated(context, orderId: existing.orderId);
      return;
    }
    // Маршрут `step` (compact): `done` ↔ `review` (FQ-FND-08).
    final String? routeStep = widget.step;
    if (routeStep != null && _state.piiNotRestored == false) {
      _ctl.goTo(CheckoutStep.parse(routeStep == 'done' ? 'review' : routeStep));
    }
  }

  // -----------------------------------------------------------------------------------------------------------------
  // Действия
  // -----------------------------------------------------------------------------------------------------------------

  /// CTA, `F9`, `Ctrl+Enter`. Недоступная CTA (ошибки полей, идёт предпроверка) всё равно вызывает `submit`:
  /// он подсвечивает ошибки или дожидается предпроверки по текущим выборам — исход обрабатывается всегда.
  Future<void> _submit() async {
    final bool online = ref.read(checkoutOnlineProvider);
    if (!online || _state.submitting) return;
    final CheckoutSubmitOutcome outcome = await _ctl.submit();
    if (!mounted) return;
    await _handleOutcome(outcome);
  }

  Future<void> _handleOutcome(CheckoutSubmitOutcome outcome) async {
    final CheckoutNavigator nav = ref.read(checkoutNavigatorProvider);
    switch (outcome) {
      case CheckoutCreated(:final String orderId, :final String? paymentId):
        nav.orderCreated(context, orderId: orderId, paymentId: paymentId);
      case CheckoutBackToCart():
        nav.backToCart(context, cartId: widget.cartId);
      case CheckoutResultUnknown():
        // Окно закрывается; SCR-20 — оверлей «Проверяем результат создания заказа…» (UI-20-020, 02 SCR-21.4).
        nav.backToCart(context, cartId: widget.cartId);
      case CheckoutStay():
        final CheckoutState s = _state;
        if (s.duplicate != null) {
          await _showDuplicate(s.duplicate!);
        } else if (s.rejectedReason != null) {
          await _showRejected(s.rejectedReason!);
        }
    }
  }

  Future<void> _showDuplicate(CheckoutDuplicate d) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String? choice = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => _ChoiceDialog(
        title: l10n.checkout_duplicate_title,
        message: l10n.checkout_duplicate_body(d.minutes ?? 0, d.number ?? ''),
        actions: <(String, String, AppButtonVariant)>[
          ('cancel', l10n.ds_button_cancel, AppButtonVariant.text),
          if (d.orderId != null) ('open', l10n.checkout_duplicate_open, AppButtonVariant.outlined),
          ('create', l10n.checkout_duplicate_create, AppButtonVariant.primary),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'open':
        _ctl.dismissDuplicate();
        ref.read(checkoutNavigatorProvider).order(context, d.orderId!);
      case 'create':
        final CheckoutSubmitOutcome outcome = await _ctl.createDuplicateAnyway();
        if (mounted) await _handleOutcome(outcome);
      default:
        _ctl.dismissDuplicate();
    }
  }

  Future<void> _showRejected(String reason) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String? choice = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => _ChoiceDialog(
        title: l10n.checkout_rejected_onec(reason),
        message: '',
        actions: <(String, String, AppButtonVariant)>[
          ('cancel', l10n.ds_button_close, AppButtonVariant.text),
          ('cart', l10n.checkout_open_restored_cart, AppButtonVariant.primary),
        ],
      ),
    );
    if (!mounted) return;
    _ctl.dismissSubmitFailure();
    if (choice == 'cart') ref.read(checkoutNavigatorProvider).backToCart(context, cartId: widget.cartId);
  }

  Future<void> _cancel() async {
    final CheckoutState s = _state;
    if (s.submitting) return;
    if (_ctl.hasEnteredData()) {
      final AppLocalizations l10n = AppLocalizations.of(context);
      final bool abort = await ConfirmDialog.show(
        context,
        title: l10n.checkout_abort_title,
        message: l10n.checkout_abort_body,
        confirmLabel: l10n.checkout_abort_confirm,
        cancelLabel: l10n.checkout_abort_continue,
      );
      if (!abort || !mounted) return;
    }
    ref.read(checkoutNavigatorProvider).backToCart(context, cartId: widget.cartId);
  }

  Future<void> _back() async {
    if (_state.submitting) return;
    if (context.windowClass == WindowClass.compact && _ctl.back()) return;
    await _cancel();
  }

  Future<void> _newCustomer() async {
    final String? id = await ref.read(checkoutNavigatorProvider).newCustomer(context);
    if (id != null && mounted) await _ctl.selectCustomer(id);
  }

  Future<void> _creditHelp() async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool park = await ConfirmDialog.show(
      context,
      title: l10n.checkout_credit_how_to_approve,
      message: l10n.checkout_credit_approval_dialog_body,
      confirmLabel: l10n.checkout_credit_approval_park,
      cancelLabel: l10n.checkout_credit_help_ok,
    );
    if (!park || !mounted) return;
    final CheckoutState s = _state;
    final String name = l10n.checkout_credit_parked_name(
      s.customer?.title ?? l10n.checkout_customer_retail_chip,
      CheckoutFormats.time(DateTime.now().toUtc()),
    );
    final bool ok = await _ctl.parkForApproval(name);
    if (ok && mounted) ref.read(checkoutNavigatorProvider).parked(context);
  }

  Future<void> _creditApprove() async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    String? reason;
    final bool ok = await ConfirmDialog.show(
      context,
      title: l10n.checkout_credit_allow,
      message: l10n.checkout_credit_allow_reason_label,
      confirmLabel: l10n.checkout_credit_allow,
      variant: ConfirmDialogVariant.withReason,
      reasonLabel: l10n.checkout_credit_allow_reason_label,
      onConfirm: (String? r) async => reason = r,
    );
    if (!ok || reason == null || !mounted) return;
    await _ctl.approveCredit(reason!);
  }

  Future<void> _pickDate() async {
    final DateTime today = _ctl.today();
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _state.desiredDate ?? today,
      firstDate: today,
      lastDate: today.add(const Duration(days: 60)),
    );
    if (picked != null) _ctl.setDesiredDate(picked);
  }

  void _onStepTap(int index) {
    final CheckoutState s = _state;
    final CheckoutStep step = s.steps[index];
    if (context.windowClass == WindowClass.compact) {
      _ctl.goTo(step);
      return;
    }
    final BuildContext? anchor = _anchors[step]?.currentContext;
    if (anchor != null) unawaited(Scrollable.ensureVisible(anchor, duration: context.motion.of(context.motion.base)));
  }

  // -----------------------------------------------------------------------------------------------------------------
  // Построение
  // -----------------------------------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final CheckoutState s = ref.watch(checkoutControllerProvider(widget.cartId));
    final bool online = ref.watch(checkoutOnlineProvider);
    final CheckoutQrMode qr = ref.watch(checkoutQrModeProvider);
    final List<CheckoutSlot> slots = ref.watch(checkoutDeliverySlotsProvider);
    ref.listen<String>(checkoutControllerProvider(widget.cartId).select((CheckoutState x) => x.courierPhoneText), (
      String? prev,
      String next,
    ) {
      if (_form.courierPhone.text != next && !_form.courierPhoneFocus.hasFocus) _form.courierPhone.text = next;
    });
    ref.listen<ReceiverKind>(checkoutControllerProvider(widget.cartId).select((CheckoutState x) => x.receiverKind), (
      ReceiverKind? prev,
      ReceiverKind next,
    ) {
      if (next == ReceiverKind.customer) {
        _form.receiverName.clear();
        _form.receiverPhone.clear();
      }
    });
    final CheckoutView view = CheckoutView(
      state: s,
      ctl: _ctl,
      form: _form,
      online: online,
      qr: qr,
      slots: slots,
      onNewCustomer: () => unawaited(_newCustomer()),
      onCreditHelp: () => unawaited(_creditHelp()),
      onCreditApprove: () => unawaited(_creditApprove()),
      onBackToCart: () => ref.read(checkoutNavigatorProvider).backToCart(context, cartId: widget.cartId),
      onPickDate: () => unawaited(_pickDate()),
      viewerName: ref.watch(checkoutViewerNameProvider),
    );
    final WindowClass wc = context.windowClass;
    final Widget content = wc == WindowClass.compact ? _compact(context, view) : _dialog(context, view, wc);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) unawaited(_back());
      },
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.enter, control: true): () => unawaited(_submit()),
          const SingleActivator(LogicalKeyboardKey.f9): () => unawaited(_submit()),
          const SingleActivator(LogicalKeyboardKey.escape): () => unawaited(_cancel()),
        },
        child: Focus(autofocus: true, child: content),
      ),
    );
  }

  // ---- служебное ----

  List<CheckoutStepperItem> _stepItems(AppLocalizations l10n, CheckoutState s, {required bool compact}) {
    final List<CheckoutStep> steps = s.steps;
    final int current = steps.indexOf(s.step);
    bool firstOpenFound = false;
    return <CheckoutStepperItem>[
      for (int i = 0; i < steps.length; i++)
        CheckoutStepperItem(
          label: _stepTitle(l10n, steps[i]),
          state: () {
            final bool valid = _ctl.stepValid(steps[i]);
            if (compact) {
              if (i == current) return CheckoutStepState.current;
              if (i < current) return valid ? CheckoutStepState.done : CheckoutStepState.error;
              return CheckoutStepState.upcoming;
            }
            if (valid) return CheckoutStepState.done;
            if (s.showErrors && steps[i] != CheckoutStep.review) return CheckoutStepState.error;
            if (!firstOpenFound) {
              firstOpenFound = true;
              return CheckoutStepState.current;
            }
            return CheckoutStepState.upcoming;
          }(),
        ),
    ];
  }

  static String _stepTitle(AppLocalizations l10n, CheckoutStep s) => switch (s) {
    CheckoutStep.customer => l10n.checkout_step_customer,
    CheckoutStep.delivery => l10n.checkout_step_delivery,
    CheckoutStep.payment => l10n.checkout_step_payment,
    CheckoutStep.review => l10n.checkout_step_done,
  };

  String _ctaLabel(AppLocalizations l10n, CheckoutState s, bool online) {
    if (s.submitting) return l10n.checkout_cta_creating;
    if (!online) return l10n.checkout_cta_offline;
    if (s.customerMode) return l10n.cart_customer_submit;
    return switch (s.paymentMethod) {
      PaymentMethod.qrBakai => s.role == RoleCode.admin ? l10n.checkout_cta_create : l10n.checkout_cta_create_qr,
      PaymentMethod.credit => l10n.checkout_cta_create_credit,
      _ => l10n.checkout_cta_create,
    };
  }

  Widget _cta(AppLocalizations l10n, CheckoutView v, {bool expand = false}) {
    final bool enabled = _ctl.canSubmit(online: v.online);
    return AppButton(
      key: CheckoutScreen.ctaKey,
      label: _ctaLabel(l10n, v.state, v.online),
      icon: Icons.check_rounded,
      variant: AppButtonVariant.success,
      size: AppButtonSize.l,
      expand: expand,
      // Повторная предпроверка / смена клиента — `loading` (02 SCR-21.4).
      loading: v.state.submitting || (v.online && _ctl.isChecking()),
      onPressed: enabled ? () => unawaited(_submit()) : null,
    );
  }

  String _onecNote(AppLocalizations l10n, CheckoutState s) {
    if (s.customerMode) return l10n.checkout_customer_onec_note;
    return s.onecUnavailable ? l10n.checkout_onec_note_offline : l10n.checkout_onec_note;
  }

  Widget _onecNoteRow(BuildContext context, AppLocalizations l10n, CheckoutState s) {
    final DsColors c = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(Icons.lock_outline_rounded, size: 16, color: c.textSecondary),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            _onecNote(l10n, s),
            key: const ValueKey<String>('checkout-onec-note'),
            textAlign: TextAlign.center,
            style: context.text.caption.copyWith(color: c.textSecondary),
          ),
        ),
      ],
    );
  }

  /// Баннеры под степпером: 1С недоступна, сеть, ошибка создания, сводка ошибок полей.
  List<Widget> _banners(BuildContext context, AppLocalizations l10n, CheckoutView v) {
    final CheckoutState s = v.state;
    final int errorCount = s.showErrors ? _ctl.errorsFor().length : 0;
    final Failure? f = s.submitFailure;
    final CheckoutNotificationBannerBuilder? notificationBanner = ref.watch(checkoutNotificationBannerProvider);
    final String? cartId = s.cart?.id;
    return <Widget>[
      if (!v.online) const OfflineBanner(variant: OfflineBannerVariant.offline),
      if (notificationBanner != null && cartId != null) notificationBanner(context, cartId),
      if (s.onecUnavailable && !s.customerMode)
        ErrorState.banner(
          key: const ValueKey<String>('checkout-onec-banner'),
          message: l10n.checkout_onec_unavailable_banner,
          tone: ErrorStateTone.warning,
        ),
      if (f != null && !s.forbiddenPayment)
        ErrorState.banner(
          key: const ValueKey<String>('checkout-submit-error'),
          message: _failureText(l10n, f),
          onRetry: f is NetworkFailure || f is OnecUnavailableFailure ? () => unawaited(_submit()) : null,
          onClose: _ctl.dismissSubmitFailure,
        ),
      if (errorCount >= 2)
        ErrorState.banner(
          key: const ValueKey<String>('checkout-errors-summary'),
          message: l10n.checkout_form_errors_summary(errorCount),
        ),
    ];
  }

  static String _failureText(AppLocalizations l10n, Failure f) {
    if (f is ConflictFailure && f.kind == ConflictKind.idempotencyKeyReused) {
      return l10n.checkout_create_failed(f.requestId ?? '—');
    }
    return ErrorTexts.message(l10n, UiErrorMapper.fromFailure(f));
  }

  Widget _anchor(CheckoutStep step, Widget child) => KeyedSubtree(key: _anchors[step], child: child);

  // ---- expanded / medium ----

  Widget _dialog(BuildContext context, CheckoutView v, WindowClass wc) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final CheckoutState s = v.state;
    final Size size = MediaQuery.sizeOf(context);
    final bool expanded = wc == WindowClass.expanded || wc == WindowClass.large;
    final double w = size.width; // money-double: allow — ширина окна
    final double width = expanded ? (w * .8).clamp(900, 1000) : w * .92; // money-double: allow — ширина окна
    final double maxHeight = size.height * 0.9; // money-double: allow — геометрия UI (ширина окна), не деньги
    const Widget gap = SizedBox(height: 24);
    final Widget customer = _anchor(CheckoutStep.customer, CheckoutCustomerSection(view: v));
    final Widget delivery = _anchor(
      CheckoutStep.delivery,
      CheckoutDeliverySection(view: v, tilesInRow: expanded && s.customerMode),
    );
    final Widget payment = _anchor(CheckoutStep.payment, CheckoutPaymentSection(view: v, tilesInRow: expanded));
    final Widget review = _anchor(
      CheckoutStep.review,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CheckoutItemsSection(view: v),
          if (!s.customerMode) ...<Widget>[gap, CheckoutPrintSection(view: v)],
        ],
      ),
    );
    Widget divider() => const SizedBox(width: 32);
    final Widget body;
    if (s.phase == CheckoutPhase.loadError) {
      body = ErrorState.fullScreen(
        title: l10n.checkout_title,
        message: l10n.error_internal,
        onRetry: () => unawaited(_ctl.reload()),
      );
    } else if (expanded) {
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (!s.customerMode) ...<Widget>[
                      Expanded(
                        child: Container(
                          padding: EdgeInsets.only(right: context.space.s6),
                          decoration: BoxDecoration(
                            border: Border(right: BorderSide(color: c.border)),
                          ),
                          child: customer,
                        ),
                      ),
                      const SizedBox(width: 24),
                    ],
                    Expanded(child: delivery),
                  ],
                ),
                gap,
                Divider(color: c.border, height: 1),
                gap,
                payment,
              ],
            ),
          ),
          divider(),
          Expanded(child: review),
        ],
      );
    } else {
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (!s.customerMode) ...<Widget>[customer, gap],
                delivery,
              ],
            ),
          ),
          divider(),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[payment, gap, review]),
          ),
        ],
      );
    }
    final List<Widget> banners = _banners(context, l10n, v);
    final Widget dialog = Container(
      key: const ValueKey<String>('checkout-dialog'),
      width: width,
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.all(context.radii.lg),
        boxShadow: context.elevation.e3,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // A — шапка и степпер.
          Padding(
            padding: EdgeInsets.fromLTRB(context.space.s6, context.space.s4, context.space.s3, 0),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(l10n.checkout_title, style: context.text.h3.copyWith(color: c.textPrimary)),
                  ),
                ),
                AppIconButton(
                  key: const ValueKey<String>('checkout-close'),
                  icon: Icons.close_rounded,
                  semanticLabel: l10n.ds_button_close,
                  onPressed: s.submitting ? null : () => unawaited(_cancel()),
                ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: context.space.s6),
            child: CheckoutStepper(
              steps: _stepItems(l10n, s, compact: false),
              allClickable: true,
              onStepTap: _onStepTap,
            ),
          ),
          if (s.submitting) const AppProgress.linear(thin: true) else const SizedBox(height: 2),
          for (final Widget b in banners)
            Padding(padding: EdgeInsets.fromLTRB(context.space.s6, context.space.s3, context.space.s6, 0), child: b),
          Flexible(
            child: Stack(
              children: <Widget>[
                AbsorbPointer(
                  absorbing: s.submitting,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    padding: EdgeInsets.all(context.space.s6),
                    child: s.phase == CheckoutPhase.loading
                        ? const Center(child: AppProgress.circular(size: 32))
                        : body,
                  ),
                ),
                if (s.submitting) Positioned.fill(child: _creatingOverlay(context, l10n, s)),
              ],
            ),
          ),
          // G — футер.
          Container(
            height: 72,
            padding: EdgeInsets.symmetric(horizontal: context.space.s6),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.border)),
            ),
            child: Row(
              children: <Widget>[
                AppButton(
                  key: const ValueKey<String>('checkout-cancel'),
                  label: l10n.checkout_cancel,
                  variant: AppButtonVariant.outlined,
                  size: AppButtonSize.l,
                  onPressed: s.submitting ? null : () => unawaited(_cancel()),
                ),
                const SizedBox(width: 16),
                Expanded(child: Center(child: _onecNoteRow(context, l10n, s))),
                const SizedBox(width: 16),
                ConstrainedBox(constraints: const BoxConstraints(minWidth: 280), child: _cta(l10n, v)),
              ],
            ),
          ),
        ],
      ),
    );
    // Окно поверх раскладки SCR-10 (маршрут прозрачный, 02 SCR-21.2): фон — только затемнение `overlay`.
    return Scaffold(
      key: const ValueKey<String>('checkout-screen'),
      backgroundColor: Colors.transparent,
      body: ColoredBox(
        color: c.overlay,
        child: SafeArea(
          child: Center(
            child: Padding(padding: EdgeInsets.all(context.space.s4), child: dialog),
          ),
        ),
      ),
    );
  }

  Widget _creatingOverlay(BuildContext context, AppLocalizations l10n, CheckoutState s) {
    final DsColors c = context.colors;
    return ColoredBox(
      color: c.surface.withValues(alpha: 0.7),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const AppProgress.circular(size: 32),
            const SizedBox(height: 12),
            Text(l10n.checkout_cta_creating, style: context.text.body.copyWith(color: c.textPrimary)),
            if (s.slow)
              Padding(
                padding: EdgeInsets.only(top: context.space.s2),
                child: Text(
                  l10n.checkout_creating_slow,
                  textAlign: TextAlign.center,
                  style: context.text.caption.copyWith(color: c.textSecondary),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ---- compact ----

  Widget _compact(BuildContext context, CheckoutView v) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final CheckoutState s = v.state;
    final List<CheckoutStep> steps = s.steps;
    final int index = steps.indexOf(s.step).clamp(0, steps.length - 1);
    final String title = _stepTitle(l10n, s.step);
    // У клиента 3 шага (SCR-21.1 «Уточнения» п. 1) — `checkout_step_counter_n` с числом шагов (03 §16.8, FQ-CHK-01).
    final String counter = s.customerMode
        ? l10n.checkout_step_counter_n('${index + 1}', title, '${steps.length}')
        : l10n.checkout_step_counter('${index + 1}', title);
    final bool last = index == steps.length - 1;
    final Widget stepBody = switch (s.step) {
      CheckoutStep.customer => CheckoutCustomerSection(view: v),
      CheckoutStep.delivery => CheckoutDeliverySection(view: v, tilesInRow: false),
      CheckoutStep.payment => CheckoutPaymentSection(view: v, tilesInRow: false),
      CheckoutStep.review => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          CheckoutItemsSection(view: v, maxVisibleLines: 1000),
          if (!s.customerMode) ...<Widget>[const SizedBox(height: 24), CheckoutPrintSection(view: v)],
          const SizedBox(height: 16),
          Center(child: _onecNoteRow(context, l10n, s)),
        ],
      ),
    };
    return Scaffold(
      key: const ValueKey<String>('checkout-screen'),
      backgroundColor: c.background,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: c.surface,
        surfaceTintColor: c.surface,
        elevation: 0,
        leading: AppIconButton(
          key: const ValueKey<String>('checkout-back'),
          icon: Icons.arrow_back_rounded,
          semanticLabel: l10n.ds_button_close,
          onPressed: s.submitting ? null : () => unawaited(_back()),
        ),
        title: Text(l10n.checkout_title, style: context.text.title.copyWith(color: c.textPrimary)),
        actions: <Widget>[
          if (last)
            TextButton(
              key: const ValueKey<String>('checkout-cancel'),
              onPressed: s.submitting ? null : () => unawaited(_cancel()),
              child: Text(l10n.checkout_cancel),
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            color: c.surface,
            padding: EdgeInsets.fromLTRB(context.space.s4, 0, context.space.s4, context.space.s2),
            child: CheckoutStepper(
              variant: CheckoutStepperVariant.compact,
              steps: _stepItems(l10n, s, compact: true),
              compactLabel: counter,
              onStepTap: _onStepTap,
            ),
          ),
          if (s.submitting) const AppProgress.linear(thin: true),
          for (final Widget b in _banners(context, l10n, v))
            Padding(padding: EdgeInsets.fromLTRB(context.space.s4, context.space.s2, context.space.s4, 0), child: b),
          Expanded(
            child: Stack(
              children: <Widget>[
                AbsorbPointer(
                  absorbing: s.submitting,
                  child: SingleChildScrollView(
                    padding: EdgeInsets.all(context.space.s4),
                    child: s.phase == CheckoutPhase.loading
                        ? const Center(child: AppProgress.circular(size: 32))
                        : (s.phase == CheckoutPhase.loadError
                              ? ErrorState.fullScreen(
                                  title: l10n.checkout_title,
                                  message: l10n.error_internal,
                                  onRetry: () => unawaited(_ctl.reload()),
                                )
                              : stepBody),
                  ),
                ),
                if (s.submitting) Positioned.fill(child: _creatingOverlay(context, l10n, s)),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Container(
              padding: EdgeInsets.fromLTRB(context.space.s4, context.space.s3, context.space.s4, context.space.s3),
              decoration: BoxDecoration(
                color: c.surface,
                border: Border(top: BorderSide(color: c.border)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  CheckoutTotals(view: v, compact: true),
                  const SizedBox(height: 8),
                  if (last)
                    _cta(l10n, v, expand: true)
                  else
                    AppButton(
                      key: CheckoutScreen.nextKey,
                      label: l10n.checkout_next,
                      size: AppButtonSize.l,
                      expand: true,
                      trailingIcon: Icons.arrow_forward_rounded,
                      onPressed: s.phase == CheckoutPhase.ready ? () => unawaited(_ctl.next()) : null,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Диалог выбора из нескольких действий (UI-21-029 «Похожий заказ», «1С отклонила заказ»).
class _ChoiceDialog extends StatelessWidget {
  const _ChoiceDialog({required this.title, required this.message, required this.actions});

  final String title;
  final String message;
  final List<(String, String, AppButtonVariant)> actions;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Dialog(
      backgroundColor: c.surface,
      surfaceTintColor: c.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(context.radii.lg)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: EdgeInsets.all(context.space.s6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(title, style: context.text.title.copyWith(color: c.textPrimary)),
              if (message.isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                Text(message, style: context.text.body.copyWith(color: c.textSecondary)),
              ],
              const SizedBox(height: 24),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final (String id, String label, AppButtonVariant variant) in actions)
                    AppButton(
                      key: ValueKey<String>('checkout-choice-$id'),
                      label: label,
                      variant: variant,
                      onPressed: () => Navigator.of(context).pop(id),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
