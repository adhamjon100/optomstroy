// SCR-39 «Заявка на возврат» (`/returns/new?orderId=` — создание, `/returns/{id}` — черновик/просмотр; 02 SCR-39;
// 10 RET-001…013, CASH-007, D-25; ядро §21 п. 1, §22.11, §23 п. 8). Владелец реализации — агент G-fe-returns
// (RM-G-007, RM-G-012). Имя класса и параметры конструктора фиксированы маршрутом основы (`app/router/routes.dart`).
//
// Раскладки 02 SCR-39.2: compact — полноэкранный маршрут (Z1 → Z2 → Z3 → Z4, закреплённые кнопки Z5); medium —
// «диалог» 640 поверх затемнения (одна колонка, шапка 56 с крестиком, нижняя полоса 72); expanded/large — 720×680:
// слева 60 % (Z1 + Z2), справа 40 % (Z3 + Z4 + Z5). Маршрут основы — обычная страница, поэтому подложкой служит
// `overlay`, а не экран-родитель (GQ-FERET-06). Режим просмотра — Z6 (статус и статус-линия), у держателя
// `return.approve` — «Согласовать» / «Отклонить». Модуль выключен сервером — «Возвраты оформляются в 1С» (RET-012).
// Документ возврата, приход на склад и деньги — только в 1С: действия «вернуть деньги» в приложении нет (AC-UI-39-008).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/error_texts.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/returns/domain/entities/return_request.dart';
import 'package:optomstroy/features/returns/presentation/providers/returns_ports.dart';
import 'package:optomstroy/features/returns/presentation/returns_format.dart';
import 'package:optomstroy/features/returns/presentation/state/return_request_controller.dart';
import 'package:optomstroy/features/returns/presentation/state/return_request_state.dart';
import 'package:optomstroy/features/returns/presentation/widgets/return_dialogs.dart';
import 'package:optomstroy/features/returns/presentation/widgets/return_sections.dart';

/// SCR-39. Заявка на возврат `/returns/new?orderId=`, `/returns/{id}` (видимость — `features.returnsFromPos`).
class ReturnRequestScreen extends ConsumerStatefulWidget {
  /// Экран SCR-39.
  const ReturnRequestScreen({this.orderId, this.returnId, super.key});

  /// ID экрана (02 §4.1).
  static const String screenId = 'SCR-39';

  /// Ключ корня экрана.
  static const ValueKey<String> rootKey = ValueKey<String>('stub-SCR-39');

  /// Ключи действий (тесты).
  static const ValueKey<String> saveKey = ValueKey<String>('return-save');
  static const ValueKey<String> submitKey = ValueKey<String>('return-submit');
  static const ValueKey<String> deleteKey = ValueKey<String>('return-delete');
  static const ValueKey<String> acceptKey = ValueKey<String>('return-accept');
  static const ValueKey<String> rejectKey = ValueKey<String>('return-reject');
  static const ValueKey<String> closeKey = ValueKey<String>('return-close');
  static const ValueKey<String> hintKey = ValueKey<String>('return-actions-hint');

  /// Новая заявка по заказу (`/returns/new?orderId=`).
  final String? orderId;

  /// Просмотр/правка заявки (`/returns/{id}`).
  final String? returnId;

  @override
  ConsumerState<ReturnRequestScreen> createState() => _ReturnRequestScreenState();
}

class _ReturnRequestScreenState extends ConsumerState<ReturnRequestScreen> {
  final TextEditingController _comment = TextEditingController();
  bool _leaving = false;
  bool _listening = false;

  ReturnScreenArgs get _args => ReturnScreenArgs(orderId: widget.orderId, returnId: widget.returnId);

  ReturnRequestController get _ctrl => ref.read(returnRequestProvider(_args).notifier);

  ReturnFormState get _state => ref.read(returnRequestProvider(_args));

  /// Комментарий формы ← состояние (загрузка, перечитывание после конфликта версии); ввод идёт обратно через
  /// `setComment`, поэтому совпадающий текст не перезаписывается. Подписка — только когда модуль включён (иначе
  /// контроллер не создаётся и запросов нет, AC-UI-39-010).
  void _listenComment() {
    if (_listening) return;
    _listening = true;
    ref.listenManual<String>(returnRequestProvider(_args).select((ReturnFormState v) => v.comment), (
      String? previous,
      String next,
    ) {
      if (_comment.text != next) _comment.text = next;
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  bool _editable(ReturnFormState s, ReturnsViewer viewer) => s.phase == ReturnPhase.editing && viewer.canCreate;

  // --- Действия -------------------------------------------------------------------------------------------------

  void _snack(String message, {AppSnackbarVariant variant = AppSnackbarVariant.info}) {
    if (!mounted) return;
    AppSnackbar.show(context, message: message, variant: variant);
  }

  String _failureText(Failure? f) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    if (f == null) return l10n.error_internal;
    return ErrorTexts.message(l10n, UiErrorMapper.fromFailureDetailed(f));
  }

  /// Реакция экрана на итог действия (снекбары, переходы — 02 SCR-39.4).
  void _handle(ReturnActionResult r) {
    if (!mounted) return;
    final AppLocalizations l10n = AppLocalizations.of(context);
    switch (r.outcome) {
      case ReturnOutcome.created:
        _snack(l10n.return_draft_saved, variant: AppSnackbarVariant.success);
        _replaceWithSaved();
      case ReturnOutcome.saved:
        _snack(l10n.return_draft_saved, variant: AppSnackbarVariant.success);
      case ReturnOutcome.submitted:
        _snack(l10n.return_submitted, variant: AppSnackbarVariant.success);
        _replaceWithSaved();
      case ReturnOutcome.thresholdBlocked:
        _replaceWithSaved();
      case ReturnOutcome.versionConflict:
        _snack(l10n.return_version_conflict);
      case ReturnOutcome.accepted:
        _snack(l10n.return_accepted, variant: AppSnackbarVariant.success);
      case ReturnOutcome.rejected:
        _snack(l10n.return_rejected_done, variant: AppSnackbarVariant.success);
      case ReturnOutcome.deleted:
        _snack(l10n.return_deleted, variant: AppSnackbarVariant.success);
        _close(force: true);
      case ReturnOutcome.forbidden:
        _snack(l10n.error_forbidden, variant: AppSnackbarVariant.error);
      case ReturnOutcome.qtyExceeded || ReturnOutcome.stateChanged || ReturnOutcome.failed:
        _snack(_failureText(r.failure), variant: AppSnackbarVariant.error);
      case ReturnOutcome.ignored ||
          ReturnOutcome.invalid ||
          ReturnOutcome.stepUpCancelled ||
          ReturnOutcome.notReturnable ||
          ReturnOutcome.unknown ||
          ReturnOutcome.alreadyInOnec:
        break;
    }
  }

  /// `/returns/new?orderId=` → `/returns/{id}` (`replace`) после первого сохранения; состояние передаётся без
  /// перезагрузки ([ReturnsHandoff]).
  void _replaceWithSaved() {
    final String? id = _state.request?.id;
    if (widget.returnId != null || id == null || GoRouter.maybeOf(context) == null) return;
    ref.read(returnsHandoffProvider).put(id, _state);
    context.returnsReplace(ReturnsLocations.returnRequest(id));
  }

  Future<void> _save() async => _handle(await _ctrl.saveDraft());

  Future<void> _submit() async => _handle(await _ctrl.submit());

  Future<void> _retryPending() async => _handle(await _ctrl.retryPending());

  Future<void> _delete() async {
    final ReturnFormState s = _state;
    if (s.busy != null) return;
    final bool ok = await ReturnDialogs.delete(context, orderNumber: s.order?.publicNumber ?? '—');
    if (!ok || !mounted) return;
    _handle(await _ctrl.deleteDraft());
  }

  Future<void> _accept() async {
    if (_state.busy != null) return;
    if (!await ReturnDialogs.accept(context) || !mounted) return;
    _handle(await _ctrl.accept());
  }

  Future<void> _reject() async {
    if (_state.busy != null) return;
    final String? reason = await ReturnDialogs.reject(context);
    if (reason == null || !mounted) return;
    _handle(await _ctrl.reject(reason));
  }

  Future<void> _editQty(ReturnLine line) async {
    final Qty? q = await ReturnDialogs.quantity(context, line);
    if (q == null || !mounted) return;
    _ctrl.setQty(line.orderLineNo, q);
  }

  // --- Выход ----------------------------------------------------------------------------------------------------

  bool _guardsLeave(ReturnFormState s, ReturnsViewer viewer) => !_leaving && s.dirty && _editable(s, viewer);

  /// «Назад» / крестик / Esc: при несохранённых изменениях — «Выйти без сохранения?» (02 SCR-39.6).
  Future<void> _requestClose({String? goTo}) async {
    final ReturnFormState s = _state;
    final ReturnsViewer viewer = ref.read(returnsViewerProvider);
    if (_guardsLeave(s, viewer)) {
      final bool canSave = s.formComplete && ref.read(returnsOnlineProvider);
      final ReturnLeaveChoice choice = await ReturnDialogs.leave(context, canSave: canSave);
      if (!mounted) return;
      switch (choice) {
        case ReturnLeaveChoice.stay:
          return;
        case ReturnLeaveChoice.save:
          final ReturnActionResult r = await _ctrl.saveDraft();
          if (!mounted) return;
          if (r.outcome != ReturnOutcome.saved && r.outcome != ReturnOutcome.created) {
            _handle(r);
            return;
          }
          _snack(AppLocalizations.of(context).return_draft_saved, variant: AppSnackbarVariant.success);
        case ReturnLeaveChoice.leave:
          break;
      }
    }
    if (goTo != null) {
      setState(() => _leaving = true);
      context.returnsGo(goTo);
      return;
    }
    _close(force: true);
  }

  void _close({bool force = false}) {
    if (force) setState(() => _leaving = true);
    final String? orderId = _state.order?.id ?? _state.request?.orderId ?? widget.orderId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.returnsClose(orderId: orderId);
    });
  }

  // --- Построение -----------------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    if (ref.watch(returnsScreenDisabledProvider)) {
      return _frame(
        context,
        title: l10n.return_title_new,
        body: Center(
          child: EmptyState(variant: EmptyStateVariant.orders, title: l10n.return_disabled),
        ),
      );
    }
    _listenComment();
    final ReturnFormState s = ref.watch(returnRequestProvider(_args));
    final ReturnsViewer viewer = ref.watch(returnsViewerProvider);
    final bool online = ref.watch(returnsOnlineProvider);

    final String title = s.request == null
        ? l10n.return_title_new
        : l10n.return_title_view(s.request!.publicNumber ?? '—');
    final Widget content = switch (s.phase) {
      ReturnPhase.loading => const ReturnSkeleton(),
      ReturnPhase.notReturnable => Center(
        child: EmptyState(
          variant: EmptyStateVariant.orders,
          title: l10n.return_not_returnable,
          actionLabel: widget.orderId == null ? null : l10n.transaction_details_action_open_order,
          onAction: widget.orderId == null ? null : () => context.returnsGo(ReturnsLocations.order(widget.orderId!)),
        ),
      ),
      ReturnPhase.notFound => Center(
        child: EmptyState(variant: EmptyStateVariant.search, title: l10n.return_not_found),
      ),
      ReturnPhase.offlineNoData => Center(
        child: EmptyState(
          variant: EmptyStateVariant.offlineNoCache,
          title: l10n.return_offline_no_data,
          actionLabel: l10n.ds_button_retry,
          onAction: () => unawaited(_ctrl.load()),
        ),
      ),
      ReturnPhase.error => ErrorState.fullScreen(
        title: l10n.return_title_new,
        message: _failureText(s.failure),
        requestId: s.failure?.requestId,
        onRetry: () => unawaited(_ctrl.load()),
      ),
      ReturnPhase.editing || ReturnPhase.viewOnly => _form(context, s, viewer, online: online),
    };

    return PopScope(
      canPop: !_guardsLeave(s, viewer),
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) unawaited(_requestClose());
      },
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
            if (_canWrite(s, viewer, online: online)) unawaited(_save());
          },
          const SingleActivator(LogicalKeyboardKey.enter, control: true): () {
            if (_canWrite(s, viewer, online: online)) unawaited(_submit());
          },
          const SingleActivator(LogicalKeyboardKey.escape): () => unawaited(_requestClose()),
        },
        child: Focus(
          autofocus: true,
          child: _frame(context, title: title, body: content, s: s, viewer: viewer),
        ),
      ),
    );
  }

  bool _canWrite(ReturnFormState s, ReturnsViewer viewer, {required bool online}) =>
      _editable(s, viewer) && online && s.busy == null && s.formComplete;

  /// Каркас по классу окна: compact — полноэкранный маршрут; medium+ — «диалог» поверх `overlay`.
  Widget _frame(
    BuildContext context, {
    required String title,
    required Widget body,
    ReturnFormState? s,
    ReturnsViewer? viewer,
  }) {
    final DsColors c = context.colors;
    final WindowClass wc = context.windowClass;
    final bool online = ref.watch(returnsOnlineProvider);
    final Widget? bar = s == null || viewer == null ? null : _actionsBar(context, s, viewer, online: online);
    if (wc == WindowClass.compact) {
      return Scaffold(
        key: ReturnRequestScreen.rootKey,
        backgroundColor: c.background,
        appBar: AppBar(title: Text(title)),
        body: Column(
          children: <Widget>[
            Expanded(child: body),
            ?bar,
          ],
        ),
      );
    }
    final bool expanded = wc == WindowClass.expanded || wc == WindowClass.large;
    final Size screen = MediaQuery.sizeOf(context);
    final AppLocalizations l10n = AppLocalizations.of(context);
    final Widget header = SizedBox(
      height: 56,
      child: Padding(
        padding: EdgeInsetsDirectional.only(start: context.space.s6, end: context.space.s2),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.title.copyWith(color: c.textPrimary),
                ),
              ),
            ),
            AppIconButton(
              key: ReturnRequestScreen.closeKey,
              icon: Icons.close_rounded,
              semanticLabel: l10n.ds_button_close,
              tooltip: l10n.ds_button_close,
              onPressed: () => unawaited(_requestClose()),
            ),
          ],
        ),
      ),
    );
    return Scaffold(
      key: ReturnRequestScreen.rootKey,
      backgroundColor: c.overlay,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(context.space.s6),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: expanded ? 720 : 640,
                maxHeight: expanded ? 680 : screen.height * 0.9,
              ),
              child: Material(
                type: MaterialType.transparency,
                child: Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.all(context.radii.xl),
                    boxShadow: context.elevation.e3,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      header,
                      Divider(height: 1, thickness: 1, color: c.border),
                      Flexible(child: body),
                      if (bar != null && !expanded) ...<Widget>[Divider(height: 1, thickness: 1, color: c.border), bar],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Форма (Editing / ViewOnly).
  Widget _form(BuildContext context, ReturnFormState s, ReturnsViewer viewer, {required bool online}) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final WindowClass wc = context.windowClass;
    final bool compact = wc == WindowClass.compact;
    final bool expanded = wc == WindowClass.expanded || wc == WindowClass.large;
    final bool editable = _editable(s, viewer) && s.busy == null;
    final ReturnRequest? request = s.request;

    final List<Widget> banners = <Widget>[
      if (request?.createdBy != null &&
          request!.isDraft &&
          viewer.canApprove &&
          viewer.userId != null &&
          request.createdBy!.id != viewer.userId)
        ErrorState.banner(
          message: l10n.return_foreign_draft(request.createdBy!.displayName),
          tone: ErrorStateTone.info,
        ),
      if (s.thresholdBlocked)
        ErrorState.banner(
          message: l10n.return_threshold,
          tone: ErrorStateTone.warning,
          onClose: _ctrl.dismissThreshold,
        ),
      if (s.alreadyInOnec) ErrorState.banner(message: l10n.return_already_in_onec, tone: ErrorStateTone.warning),
      if (s.pending != null)
        ErrorState.banner(
          message: l10n.return_unknown,
          onRetry: online ? () => unawaited(_retryPending()) : null,
          retrying: s.busy != null,
        ),
      if (_editable(s, viewer) && !online)
        ErrorState.banner(message: l10n.return_offline_hint, tone: ErrorStateTone.info),
    ];

    final Widget source = ReturnSourceCard(
      order: s.order,
      request: request,
      onOpenOrder: s.order == null ? null : () => unawaited(_requestClose(goTo: ReturnsLocations.order(s.order!.id))),
    );
    final Widget items = ReturnZone(
      child: ReturnItemsSection(
        lines: s.lines,
        // Строки в два ряда: compact и узкая левая колонка expanded (60 % от 720).
        compact: compact || expanded,
        callbacks: !editable
            ? null
            : ReturnLineCallbacks(
                onToggle: _ctrl.toggleLine,
                onIncrement: _ctrl.increment,
                onDecrement: _ctrl.decrement,
                onEditQty: (ReturnLine l) => unawaited(_editQty(l)),
                onSelectAll: _ctrl.selectAll,
              ),
      ),
    );
    final Widget reason = ReturnZone(
      child: ReturnReasonSection(
        reason: s.reason,
        commentController: _comment,
        compact: compact,
        commentError: s.commentError,
        onReason: editable ? _ctrl.setReason : null,
        onComment: editable ? _ctrl.setComment : null,
      ),
    );
    final Widget amount = ReturnZone(
      child: ReturnAmountSection(
        total: s.displayTotal,
        refundKind: s.refundKind,
        creditSale: s.order?.paymentMethod == PaymentMethod.credit,
        compact: compact,
        onRefundKind: editable ? _ctrl.setRefundKind : null,
      ),
    );
    final Widget? status = s.phase == ReturnPhase.viewOnly && request != null
        ? ReturnStatusBlock(request: request, rejectReason: s.rejectReason, loadedAt: s.loadedAt)
        : null;

    final EdgeInsets pad = EdgeInsets.all(compact ? context.space.s4 : context.space.s6);
    final SizedBox gap = SizedBox(height: context.space.s4);
    List<Widget> spaced(List<Widget> ws) => <Widget>[
      for (int i = 0; i < ws.length; i++) ...<Widget>[if (i > 0) gap, ws[i]],
    ];

    if (!expanded) {
      return ListView(padding: pad, children: spaced(<Widget>[...banners, ?status, source, items, reason, amount]));
    }
    final Widget? bar = _actionsBar(context, s, viewer, online: online, inColumn: true);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          flex: 6,
          child: ListView(padding: pad, children: spaced(<Widget>[...banners, ?status, source, items])),
        ),
        VerticalDivider(width: 1, thickness: 1, color: context.colors.border),
        Expanded(
          flex: 4,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: ListView(padding: pad, children: spaced(<Widget>[reason, amount])),
              ),
              ?bar,
            ],
          ),
        ),
      ],
    );
  }

  /// Z5 — действия (UI-39-006, UI-39-014) или решение по заявке (UI-39-015/016); `null` — кнопок нет.
  Widget? _actionsBar(
    BuildContext context,
    ReturnFormState s,
    ReturnsViewer viewer, {
    required bool online,
    bool inColumn = false,
  }) {
    if (s.phase != ReturnPhase.editing && s.phase != ReturnPhase.viewOnly) return null;
    final WindowClass wc = context.windowClass;
    final bool expanded = wc == WindowClass.expanded || wc == WindowClass.large;
    if (expanded && !inColumn) return null;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final ReturnRequest? request = s.request;
    final List<Widget> buttons = <Widget>[];
    String? hint;

    if (_editable(s, viewer)) {
      final bool ready = s.formComplete && online && s.busy == null;
      if (!s.hasSelection) {
        hint = l10n.return_items_required;
      } else if (s.reason == null) {
        hint = l10n.return_reason_required;
      } else if (!online) {
        hint = l10n.return_offline_hint;
      }
      if (request != null && request.isDraft) {
        buttons.add(
          AppButton(
            key: ReturnRequestScreen.deleteKey,
            label: l10n.return_delete_draft,
            variant: AppButtonVariant.text,
            loading: s.busy == ReturnBusy.deleting,
            onPressed: online && s.busy == null ? () => unawaited(_delete()) : null,
          ),
        );
      }
      buttons
        ..add(
          AppButton(
            key: ReturnRequestScreen.saveKey,
            label: l10n.return_save_draft,
            variant: AppButtonVariant.outlined,
            loading: s.busy == ReturnBusy.saving,
            onPressed: ready ? () => unawaited(_save()) : null,
          ),
        )
        ..add(
          AppButton(
            key: ReturnRequestScreen.submitKey,
            label: l10n.return_submit,
            loading: s.busy == ReturnBusy.submitting,
            onPressed: ready ? () => unawaited(_submit()) : null,
          ),
        );
    } else if (s.phase == ReturnPhase.viewOnly && request != null && viewer.canApprove && !s.alreadyInOnec) {
      final ReturnRequestStatus? st = request.status;
      final bool idle = online && s.busy == null;
      if (st == ReturnRequestStatus.submitted || st == ReturnRequestStatus.accepted) {
        buttons.add(
          AppButton(
            key: ReturnRequestScreen.rejectKey,
            label: l10n.return_reject,
            variant: AppButtonVariant.outlined,
            loading: s.busy == ReturnBusy.rejecting,
            onPressed: idle ? () => unawaited(_reject()) : null,
          ),
        );
      }
      if (st == ReturnRequestStatus.submitted) {
        buttons.add(
          AppButton(
            key: ReturnRequestScreen.acceptKey,
            label: l10n.return_accept,
            loading: s.busy == ReturnBusy.accepting,
            onPressed: idle ? () => unawaited(_accept()) : null,
          ),
        );
      }
    }
    if (buttons.isEmpty && wc != WindowClass.compact && s.phase == ReturnPhase.viewOnly) {
      buttons.add(
        AppButton(
          label: l10n.ds_button_close,
          variant: AppButtonVariant.outlined,
          onPressed: () => unawaited(_requestClose()),
        ),
      );
    }
    if (buttons.isEmpty) return null;
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        border: wc == WindowClass.compact || inColumn ? Border(top: BorderSide(color: c.border)) : null,
      ),
      padding: EdgeInsets.symmetric(horizontal: context.space.s4, vertical: context.space.s3),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (hint != null) ...<Widget>[
              Text(
                hint,
                key: ReturnRequestScreen.hintKey,
                style: context.text.caption.copyWith(color: c.textSecondary),
              ),
              SizedBox(height: context.space.s2),
            ],
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: context.space.s2,
              runSpacing: context.space.s2,
              children: buttons,
            ),
          ],
        ),
      ),
    );
  }
}
