// Деталь записи аудита SCR-47 (02 UI-47-004, UI-47-005, UI-47-011, UI-47-013; AC-UI-47-004/005/014):
// событие, результат и признак целостности (`chainOk=false` — «Нарушена целостность»), пользователь и роль, время до
// секунд, устройство и сессия, причина и способ подтверждения, таблица «Было · Стало» по ключам `before/after`
// (без зачёркивания, A11Y-004), маска финансовых значений для `admin` («скрыто» + `visibility_off`), ссылка на
// объект, `requestId`/`rowHash` с копированием. Только чтение: действий изменения/удаления нет (AC-UI-47-007).
// Значения в лог и на диск не пишутся.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/audit_record.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';
import 'package:optomstroy/features/admin/presentation/audit/audit_labels.dart';
import 'package:optomstroy/features/admin/presentation/common/admin_format.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/admin_labels.dart';

/// Деталь записи журнала.
class AuditDetail extends StatelessWidget {
  const AuditDetail({required this.record, required this.integrityLabel, super.key});

  /// Ключи для тестов.
  static const Key rootKey = ValueKey<String>('audit-detail');
  static const Key integrityKey = ValueKey<String>('audit-detail-integrity');
  static const Key objectLinkKey = ValueKey<String>('audit-detail-object');
  static Key maskedKey(String field) => ValueKey<String>('audit-detail-masked-$field');

  final AuditRecord record;

  /// Подпись «Нарушена целостность».
  final String integrityLabel;

  static String _value(Object? v) => switch (v) {
    null => '—',
    final String s => s,
    final bool b => '$b',
    final int i => '$i',
    _ => jsonEncode(v),
  };

  Future<void> _copy(BuildContext context, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) return;
    AppSnackbar.show(context, message: AppLocalizations.of(context).audit_copied);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final AuditRecord r = record;
    final TextStyle caption = context.text.caption.copyWith(color: context.colors.textSecondary);
    final TextStyle body = context.text.body.copyWith(color: context.colors.textPrimary);
    final TextStyle mono = body.copyWith(fontFeatures: DsTypography.numeric);
    final String object = <String?>[r.entityType, r.entityId].whereType<String>().join(' · ');
    final String? location = AuditLabels.objectLocation(r.entityType, r.entityId);

    Widget field(String label, String? value, {bool copy = false, bool code = false}) {
      if (value == null || value.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: EdgeInsets.only(bottom: context.space.s2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(width: 140, child: Text(label, style: caption)),
            Expanded(child: SelectableText(value, style: code ? mono : body)),
            if (copy)
              IconButton(
                tooltip: l10n.audit_copied,
                icon: Icon(Icons.content_copy_rounded, size: 18, color: context.colors.textSecondary),
                onPressed: () => unawaited(_copy(context, value)),
              ),
          ],
        ),
      );
    }

    final Set<String> keys = <String>{...?r.before?.keys, ...?r.after?.keys};
    return Column(
      key: rootKey,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(AuditLabels.action(l10n, r.action), style: context.text.title.copyWith(color: context.colors.textPrimary)),
        SizedBox(height: context.space.s2),
        Wrap(
          spacing: context.space.s2,
          runSpacing: context.space.s2,
          children: <Widget>[
            StatusChip(label: AuditLabels.result(l10n, r.result), variant: AuditLabels.resultVariant(r.result)),
            if (!r.chainOk)
              StatusChip(
                key: integrityKey,
                label: integrityLabel,
                variant: StatusChipVariant.error,
                icon: Icons.link_off_rounded,
              ),
          ],
        ),
        SizedBox(height: context.space.s4),
        field(l10n.orders_col_date, AdminFormat.dateTimeSeconds(r.occurredAt), code: true),
        field(
          l10n.audit_filter_user,
          <String?>[
            r.actor?.displayName,
            if (r.actorRole != null) AdminLabels.role(l10n, r.actorRole!),
          ].whereType<String>().join(' · '),
        ),
        field(l10n.audit_filter_object, object),
        if (location != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: AppButton(
              key: objectLinkKey,
              label: l10n.ds_button_open,
              variant: AppButtonVariant.text,
              size: AppButtonSize.s,
              icon: Icons.open_in_new_rounded,
              onPressed: () => GoRouter.maybeOf(context)?.go(location),
            ),
          ),
        field(l10n.audit_reason, r.reason),
        field(l10n.audit_step_up_method, r.stepUpMethod?.value),
        field(l10n.transaction_details_device, r.deviceId, code: true),
        // Технические поля — имена полей контракта (подписей в 02 §7 нет, GQ-FEADM-04).
        field('ip', r.ip, code: true),
        field('appVersion', r.appVersion, code: true),
        field('sessionId', r.sessionId, code: true),
        field('requestId', r.requestId, copy: true, code: true),
        field('onecRef', r.onecRef, code: true),
        if (keys.isNotEmpty) ...<Widget>[
          SizedBox(height: context.space.s3),
          _DiffTable(keys: keys.toList()..sort(), before: r.before, after: r.after, valueOf: _value),
        ],
        if (r.rowHash != null) ...<Widget>[
          SizedBox(height: context.space.s3),
          Row(
            children: <Widget>[
              Icon(
                r.chainOk ? Icons.link_rounded : Icons.link_off_rounded,
                size: 16,
                color: r.chainOk ? context.colors.textSecondary : context.colors.error,
              ),
              SizedBox(width: context.space.s1),
              Expanded(
                child: Text(
                  r.rowHash!.length > 16 ? '${r.rowHash!.substring(0, 16)}…' : r.rowHash!,
                  style: caption.copyWith(fontFeatures: DsTypography.numeric),
                ),
              ),
              IconButton(
                tooltip: l10n.audit_copied,
                icon: Icon(Icons.content_copy_rounded, size: 18, color: context.colors.textSecondary),
                onPressed: () => unawaited(_copy(context, r.rowHash!)),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Таблица «Поле · Было · Стало».
class _DiffTable extends StatelessWidget {
  const _DiffTable({required this.keys, required this.before, required this.after, required this.valueOf});

  final List<String> keys;
  final Map<String, Object?>? before;
  final Map<String, Object?>? after;
  final String Function(Object? v) valueOf;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final TextStyle head = context.text.caption.copyWith(color: context.colors.textSecondary);
    Widget cell(String field, Object? v, {required bool has}) {
      if (!has) return Text('—', style: context.text.body.copyWith(color: context.colors.textSecondary));
      if (AuditLabels.isMasked(v)) {
        return Row(
          key: AuditDetail.maskedKey(field),
          children: <Widget>[
            Icon(Icons.visibility_off_outlined, size: 16, color: context.colors.textSecondary),
            SizedBox(width: context.space.s1),
            Flexible(child: Text(l10n.audit_masked_value, style: head)),
          ],
        );
      }
      return _LongValue(text: valueOf(v));
    }

    return Table(
      columnWidths: const <int, TableColumnWidth>{0: FlexColumnWidth(2), 1: FlexColumnWidth(3), 2: FlexColumnWidth(3)},
      border: TableBorder(horizontalInside: BorderSide(color: context.colors.border)),
      defaultVerticalAlignment: TableCellVerticalAlignment.top,
      children: <TableRow>[
        TableRow(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: context.colors.borderStrong)),
          ),
          children: <Widget>[
            _pad(context, Text(l10n.audit_filter_object, style: head)),
            _pad(context, Text(l10n.audit_before, style: head)),
            _pad(context, Text(l10n.audit_after, style: head)),
          ],
        ),
        for (final String k in keys)
          TableRow(
            children: <Widget>[
              _pad(context, Text(k, style: head.copyWith(fontFeatures: DsTypography.numeric))),
              _pad(context, cell(k, before?[k], has: before?.containsKey(k) ?? false)),
              _pad(context, cell(k, after?[k], has: after?.containsKey(k) ?? false)),
            ],
          ),
      ],
    );
  }

  static Widget _pad(BuildContext context, Widget child) => Padding(
    padding: EdgeInsets.symmetric(vertical: context.space.s2, horizontal: context.space.s1),
    child: child,
  );
}

/// Длинное значение сворачивается («Ещё»).
class _LongValue extends StatefulWidget {
  const _LongValue({required this.text});

  final String text;

  static const int limit = 120;

  @override
  State<_LongValue> createState() => _LongValueState();
}

class _LongValueState extends State<_LongValue> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final TextStyle style = context.text.body.copyWith(
      color: context.colors.textPrimary,
      fontFeatures: DsTypography.numeric,
    );
    if (widget.text.length <= _LongValue.limit || _open) return SelectableText(widget.text, style: style);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('${widget.text.substring(0, _LongValue.limit)}…', style: style),
        AppButton(
          label: AppLocalizations.of(context).ds_button_more,
          variant: AppButtonVariant.text,
          size: AppButtonSize.s,
          onPressed: () => setState(() => _open = true),
        ),
      ],
    );
  }
}
