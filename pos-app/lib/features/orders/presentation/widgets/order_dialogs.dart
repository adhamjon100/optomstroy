// Диалоги SCR-24: отмена / запрос отмены (UI-24-017; 10 ORD-050…053, ядро §22.9) и ручная привязка к документу
// 1С (UI-24-022; ядро §19.2, §23 п.1–2). Общее: ширина 480, фокус по умолчанию — на безопасной кнопке,
// `Esc` закрывает без действия; CTA в `loading`, повторные нажатия игнорируются; `Idempotency-Key` создаётся при
// первом подтверждении и переиспользуется при повторе из того же диалога (ORD-053, AC-UI-24-016); ошибка запроса —
// текст под кнопками, диалог остаётся (ANIM-023).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/error_texts.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_radio.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/category_chip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/presentation/orders_format.dart';
import 'package:uuid/uuid.dart';

/// Новый `Idempotency-Key` (UUID v4, 08 §2.7).
String newOrderIdempotencyKey() => const Uuid().v4();

/// Отправка из диалога: тело и ключ → результат.
typedef OrderCancelSubmit = Future<Result<Order>> Function(OrderCancelRequest request, String idempotencyKey);

/// Отправка привязки к 1С.
typedef OrderOnecLinkSubmit = Future<Result<Order>> Function(OrderOnecLinkRequest request, String idempotencyKey);

/// Итог диалога: заказ после `200` или ошибка, закрывшая диалог (`409 ORDER_STATE_INVALID` — экран обновляется).
typedef OrderDialogOutcome = ({Order? order, Failure? failure});

Future<OrderDialogOutcome?> _showOrderDialog(BuildContext context, Widget dialog) {
  final DsColors c = context.colors;
  return showGeneralDialog<OrderDialogOutcome>(
    context: context,
    barrierDismissible: false,
    barrierLabel: AppLocalizations.of(context).ds_button_cancel,
    barrierColor: c.overlay,
    transitionDuration: context.motion.of(const Duration(milliseconds: 250)),
    pageBuilder: (_, _, _) => dialog,
    transitionBuilder: (_, a, _, child) {
      final CurvedAnimation curve = CurvedAnimation(parent: a, curve: context.motion.standard);
      return FadeTransition(
        opacity: curve,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1).animate(curve), // money-double: allow — масштаб
          child: child,
        ),
      );
    },
  );
}

/// `ORDER_STATE_INVALID` / `PAYMENT_STATE_INVALID` / `404` закрывают диалог — экран перечитывает заказ.
bool _closesDialog(Failure f) =>
    (f is ConflictFailure &&
        (f.kind == ConflictKind.orderStateInvalid || f.kind == ConflictKind.paymentStateInvalid)) ||
    (f is ServerFailure && f.status == 404) ||
    f is PermissionFailure;

/// Каркас диалога 480: заголовок `title`, тело, ошибка, кнопки справа.
class _DialogFrame extends StatelessWidget {
  const _DialogFrame({required this.title, required this.children, required this.actions, this.error});

  final String title;
  final List<Widget> children;
  final List<Widget> actions;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(context.space.s4),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Material(
            color: c.surface,
            elevation: 3,
            borderRadius: BorderRadius.all(context.radii.lg),
            child: SingleChildScrollView(
              padding: EdgeInsets.all(context.space.s6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(title, style: context.text.h3.copyWith(color: c.textPrimary)),
                  SizedBox(height: context.space.s4),
                  ...children,
                  if (error != null) ...<Widget>[
                    SizedBox(height: context.space.s3),
                    Text(
                      error!,
                      key: const ValueKey<String>('order-dialog-error'),
                      style: context.text.label.copyWith(color: c.error),
                    ),
                  ],
                  SizedBox(height: context.space.s6),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: context.space.s2,
                    runSpacing: context.space.s2,
                    children: actions,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Диалог отмены UI-24-017.
class OrderCancelDialog extends StatefulWidget {
  /// Создаёт диалог.
  const OrderCancelDialog({
    super.key,
    required this.order,
    required this.isRequest,
    required this.withRefundIntent,
    required this.onSubmit,
  });

  /// Заказ.
  final Order order;

  /// «Запросить отмену» (иначе «Отменить заказ»).
  final bool isRequest;

  /// Есть полученные платежи — обязателен выбор «вернуть / оставить авансом» (`refundIntent`, Q-012).
  final bool withRefundIntent;

  /// Отправка.
  final OrderCancelSubmit onSubmit;

  /// Показать; `null` — «Не отменять».
  static Future<OrderDialogOutcome?> show(
    BuildContext context, {
    required Order order,
    required bool isRequest,
    required bool withRefundIntent,
    required OrderCancelSubmit onSubmit,
  }) => _showOrderDialog(
    context,
    OrderCancelDialog(order: order, isRequest: isRequest, withRefundIntent: withRefundIntent, onSubmit: onSubmit),
  );

  /// Предельная длина причины (08 `OrdersCancelRequest.reason`).
  static const int reasonMaxLength = 500;

  @override
  State<OrderCancelDialog> createState() => _OrderCancelDialogState();
}

class _OrderCancelDialogState extends State<OrderCancelDialog> {
  final TextEditingController _reason = TextEditingController();
  final FocusNode _keepFocus = FocusNode();
  CancelReasonCode? _code;
  RefundIntent? _refund;
  String? _key;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _keepFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _reason.dispose();
    _keepFocus.dispose();
    super.dispose();
  }

  bool get _valid => _code != null && _reason.text.trim().isNotEmpty && (!widget.withRefundIntent || _refund != null);

  Future<void> _submit() async {
    if (_busy || !_valid) return;
    final AppLocalizations l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    final String key = _key ??= newOrderIdempotencyKey();
    final Result<Order> r = await widget.onSubmit(
      OrderCancelRequest(
        reason: _reason.text.trim(),
        reasonCode: _code!,
        refundIntent: widget.withRefundIntent ? _refund : null,
      ),
      key,
    );
    if (!mounted) return;
    switch (r) {
      case Success<Order>(:final Order value):
        Navigator.of(context).pop<OrderDialogOutcome>((order: value, failure: null));
      case FailureResult<Order>(:final Failure failure):
        if (_closesDialog(failure)) {
          Navigator.of(context).pop<OrderDialogOutcome>((order: null, failure: failure));
          return;
        }
        setState(() {
          _busy = false;
          _error = ErrorTexts.message(l10n, UiErrorMapper.fromFailure(failure));
        });
    }
  }

  String _reasonLabel(AppLocalizations l10n, CancelReasonCode c) => switch (c) {
    CancelReasonCode.customerRefused => l10n.order_cancel_reason_customer_refused,
    CancelReasonCode.duplicate => l10n.order_cancel_reason_duplicate,
    CancelReasonCode.error => l10n.order_cancel_reason_error,
    CancelReasonCode.other => l10n.order_cancel_reason_other,
  };

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String cta = widget.isRequest ? l10n.order_action_cancel_request : l10n.order_action_cancel;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (!_busy) Navigator.of(context).pop();
        },
      },
      child: _DialogFrame(
        title: l10n.order_cancel_dialog_title(widget.order.publicNumber),
        error: _error,
        actions: <Widget>[
          AppButton(
            key: const ValueKey<String>('cancel-keep'),
            label: OrdersTexts.keepOrder(l10n),
            variant: AppButtonVariant.text,
            focusNode: _keepFocus,
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
          ),
          AppButton(
            key: const ValueKey<String>('cancel-confirm'),
            label: cta,
            variant: AppButtonVariant.danger,
            loading: _busy,
            onPressed: _valid && !_busy ? _submit : null,
          ),
        ],
        children: <Widget>[
          Wrap(
            spacing: context.space.s2,
            children: <Widget>[
              for (final CancelReasonCode c in CancelReasonCode.values)
                CategoryChip(
                  key: ValueKey<String>('cancel-reason-${c.value}'),
                  label: _reasonLabel(l10n, c),
                  selected: _code == c,
                  enabled: !_busy,
                  onTap: () => setState(() => _code = c),
                ),
            ],
          ),
          SizedBox(height: context.space.s3),
          AppTextField(
            key: const ValueKey<String>('cancel-reason-text'),
            controller: _reason,
            label: OrdersTexts.reason(l10n),
            variant: AppTextFieldVariant.multiline,
            maxLength: OrderCancelDialog.reasonMaxLength,
            enabled: !_busy,
            helper: _reason.text.trim().isEmpty ? l10n.order_cancel_reason_required : null,
            onChanged: (_) => setState(() {}),
          ),
          if (widget.withRefundIntent) ...<Widget>[
            SizedBox(height: context.space.s3),
            AppRadio<RefundIntent>(
              key: const ValueKey<String>('cancel-refund'),
              value: RefundIntent.refund,
              groupValue: _refund,
              label: l10n.order_cancel_money_refund,
              onChanged: _busy ? null : (RefundIntent v) => setState(() => _refund = v),
            ),
            AppRadio<RefundIntent>(
              key: const ValueKey<String>('cancel-advance'),
              value: RefundIntent.advance,
              groupValue: _refund,
              label: l10n.order_cancel_money_advance,
              onChanged: _busy ? null : (RefundIntent v) => setState(() => _refund = v),
            ),
          ],
        ],
      ),
    );
  }
}

/// Диалог привязки к документу 1С UI-24-022: номер документа 1С (кандидатов в DTO 08 нет — ввод номера, Q-263)
/// и причина ≥ 5 символов; «Привязать» → step-up → `POST /orders/{id}/onec-link`.
class OrderOnecLinkDialog extends StatefulWidget {
  /// Создаёт диалог.
  const OrderOnecLinkDialog({super.key, required this.order, required this.onSubmit});

  /// Заказ.
  final Order order;

  /// Отправка (step-up — внутри [onSubmit]).
  final OrderOnecLinkSubmit onSubmit;

  /// Причина — не короче (02 UI-24-022).
  static const int reasonMinLength = 5;

  /// Показать; `null` — «Отмена».
  static Future<OrderDialogOutcome?> show(
    BuildContext context, {
    required Order order,
    required OrderOnecLinkSubmit onSubmit,
  }) => _showOrderDialog(context, OrderOnecLinkDialog(order: order, onSubmit: onSubmit));

  @override
  State<OrderOnecLinkDialog> createState() => _OrderOnecLinkDialogState();
}

class _OrderOnecLinkDialogState extends State<OrderOnecLinkDialog> {
  final TextEditingController _number = TextEditingController();
  final TextEditingController _reason = TextEditingController();
  final FocusNode _cancelFocus = FocusNode();
  String? _key;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _cancelFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _number.dispose();
    _reason.dispose();
    _cancelFocus.dispose();
    super.dispose();
  }

  bool get _valid {
    final String n = _number.text.trim();
    return n.isNotEmpty && n.length <= 32 && _reason.text.trim().length >= OrderOnecLinkDialog.reasonMinLength;
  }

  Future<void> _submit() async {
    if (_busy || !_valid) return;
    final AppLocalizations l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    final String key = _key ??= newOrderIdempotencyKey();
    final Result<Order> r = await widget.onSubmit(
      OrderOnecLinkRequest(onecNumber: _number.text.trim(), reason: _reason.text.trim()),
      key,
    );
    if (!mounted) return;
    switch (r) {
      case Success<Order>(:final Order value):
        Navigator.of(context).pop<OrderDialogOutcome>((order: value, failure: null));
      case FailureResult<Order>(:final Failure failure):
        if (_closesDialog(failure)) {
          Navigator.of(context).pop<OrderDialogOutcome>((order: null, failure: failure));
          return;
        }
        setState(() {
          _busy = false;
          _error = ErrorTexts.message(l10n, UiErrorMapper.fromFailure(failure));
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (!_busy) Navigator.of(context).pop();
        },
      },
      child: _DialogFrame(
        title: l10n.order_onec_link_title,
        error: _error,
        actions: <Widget>[
          AppButton(
            key: const ValueKey<String>('onec-link-cancel'),
            label: l10n.ds_button_cancel,
            variant: AppButtonVariant.text,
            focusNode: _cancelFocus,
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
          ),
          AppButton(
            key: const ValueKey<String>('onec-link-confirm'),
            label: l10n.order_onec_link_confirm,
            loading: _busy,
            onPressed: _valid && !_busy ? _submit : null,
          ),
        ],
        children: <Widget>[
          Text(
            l10n.order_onec_link_body(widget.order.publicNumber),
            style: context.text.body.copyWith(color: c.textSecondary),
          ),
          SizedBox(height: context.space.s3),
          AppTextField(
            key: const ValueKey<String>('onec-link-number'),
            controller: _number,
            label: l10n.order_onec_link_number,
            maxLength: 32,
            enabled: !_busy,
            onChanged: (_) => setState(() {}),
          ),
          SizedBox(height: context.space.s3),
          AppTextField(
            key: const ValueKey<String>('onec-link-reason'),
            controller: _reason,
            label: l10n.order_onec_link_reason,
            variant: AppTextFieldVariant.multiline,
            maxLength: 500,
            enabled: !_busy,
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
    );
  }
}
