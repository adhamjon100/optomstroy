// UI-43-012 «Запуск синхронизации» (`admin`, `owner`): сущность (`AppDropdown`, одна сущность на запуск —
// пункта «Все» нет) и режим (`AppRadio`: изменения по умолчанию, полная загрузка, сверка). Для `full`/`reconcile`
// — предупреждение `warningContainer` (`sync_run_full_warning`). Step-up выполняет контроллер после закрытия.
import 'package:flutter/material.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/sync/sync_run_policy.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_dropdown.dart';
import 'package:optomstroy/design_system/components/app_radio.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/sync_status/presentation/widgets/sync_labels.dart';

/// Выбор пользователя в диалоге.
typedef SyncRunChoice = ({SyncEntity entity, SyncMode mode});

class SyncRunDialog extends StatefulWidget {
  const SyncRunDialog({
    super.key,
    this.entity,
    this.mode = SyncMode.incremental,
    this.fullEstimates = const <SyncEntity, int>{},
  });

  /// Предзаполнение (меню строки сущности).
  final SyncEntity? entity;
  final SyncMode mode;

  /// Оценка длительности (мин) по последнему завершённому `full` сущности (журнал прогонов).
  final Map<SyncEntity, int> fullEstimates;

  static const Key confirmKey = Key('sync-run-dialog-confirm');

  /// Показать диалог; `null` — закрыт без запуска.
  static Future<SyncRunChoice?> show(
    BuildContext context, {
    SyncEntity? entity,
    SyncMode mode = SyncMode.incremental,
    Map<SyncEntity, int> fullEstimates = const <SyncEntity, int>{},
  }) => showDialog<SyncRunChoice>(
    context: context,
    builder: (_) => SyncRunDialog(entity: entity, mode: mode, fullEstimates: fullEstimates),
  );

  @override
  State<SyncRunDialog> createState() => _SyncRunDialogState();
}

class _SyncRunDialogState extends State<SyncRunDialog> {
  late SyncEntity _entity = widget.entity ?? SyncEntity.stock;
  late SyncMode _mode = SyncRunPolicy.dialogModes.contains(widget.mode) ? widget.mode : SyncMode.incremental;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final heavy = _mode == SyncMode.full || _mode == SyncMode.reconcile;
    return Dialog(
      insetPadding: EdgeInsets.all(context.space.s4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          padding: EdgeInsets.all(context.space.s6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(l10n.sync_run_dialog_title, style: context.text.h3.copyWith(color: context.colors.textPrimary)),
              SizedBox(height: context.space.s4),
              AppDropdown<SyncEntity>(
                label: l10n.sync_run_dialog_entity,
                value: _entity,
                items: [
                  for (final e in SyncRunPolicy.displayOrder)
                    AppDropdownItem<SyncEntity>(value: e, label: SyncLabels.entity(l10n, e)),
                ],
                onChanged: (e) => setState(() => _entity = e),
              ),
              SizedBox(height: context.space.s4),
              Text(l10n.sync_run_dialog_mode, style: context.text.label.copyWith(color: context.colors.textSecondary)),
              for (final m in SyncRunPolicy.dialogModes)
                AppRadio<SyncMode>(
                  value: m,
                  groupValue: _mode,
                  label: SyncLabels.mode(l10n, m),
                  onChanged: (v) => setState(() => _mode = v),
                ),
              if (heavy) ...<Widget>[
                SizedBox(height: context.space.s2),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: context.colors.warningContainer,
                    borderRadius: BorderRadius.all(context.radii.md),
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(context.space.s3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Icon(Icons.warning_rounded, size: 20, color: context.colors.warning),
                        SizedBox(width: context.space.s2),
                        Expanded(
                          child: Text(
                            // Оценка — по последнему `full` сущности; без данных журнала — текст без числа
                            // (02 SCR-43.4, EQ-E009-05).
                            switch (widget.fullEstimates[_entity]) {
                              final int minutes => l10n.sync_run_full_warning(minutes),
                              null => l10n.sync_run_full_warning_no_estimate,
                            },
                            style: context.text.body.copyWith(color: context.colors.textPrimary),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              SizedBox(height: context.space.s6),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: context.space.s2,
                runSpacing: context.space.s2,
                children: <Widget>[
                  AppButton(
                    label: l10n.ds_button_cancel,
                    variant: AppButtonVariant.text,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  AppButton(
                    key: SyncRunDialog.confirmKey,
                    label: l10n.sync_run_open_dialog,
                    onPressed: () => Navigator.of(context).pop<SyncRunChoice>((entity: _entity, mode: _mode)),
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
