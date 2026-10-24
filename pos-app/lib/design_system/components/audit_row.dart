// `AuditRow` (03 §9.62; 02 SCR-47 UI-47-002, UI-47-005, AC-UI-47-014): строка журнала аудита.
//
// Expanded/medium — 64: иконка действия 20 в круге 36 `surfaceVariant` → действие `body 500` → пользователь
// `caption textSecondary` → время до секунд · устройство `caption tnum` → справа `StatusChip` результата и, при
// разрыве хэш-цепочки (`AuditRow.chainOk=false`, ядро §19.2), `StatusChip.error` с глифом `link_off` → шеврон.
// Compact — 80, три строки: время + результат / пользователь · действие / объект.
// Компонент не знает домена: подписи, вариант результата и признак целостности передаёт экран (тексты — ARB).
// Только чтение: действий изменения/удаления у строки нет (AC-UI-47-007).
import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

/// Строка журнала аудита.
class AuditRow extends StatelessWidget {
  /// Создаёт строку.
  const AuditRow({
    super.key,
    required this.actionLabel,
    required this.timeLabel,
    required this.resultLabel,
    required this.resultVariant,
    this.icon = Icons.fact_check_outlined,
    this.actorLabel,
    this.objectLabel,
    this.deviceLabel,
    this.integrityBroken = false,
    this.integrityLabel,
    this.selected = false,
    this.compact = false,
    this.onTap,
  });

  /// Высота строки на medium/expanded.
  static const double heightRegular = 64;

  /// Высота строки на compact (3 строки).
  static const double heightCompact = 80;

  /// Ключ чипа «Нарушена целостность».
  static const Key integrityKey = ValueKey<String>('audit-row-integrity');

  /// Подпись действия (`audit_action_<code>` или код как есть).
  final String actionLabel;

  /// Время до секунд (Asia/Bishkek).
  final String timeLabel;

  /// Подпись результата (`audit_result_*`).
  final String resultLabel;

  /// Вариант чипа результата (`ok` — success, `denied` — error, `error` — warning).
  final StatusChipVariant resultVariant;

  /// Иконка действия ([iconFor]).
  final IconData icon;

  /// Пользователь и роль.
  final String? actorLabel;

  /// Объект (`entityType` · `entityId`).
  final String? objectLabel;

  /// Устройство.
  final String? deviceLabel;

  /// Целостность записи не подтверждена сервером (`chainOk == false`).
  final bool integrityBroken;

  /// Подпись чипа целостности.
  final String? integrityLabel;

  /// Выбранная строка (деталь открыта).
  final bool selected;

  /// Вариант compact (3 строки, 80).
  final bool compact;

  /// Открыть деталь.
  final VoidCallback? onTap;

  /// Иконка по коду события (03 §9.62): скидка `percent`, step-up и вход `lock`, блокировка `person_off`,
  /// права/лимиты/настройки `edit`, просмотр финансов `visibility`, ручное подтверждение QR `qr_code_2`,
  /// синхронизация `sync`, отмена `cancel`, возврат `undo`; прочее — `fact_check`.
  static IconData iconFor(String action) {
    if (action.startsWith('discount.limits')) return Icons.edit_outlined;
    if (action.startsWith('discount.')) return Icons.percent_rounded;
    if (action == 'user.blocked' || action.startsWith('authz.')) return Icons.person_off_outlined;
    if (action.startsWith('user.') || action.startsWith('settings.') || action.startsWith('invitation.')) {
      return Icons.edit_outlined;
    }
    if (action.startsWith('auth.') || action.startsWith('session.')) return Icons.lock_outline_rounded;
    if (action.startsWith('customer.') || action.startsWith('receivables.')) return Icons.visibility_outlined;
    if (action.startsWith('payment.manual')) return Icons.qr_code_2_rounded;
    if (action.startsWith('sync.') || action.startsWith('outbox.')) return Icons.sync_rounded;
    if (action.contains('cancel') || action.contains('void')) return Icons.cancel_outlined;
    if (action.startsWith('return.')) return Icons.undo_rounded;
    return Icons.fact_check_outlined;
  }

  /// Скелетон строки (`SkeletonList.row64`).
  static Widget skeleton({bool compact = false}) => _AuditRowSkeleton(compact: compact);

  String get _semantics => <String?>[
    timeLabel,
    actorLabel,
    actionLabel,
    objectLabel,
    deviceLabel,
    resultLabel,
    if (integrityBroken) integrityLabel,
  ].whereType<String>().where((String s) => s.isNotEmpty).join(', ');

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final DsTypography t = context.text;
    final TextStyle caption = t.caption.copyWith(color: c.textSecondary);
    final TextStyle numeric = caption.copyWith(fontFeatures: DsTypography.numeric);
    final Widget chips = Wrap(
      spacing: context.space.s1,
      runSpacing: context.space.s1,
      alignment: WrapAlignment.end,
      children: <Widget>[
        StatusChip(label: resultLabel, variant: resultVariant, dense: true),
        if (integrityBroken)
          StatusChip(
            key: integrityKey,
            label: integrityLabel ?? '',
            variant: StatusChipVariant.error,
            icon: Icons.link_off_rounded,
            dense: true,
          ),
      ],
    );
    final Widget content = compact
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(timeLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: numeric),
                  ),
                  chips,
                ],
              ),
              SizedBox(height: context.space.s1),
              Text(
                <String?>[actorLabel, actionLabel].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: t.body.copyWith(color: c.textPrimary, fontWeight: FontWeight.w500),
              ),
              if (objectLabel != null && objectLabel!.isNotEmpty)
                Text(objectLabel!, maxLines: 1, overflow: TextOverflow.ellipsis, style: caption),
            ],
          )
        : Row(
            children: <Widget>[
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: c.surfaceVariant, shape: BoxShape.circle),
                child: Icon(icon, size: 20, color: c.textSecondary),
              ),
              SizedBox(width: context.space.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Text(
                      <String?>[actionLabel, objectLabel].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.body.copyWith(color: c.textPrimary, fontWeight: FontWeight.w500),
                    ),
                    if (actorLabel != null && actorLabel!.isNotEmpty)
                      Text(actorLabel!, maxLines: 1, overflow: TextOverflow.ellipsis, style: caption),
                    Text(
                      <String?>[timeLabel, deviceLabel].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: numeric,
                    ),
                  ],
                ),
              ),
              SizedBox(width: context.space.s2),
              Flexible(flex: 0, child: chips),
              if (onTap != null) Icon(Icons.chevron_right_rounded, size: 20, color: c.textSecondary),
            ],
          );
    return Semantics(
      button: onTap != null,
      selected: selected,
      label: _semantics,
      excludeSemantics: true,
      child: Material(
        color: selected ? c.primaryContainer : c.surface,
        child: InkWell(
          onTap: onTap,
          hoverColor: c.surfaceHover,
          highlightColor: c.surfacePressed,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: compact ? heightCompact : heightRegular),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: context.space.s4, vertical: context.space.s2),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

class _AuditRowSkeleton extends StatelessWidget {
  const _AuditRowSkeleton({required this.compact});

  final bool compact;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: compact ? AuditRow.heightCompact : AuditRow.heightRegular,
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: context.space.s4, vertical: context.space.s2),
      child: Row(
        children: <Widget>[
          if (!compact) ...<Widget>[const SkeletonBox.avatar(size: 36), SizedBox(width: context.space.s3)],
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: <Widget>[SkeletonBox.text(width: 220, height: 14), SkeletonBox.text(width: 140, height: 12)],
            ),
          ),
          const SkeletonBox(width: 72, height: 20),
        ],
      ),
    ),
  );
}
