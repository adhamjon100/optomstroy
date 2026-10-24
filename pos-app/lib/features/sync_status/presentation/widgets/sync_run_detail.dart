// Деталь прогона SCR-43 (02 UI-43-011): сущность, режим, способ запуска (`SyncRun.trigger`, «Вручную: {name}»),
// статус, начало–конец, счётчики `fetched / sourceTotal`, число ошибок. Данные — `GET /sync/runs/{id}`
// (`SyncStatusPort.run`); compact — отдельный экран, medium/expanded — боковой лист. Действий «Пометить решённой» и
// «Пауза сущности» в R1 нет (Q-219, RM-G-012 п. 4). Журнал ошибок прогона (`/sync/runs/{id}/errors`) — порт не
// содержит метода (GQ-FEADM-08).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/sync/sync_models.dart';
import 'package:optomstroy/core/sync/sync_ports.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';
import 'package:optomstroy/features/sync_status/presentation/widgets/sync_labels.dart';

/// Деталь прогона по `runId` (данные из списка показываются сразу, затем уточняются запросом).
class SyncRunDetail extends ConsumerStatefulWidget {
  const SyncRunDetail({required this.runId, this.initial, super.key});

  /// Корневой ключ.
  static const Key rootKey = ValueKey<String>('sync-run-detail');

  final String runId;
  final SyncRunInfo? initial;

  @override
  ConsumerState<SyncRunDetail> createState() => _SyncRunDetailState();
}

class _SyncRunDetailState extends ConsumerState<SyncRunDetail> {
  late SyncRunInfo? _run = widget.initial;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final SyncStatusPort? port = ref.read(syncStatusPortProvider);
    if (port == null) return;
    final Result<SyncRunInfo> r = await port.run(widget.runId);
    if (!mounted) return;
    setState(() {
      switch (r) {
        case Success<SyncRunInfo>(:final value):
          _run = value;
          _failed = false;
        case FailureResult<SyncRunInfo>():
          _failed = _run == null;
      }
    });
  }

  static String _t(DateTime utc) {
    final DateTime w = utc.toUtc().add(const Duration(hours: 6));
    String p(int v) => v.toString().padLeft(2, '0');
    return '${p(w.day)}.${p(w.month)}.${w.year} ${p(w.hour)}:${p(w.minute)}:${p(w.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final SyncRunInfo? r = _run;
    if (r == null) {
      if (_failed) return ErrorState.inline(message: l10n.error_internal, onRetry: () => unawaited(_load()));
      return const Column(
        children: <Widget>[
          SkeletonBox(height: 24),
          SizedBox(height: 8),
          SkeletonBox(height: 16),
          SizedBox(height: 8),
          SkeletonBox(height: 16),
        ],
      );
    }
    final (String status, StatusChipVariant variant) = SyncLabels.runStatus(l10n, r);
    final TextStyle caption = context.text.caption.copyWith(color: context.colors.textSecondary);
    final TextStyle numeric = context.text.body.copyWith(
      color: context.colors.textPrimary,
      fontFeatures: DsTypography.numeric,
    );
    final List<String> lines = <String>[
      if (r.mode != null) SyncLabels.mode(l10n, r.mode!),
      SyncLabels.trigger(l10n, r),
    ];
    return Column(
      key: SyncRunDetail.rootKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                SyncLabels.entityValue(l10n, r.entityValue),
                style: context.text.title.copyWith(color: context.colors.textPrimary),
              ),
            ),
            StatusChip(label: status, variant: variant),
          ],
        ),
        SizedBox(height: context.space.s2),
        Text(lines.join(' · '), style: caption),
        SizedBox(height: context.space.s3),
        if (r.startedAt != null)
          Text(r.finishedAt == null ? _t(r.startedAt!) : '${_t(r.startedAt!)} – ${_t(r.finishedAt!)}', style: numeric),
        if (r.fetched != null || r.sourceTotal != null)
          Padding(
            padding: EdgeInsets.only(top: context.space.s2),
            child: Text('${r.fetched ?? 0} / ${r.sourceTotal ?? '—'}', style: numeric),
          ),
        if ((r.errors ?? 0) > 0)
          Padding(
            padding: EdgeInsets.only(top: context.space.s2),
            child: StatusChip(label: l10n.sync_run_partial(r.errors!), variant: StatusChipVariant.warning),
          ),
      ],
    );
  }
}
