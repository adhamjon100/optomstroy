// Вкладки SCR-43 полного режима (02 SCR-43 зона D; RM-G-008; 04 FLOW-033.S6):
// * «Ошибки» (UI-43-007; `senior_seller`, `admin`, `owner` — `sync.runs.read`): ошибки выбранного прогона
//   (`?runId=` или последний прогон с ошибками по фильтру сущности) — `GET /sync/runs/{id}/errors`; строка — код журнала
//   синхронизации (сам код — описаний кодов в ARB нет), сообщение сервера, код объекта 1С с копированием. «Пометить
//   решённой» — R2 (Q-219).
// * «Outbox» (UI-43-008, UI-43-013, UI-43-015; `admin`, `senior_seller` — `sync.outbox.manage`): `GET /sync/outbox`
//   (по умолчанию `failed`, `dead`; `dead` — по `createdAt` по возрастанию, порядок зависимостей SYNC-042/049);
//   «Повторить» у `failed`/`dead` → ConfirmDialog → `POST /sync/outbox/{id}/retry` + `Idempotency-Key` (без step-up,
//   ядро §19.4) → строка `pending`, снекбар `sync_outbox_retried`; `409 already_delivered` → `sync_outbox_already_sent`
//   и перечитывание; `404` — строка исчезает; сеть — тот же ключ при следующем нажатии (P-IDEMP).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/sync/sync_journal.dart';
import 'package:optomstroy/core/sync/sync_models.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/offline_banner.dart' show dsTimeLabel;
import 'package:optomstroy/design_system/components/order_status_chip.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';
import 'package:optomstroy/features/sync_status/presentation/widgets/sync_labels.dart';
import 'package:uuid/uuid.dart';

/// Ключи вкладок журнала (тесты).
abstract final class SyncJournalKeys {
  static const Key errorsList = ValueKey<String>('sync-errors-list');
  static const Key errorsEmpty = ValueKey<String>('sync-errors-empty');
  static const Key outboxList = ValueKey<String>('sync-outbox-list');
  static const Key outboxEmpty = ValueKey<String>('sync-outbox-empty');
  static Key errorRow(String id) => ValueKey<String>('sync-error-$id');
  static Key outboxRow(String id) => ValueKey<String>('sync-outbox-$id');
  static Key outboxRetry(String id) => ValueKey<String>('sync-outbox-retry-$id');
  static Key outboxOpen(String id) => ValueKey<String>('sync-outbox-open-$id');
  static Key copyCode(String id) => ValueKey<String>('sync-error-copy-$id');
}

/// Генератор `Idempotency-Key` повтора outbox (тесты подменяют).
final syncOutboxKeyFactoryProvider = Provider<String Function()>((ref) => const Uuid().v4);

/// Прогон для вкладки «Ошибки»: явный [runId], иначе последний прогон с ошибками из [runs], иначе последний.
String? errorsRunOf(String? runId, List<SyncRunInfo>? runs) {
  if (runId != null) return runId;
  if (runs == null || runs.isEmpty) return null;
  for (final SyncRunInfo r in runs) {
    if ((r.errors ?? 0) > 0) return r.id;
  }
  return runs.first.id;
}

/// Вкладка «Ошибки» (UI-43-007).
class SyncErrorsTab extends ConsumerStatefulWidget {
  const SyncErrorsTab({required this.runId, this.run, super.key});

  /// Прогон; `null` — прогонов нет.
  final String? runId;

  /// Сведения о прогоне (подпись над списком).
  final SyncRunInfo? run;

  @override
  ConsumerState<SyncErrorsTab> createState() => _SyncErrorsTabState();
}

class _SyncErrorsTabState extends ConsumerState<SyncErrorsTab> {
  List<SyncRunErrorInfo>? _items;
  String? _cursor;
  bool _loading = false;
  Failure? _failure;
  int _req = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(SyncErrorsTab old) {
    super.didUpdateWidget(old);
    if (old.runId != widget.runId) unawaited(_load());
  }

  Future<void> _load({bool more = false}) async {
    final SyncJournalPort? port = ref.read(syncJournalPortProvider);
    final String? runId = widget.runId;
    if (port == null || runId == null) return;
    final int req = more ? _req : ++_req;
    setState(() {
      _loading = true;
      _failure = null;
      if (!more) _items = null;
    });
    final Result<PageResult<SyncRunErrorInfo>> r = await port.runErrors(runId, cursor: more ? _cursor : null);
    if (!mounted || req != _req) return;
    setState(() {
      _loading = false;
      switch (r) {
        case Success<PageResult<SyncRunErrorInfo>>(:final value):
          _items = <SyncRunErrorInfo>[if (more) ...?_items, ...value.items];
          _cursor = value.hasMore ? value.nextCursor : null;
        case FailureResult<PageResult<SyncRunErrorInfo>>(:final failure):
          _failure = failure;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    if (widget.runId == null) {
      return EmptyState(
        key: SyncJournalKeys.errorsEmpty,
        variant: EmptyStateVariant.search,
        title: l10n.sync_empty_errors,
      );
    }
    final List<SyncRunErrorInfo>? items = _items;
    if (items == null) {
      if (_failure != null) {
        return ErrorState.inline(message: l10n.error_internal, onRetry: () => unawaited(_load()), retrying: _loading);
      }
      return Column(
        children: <Widget>[
          for (int i = 0; i < 3; i++)
            Padding(
              padding: EdgeInsets.only(top: context.space.s2),
              child: const SkeletonBox(height: 56),
            ),
        ],
      );
    }
    final SyncRunInfo? run = widget.run;
    return Column(
      key: SyncJournalKeys.errorsList,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (run != null)
          Padding(
            padding: EdgeInsets.only(bottom: context.space.s2),
            child: Text(
              <String>[
                SyncLabels.entityValue(l10n, run.entityValue),
                if (run.startedAt != null)
                  dsTimeLabel(
                    context,
                    run.startedAt!,
                    nowUtc: ref.watch(syncNowProvider).value ?? ref.read(clockProvider).nowUtc(),
                  ),
              ].join(' · '),
              style: context.text.caption.copyWith(color: context.colors.textSecondary),
            ),
          ),
        if (items.isEmpty)
          EmptyState(key: SyncJournalKeys.errorsEmpty, variant: EmptyStateVariant.search, title: l10n.sync_empty_errors)
        else
          for (final SyncRunErrorInfo e in items) _ErrorRow(error: e),
        if (_cursor != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: AppButton(
              label: l10n.ds_button_more,
              variant: AppButtonVariant.text,
              size: AppButtonSize.s,
              loading: _loading,
              onPressed: _loading ? null : () => unawaited(_load(more: true)),
            ),
          ),
      ],
    );
  }
}

class _ErrorRow extends StatelessWidget {
  const _ErrorRow({required this.error});

  final SyncRunErrorInfo error;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String? code = error.onecCode;
    return Container(
      key: SyncJournalKeys.errorRow(error.id),
      constraints: const BoxConstraints(minHeight: 64),
      padding: EdgeInsets.symmetric(vertical: context.space.s2),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.colors.border)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  <String>[error.errorCodeValue, ?code].join(' · '),
                  style: context.text.label.copyWith(
                    color: context.colors.textPrimary,
                    fontFeatures: DsTypography.numeric,
                  ),
                ),
                Text(error.message, style: context.text.body.copyWith(color: context.colors.textPrimary)),
              ],
            ),
          ),
          if (code != null)
            AppIconButton(
              key: SyncJournalKeys.copyCode(error.id),
              icon: Icons.content_copy_rounded,
              semanticLabel: l10n.ds_copy_number,
              tooltip: l10n.ds_copy_number,
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: code));
                if (context.mounted) AppSnackbar.show(context, message: l10n.ds_copied);
              },
            ),
        ],
      ),
    );
  }
}

/// Вкладка «Outbox» (UI-43-008, UI-43-013, UI-43-015).
class SyncOutboxTab extends ConsumerStatefulWidget {
  const SyncOutboxTab({super.key});

  @override
  ConsumerState<SyncOutboxTab> createState() => _SyncOutboxTabState();
}

class _SyncOutboxTabState extends ConsumerState<SyncOutboxTab> {
  List<SyncOutboxItem>? _items;
  String? _cursor;
  bool _loading = false;
  Failure? _failure;
  final Set<String> _retrying = <String>{};

  /// Ключ повтора элемента до окончательного ответа (сеть — тот же ключ при следующем нажатии; P-IDEMP).
  final Map<String, String> _keys = <String, String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool more = false}) async {
    final SyncJournalPort? port = ref.read(syncJournalPortProvider);
    if (port == null) return;
    setState(() {
      _loading = true;
      _failure = null;
    });
    final Result<PageResult<SyncOutboxItem>> r = await port.outbox(cursor: more ? _cursor : null);
    if (!mounted) return;
    setState(() {
      _loading = false;
      switch (r) {
        case Success<PageResult<SyncOutboxItem>>(:final value):
          final List<SyncOutboxItem> all = <SyncOutboxItem>[if (more) ...?_items, ...value.items];
          // `dead` — по `createdAt` по возрастанию (порядок зависимостей «клиент → заказ → платёж», SYNC-042/049).
          _items = all;
          _cursor = value.hasMore ? value.nextCursor : null;
        case FailureResult<PageResult<SyncOutboxItem>>(:final failure):
          _failure = failure;
      }
    });
  }

  Future<void> _retry(SyncOutboxItem item) async {
    if (_retrying.contains(item.id)) return;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool ok = await ConfirmDialog.show(
      context,
      title: l10n.sync_outbox_retry_confirm(item.publicNumber ?? item.aggregateId),
      message: '',
      confirmLabel: l10n.sync_outbox_retry,
    );
    if (!ok || !mounted) return;
    final SyncJournalPort? port = ref.read(syncJournalPortProvider);
    if (port == null) return;
    final String key = _keys[item.id] ??= ref.read(syncOutboxKeyFactoryProvider)();
    setState(() => _retrying.add(item.id));
    final Result<SyncOutboxItem> r = await port.retryOutbox(item.id, idempotencyKey: key);
    if (!mounted) return;
    setState(() => _retrying.remove(item.id));
    switch (r) {
      case Success<SyncOutboxItem>(:final value):
        _keys.remove(item.id);
        setState(
          () => _items = <SyncOutboxItem>[
            for (final SyncOutboxItem x in _items ?? const <SyncOutboxItem>[]) x.id == item.id ? value : x,
          ],
        );
        AppSnackbar.show(context, message: l10n.sync_outbox_retried, variant: AppSnackbarVariant.success);
      case FailureResult<SyncOutboxItem>(:final failure):
        if (failure is NetworkFailure) {
          AppSnackbar.show(context, message: l10n.auth_error_network, variant: AppSnackbarVariant.error);
          return;
        }
        _keys.remove(item.id);
        if (failure is ConflictFailure && failure.kind == ConflictKind.orderStateInvalid) {
          AppSnackbar.show(context, message: l10n.sync_outbox_already_sent);
          unawaited(_load());
          return;
        }
        if (failure is ServerFailure && failure.status == 404) {
          setState(
            () => _items = <SyncOutboxItem>[
              for (final SyncOutboxItem x in _items ?? const <SyncOutboxItem>[])
                if (x.id != item.id) x,
            ],
          );
          return;
        }
        AppSnackbar.show(
          context,
          message: failure is PermissionFailure ? l10n.error_forbidden : l10n.error_internal,
          variant: AppSnackbarVariant.error,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final List<SyncOutboxItem>? items = _items;
    if (items == null) {
      if (_failure != null) {
        return ErrorState.inline(message: l10n.error_internal, onRetry: () => unawaited(_load()), retrying: _loading);
      }
      return Column(
        children: <Widget>[
          for (int i = 0; i < 3; i++)
            Padding(
              padding: EdgeInsets.only(top: context.space.s2),
              child: const SkeletonBox(height: 72),
            ),
        ],
      );
    }
    if (items.isEmpty) {
      return EmptyState(
        key: SyncJournalKeys.outboxEmpty,
        variant: EmptyStateVariant.transactions,
        title: l10n.sync_empty_outbox,
      );
    }
    final List<SyncOutboxItem> sorted = <SyncOutboxItem>[...items]
      ..sort((SyncOutboxItem a, SyncOutboxItem b) {
        final DateTime? x = a.createdAt;
        final DateTime? y = b.createdAt;
        if (x == null || y == null) return 0;
        return x.compareTo(y);
      });
    return Column(
      key: SyncJournalKeys.outboxList,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final SyncOutboxItem item in sorted)
          _OutboxRow(item: item, retrying: _retrying.contains(item.id), onRetry: () => unawaited(_retry(item))),
        if (_cursor != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: AppButton(
              label: l10n.ds_button_more,
              variant: AppButtonVariant.text,
              size: AppButtonSize.s,
              loading: _loading,
              onPressed: _loading ? null : () => unawaited(_load(more: true)),
            ),
          ),
      ],
    );
  }
}

/// Подпись и вариант `StatusChip` статуса outbox (`outbox_status`; отдельных строк ARB нет — подписи 1С-статуса
/// документа, как на SCR-37/SCR-38).
(String, StatusChipVariant) outboxStatusChip(AppLocalizations l10n, OutboxStatus? s) => switch (s) {
  OutboxStatus.pending || OutboxStatus.sending => (l10n.payment_onec_pending, StatusChipVariant.info),
  OutboxStatus.sent || OutboxStatus.confirmed => (l10n.payment_onec_confirmed, StatusChipVariant.success),
  OutboxStatus.failed => (l10n.transactions_status_onec_error, StatusChipVariant.warning),
  OutboxStatus.dead => (l10n.transactions_status_onec_error, StatusChipVariant.error),
  OutboxStatus.cancelled => (OrderStatusChip.labelOf(l10n, OrderStatus.cancelled), StatusChipVariant.neutral),
  null => (l10n.transactions_status_onec_error, StatusChipVariant.neutral),
};

class _OutboxRow extends StatelessWidget {
  const _OutboxRow({required this.item, required this.retrying, required this.onRetry});

  final SyncOutboxItem item;
  final bool retrying;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final (String label, StatusChipVariant variant) = outboxStatusChip(l10n, item.status);
    final String? error = <String>[?item.lastErrorCode, ?item.lastError].join(' · ').ifNotEmpty;
    return Container(
      key: SyncJournalKeys.outboxRow(item.id),
      constraints: const BoxConstraints(minHeight: 72),
      padding: EdgeInsets.symmetric(vertical: context.space.s2),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.colors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  <String>[item.aggregateTypeValue, item.publicNumber ?? item.aggregateId].join(' · '),
                  style: context.text.body.copyWith(
                    color: context.colors.textPrimary,
                    fontWeight: FontWeight.w500,
                    fontFeatures: DsTypography.numeric,
                  ),
                ),
              ),
              StatusChip(label: label, variant: variant, dense: true),
            ],
          ),
          if (error != null) Text(error, style: context.text.caption.copyWith(color: context.colors.textSecondary)),
          Wrap(
            spacing: context.space.s2,
            children: <Widget>[
              if (item.aggregateType == OutboxAggregate.order)
                AppButton(
                  key: SyncJournalKeys.outboxOpen(item.id),
                  label: l10n.transaction_details_action_open_order,
                  variant: AppButtonVariant.text,
                  size: AppButtonSize.s,
                  onPressed: () => GoRouter.maybeOf(context)?.go('/orders/${Uri.encodeComponent(item.aggregateId)}'),
                ),
              if (item.retryable)
                AppButton(
                  key: SyncJournalKeys.outboxRetry(item.id),
                  label: l10n.sync_outbox_retry,
                  variant: AppButtonVariant.tonal,
                  size: AppButtonSize.s,
                  loading: retrying,
                  onPressed: retrying ? null : onRetry,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

extension on String {
  String? get ifNotEmpty => isEmpty ? null : this;
}
