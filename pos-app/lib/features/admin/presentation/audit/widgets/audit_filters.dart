// Фильтры SCR-47 (02 UI-47-001, UI-47-003, UI-47-006, UI-47-007): пользователь (`actorId`, список — `GET /admin/users`),
// действие — префикс кода (≤ 100; чипы групп 11 §7.2), объект — тип и ID (≤ 64), результат. Период — отдельной лентой
// пресетов на экране (обязателен, «Сбросить» возвращает «Сегодня»). Лист (compact) / панель (medium, expanded).
import 'package:flutter/material.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_dropdown.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/category_chip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/admin/domain/audit/audit_log.dart';
import 'package:optomstroy/features/admin/presentation/audit/audit_labels.dart';

/// Фильтры журнала (кроме периода).
@immutable
final class AuditFilters {
  const AuditFilters({this.actorId, this.action, this.entityType, this.entityId, this.result});

  /// Из параметров URL.
  factory AuditFilters.fromQuery({
    String? userId,
    String? action,
    String? entityType,
    String? entityId,
    String? result,
  }) => AuditFilters(
    actorId: _norm(userId, 64),
    action: _norm(action, AuditQuery.actionMax),
    entityType: _norm(entityType, AuditQuery.entityMax),
    entityId: _norm(entityId, AuditQuery.entityMax),
    result: AuditResult.values.where((AuditResult r) => r.value == result).firstOrNull,
  );

  final String? actorId;
  final String? action;
  final String? entityType;
  final String? entityId;
  final AuditResult? result;

  static String? _norm(String? v, int max) {
    final String t = (v ?? '').trim();
    if (t.isEmpty) return null;
    return t.length > max ? t.substring(0, max) : t;
  }

  /// Число активных фильтров (для «Фильтры (n)»).
  int get count => <Object?>[actorId, action, entityType, entityId, result].where((Object? v) => v != null).length;

  AuditFilters normalized() => AuditFilters(
    actorId: _norm(actorId, 64),
    action: _norm(action, AuditQuery.actionMax),
    entityType: _norm(entityType, AuditQuery.entityMax),
    entityId: _norm(entityId, AuditQuery.entityMax),
    result: result,
  );

  @override
  bool operator ==(Object other) =>
      other is AuditFilters &&
      other.actorId == actorId &&
      other.action == action &&
      other.entityType == entityType &&
      other.entityId == entityId &&
      other.result == result;

  @override
  int get hashCode => Object.hash(actorId, action, entityType, entityId, result);
}

/// Пункт списка пользователей фильтра.
@immutable
final class AuditUserOption {
  const AuditUserOption({required this.id, required this.label});

  final String id;
  final String label;
}

/// Форма фильтров.
class AuditFiltersForm extends StatefulWidget {
  const AuditFiltersForm({
    required this.initial,
    required this.users,
    required this.onApply,
    required this.onReset,
    super.key,
  });

  /// Ключи для тестов.
  static const Key userKey = ValueKey<String>('audit-filter-user');
  static const Key actionKey = ValueKey<String>('audit-filter-action');
  static const Key entityTypeKey = ValueKey<String>('audit-filter-entity-type');
  static const Key entityIdKey = ValueKey<String>('audit-filter-entity-id');
  static const Key resultKey = ValueKey<String>('audit-filter-result');
  static const Key applyKey = ValueKey<String>('audit-filter-apply');
  static const Key resetKey = ValueKey<String>('audit-filter-reset');
  static Key prefixKey(String prefix) => ValueKey<String>('audit-filter-prefix-$prefix');

  final AuditFilters initial;
  final List<AuditUserOption> users;
  final ValueChanged<AuditFilters> onApply;
  final VoidCallback onReset;

  @override
  State<AuditFiltersForm> createState() => _AuditFiltersFormState();
}

class _AuditFiltersFormState extends State<AuditFiltersForm> {
  late String _actorId = widget.initial.actorId ?? '';
  late String _result = widget.initial.result?.value ?? '';
  late final TextEditingController _action = TextEditingController(text: widget.initial.action);
  late final TextEditingController _entityType = TextEditingController(text: widget.initial.entityType);
  late final TextEditingController _entityId = TextEditingController(text: widget.initial.entityId);

  @override
  void dispose() {
    _action.dispose();
    _entityType.dispose();
    _entityId.dispose();
    super.dispose();
  }

  AuditFilters get _draft => AuditFilters(
    actorId: _actorId,
    action: _action.text,
    entityType: _entityType.text,
    entityId: _entityId.text,
    result: AuditResult.values.where((AuditResult r) => r.value == _result).firstOrNull,
  ).normalized();

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool knownUser = _actorId.isEmpty || widget.users.any((AuditUserOption u) => u.id == _actorId);
    final SizedBox gap = SizedBox(height: context.space.s3);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AppDropdown<String>(
          key: AuditFiltersForm.userKey,
          label: l10n.audit_filter_user,
          value: _actorId,
          items: <AppDropdownItem<String>>[
            AppDropdownItem<String>(value: '', label: l10n.admin_users_filter_all),
            if (!knownUser) AppDropdownItem<String>(value: _actorId, label: _actorId),
            for (final AuditUserOption u in widget.users) AppDropdownItem<String>(value: u.id, label: u.label),
          ],
          onChanged: (String v) => setState(() => _actorId = v),
        ),
        gap,
        AppTextField(
          key: AuditFiltersForm.actionKey,
          controller: _action,
          label: l10n.audit_filter_action,
          maxLength: AuditQuery.actionMax,
          onChanged: (_) => setState(() {}),
        ),
        SizedBox(height: context.space.s2),
        Wrap(
          spacing: context.space.s2,
          runSpacing: context.space.s2,
          children: <Widget>[
            for (final String p in AuditLabels.actionPrefixes)
              IntrinsicWidth(
                child: CategoryChip(
                  key: AuditFiltersForm.prefixKey(p),
                  label: p,
                  selected: _action.text.trim() == p,
                  onTap: () => setState(() => _action.text = _action.text.trim() == p ? '' : p),
                ),
              ),
          ],
        ),
        gap,
        AppTextField(
          key: AuditFiltersForm.entityTypeKey,
          controller: _entityType,
          label: l10n.audit_filter_object,
          maxLength: AuditQuery.entityMax,
        ),
        SizedBox(height: context.space.s2),
        AppTextField(
          key: AuditFiltersForm.entityIdKey,
          controller: _entityId,
          label: 'ID',
          maxLength: AuditQuery.entityMax,
        ),
        gap,
        AppDropdown<String>(
          key: AuditFiltersForm.resultKey,
          label: l10n.audit_filter_result,
          value: _result,
          items: <AppDropdownItem<String>>[
            AppDropdownItem<String>(value: '', label: l10n.admin_users_filter_all),
            AppDropdownItem<String>(value: AuditResult.ok.value, label: l10n.audit_result_ok),
            AppDropdownItem<String>(value: AuditResult.denied.value, label: l10n.audit_result_denied),
            AppDropdownItem<String>(value: AuditResult.error.value, label: l10n.audit_result_error),
          ],
          onChanged: (String v) => setState(() => _result = v),
        ),
        SizedBox(height: context.space.s4),
        Row(
          children: <Widget>[
            Expanded(
              child: AppButton(
                key: AuditFiltersForm.resetKey,
                label: l10n.ds_button_reset,
                variant: AppButtonVariant.text,
                onPressed: widget.onReset,
              ),
            ),
            SizedBox(width: context.space.s2),
            Expanded(
              child: AppButton(
                key: AuditFiltersForm.applyKey,
                label: l10n.ds_button_apply,
                onPressed: () => widget.onApply(_draft),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
