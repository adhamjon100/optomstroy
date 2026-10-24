// Содержимое секций SCR-46 (02 SCR-46.2 таблица секций, UI-46-002…UI-46-017). Поле — подпись (ключ `app_settings`
// API: подписей полей в словаре 02 §7 нет, GQ-FEADM-05), ввод и ошибка 02 SCR-46.8; изменённое поле — фон
// `primaryContainer` (до сохранения/отмены); значения окружения — строка только для чтения с `lock` и подсказкой
// «Задаётся на сервере» (UI-46-004). `owner` — все поля неактивны (UI-46-015). `CUSTOMER_SELF_SERVICE` — строка
// только для чтения без переключателя (UI-46-017, AC-UI-46-011). Секреты не показываются (AC-UI-46-010).
import 'package:flutter/material.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_checkbox.dart';
import 'package:optomstroy/design_system/components/app_dropdown.dart';
import 'package:optomstroy/design_system/components/app_switch.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';
import 'package:optomstroy/features/admin/domain/settings/admin_settings.dart';
import 'package:optomstroy/features/admin/presentation/settings/admin_settings_controller.dart';
import 'package:optomstroy/features/admin/presentation/settings/admin_settings_form.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/admin_labels.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/role_badge.dart';

/// Подписи SCR-46.
abstract final class AdminSettingsTexts {
  static String section(AppLocalizations l10n, AdminSettingsSection s) => switch (s) {
    AdminSettingsSection.discountLimits => l10n.admin_settings_section_limits,
    AdminSettingsSection.receivables => l10n.admin_settings_section_debts,
    AdminSettingsSection.stock => l10n.admin_settings_section_stock,
    AdminSettingsSection.paymentsReturns => l10n.admin_settings_section_payments,
    AdminSettingsSection.carts => l10n.admin_settings_section_carts,
    AdminSettingsSection.printing => l10n.admin_settings_section_print,
    AdminSettingsSection.sync => l10n.admin_settings_section_sync,
    AdminSettingsSection.authSessions => l10n.admin_settings_section_auth,
    AdminSettingsSection.appVersions => l10n.admin_settings_section_versions,
    AdminSettingsSection.registration => l10n.admin_settings_section_registration,
    AdminSettingsSection.textsContacts => l10n.admin_settings_section_texts,
  };

  static IconData icon(AdminSettingsSection s) => switch (s) {
    AdminSettingsSection.discountLimits => Icons.percent_rounded,
    AdminSettingsSection.receivables => Icons.account_balance_wallet_outlined,
    AdminSettingsSection.stock => Icons.warehouse_outlined,
    AdminSettingsSection.paymentsReturns => Icons.payments_outlined,
    AdminSettingsSection.carts => Icons.shopping_cart_outlined,
    AdminSettingsSection.printing => Icons.print_outlined,
    AdminSettingsSection.sync => Icons.sync_rounded,
    AdminSettingsSection.authSessions => Icons.lock_outline_rounded,
    AdminSettingsSection.appVersions => Icons.system_update_outlined,
    AdminSettingsSection.registration => Icons.person_add_outlined,
    AdminSettingsSection.textsContacts => Icons.info_outline_rounded,
  };

  /// Текст ошибки поля; для диапазонов без отдельного ключа — сам диапазон (GQ-FEADM-05).
  static String? error(AppLocalizations l10n, SettingsFieldError? e, {SettingsField? field}) => switch (e) {
    null => null,
    SettingsFieldError.limit => l10n.admin_settings_limit_error,
    SettingsFieldError.receivables => l10n.admin_settings_receivables_error,
    SettingsFieldError.lowStock => l10n.admin_settings_low_stock_error,
    SettingsFieldError.interval => l10n.admin_settings_interval_error,
    SettingsFieldError.otpTtl => l10n.admin_settings_otp_ttl_error,
    SettingsFieldError.idle => l10n.admin_settings_idle_error,
    SettingsFieldError.version => l10n.admin_settings_version_error,
    SettingsFieldError.versionOrder => l10n.admin_settings_version_order_error,
    SettingsFieldError.invalid =>
      field?.min != null && field?.max != null ? '${field!.min}…${field.max}' : l10n.error_internal,
    SettingsFieldError.server => l10n.error_internal,
  };

  /// Значения окружения секции (UI-46-004): имя переменной → значение.
  static List<(String, String?)> env(AdminSettingsSection s, AdminSettingsEnv e, {required bool selfService}) =>
      switch (s) {
        AdminSettingsSection.receivables => <(String, String?)>[
          ('RECEIVABLES_MAX_AGE_MIN', e.receivablesMaxAgeMin?.toString()),
        ],
        AdminSettingsSection.paymentsReturns => <(String, String?)>[
          ('QR_PROVIDER', e.qrProvider?.value),
          ('QR_TTL_MINUTES', e.qrTtlMinutes?.toString()),
          ('QR_ONEC_POLL_SECONDS', e.qrOnecPollSeconds?.toString()),
          ('DEBT_PAYMENTS_FROM_POS', e.debtPaymentsFromPos?.toString()),
        ],
        AdminSettingsSection.authSessions => <(String, String?)>[
          ('OTP_TTL_SECONDS', e.otpTtlSeconds?.toString()),
          ('OTP_RESEND_COOLDOWN_SECONDS', e.otpResendCooldownSeconds?.toString()),
          ('OTP_MAX_VERIFY_ATTEMPTS', e.otpMaxVerifyAttempts?.toString()),
          ('OTP_GLOBAL_PER_MIN', e.otpGlobalPerMin?.toString()),
          ('OTP_LOCK_AFTER_LOCKED_CODES', e.otpLockAfterLockedCodes?.toString()),
          ('OTP_PHONE_PAUSE_MINUTES', e.otpPhonePauseMinutes?.toString()),
          ('SESSION_IDLE_LOCK_MINUTES', e.sessionIdleLockMinutes?.toString()),
          ('AUTH_BACKGROUND_LOCK_MINUTES', e.authBackgroundLockMinutes?.toString()),
        ],
        AdminSettingsSection.appVersions => <(String, String?)>[
          ('MIN_APP_VERSION', e.minAppVersion),
          ('RECOMMENDED_APP_VERSION', e.recommendedAppVersion),
        ],
        AdminSettingsSection.textsContacts => <(String, String?)>[('SMS_SENDER_NAME', e.smsSenderName)],
        _ => const <(String, String?)>[],
      };
}

/// Ключи для тестов.
abstract final class AdminSettingsKeys {
  static Key field(String key) => ValueKey<String>('admin-settings-field-$key');
  static Key env(String name) => ValueKey<String>('admin-settings-env-$name');
  static const Key customerMode = ValueKey<String>('admin-settings-customer-mode');
  static const Key overrideWarning = ValueKey<String>('admin-settings-override-warning');
  static const Key onecBanner = ValueKey<String>('admin-settings-onec-banner');
}

/// Содержимое секции.
class AdminSettingsSectionBody extends StatelessWidget {
  const AdminSettingsSectionBody({
    required this.section,
    required this.state,
    required this.onEdit,
    required this.selfService,
    super.key,
  });

  final AdminSettingsSection section;
  final AdminSettingsState state;
  final void Function(String key, String value) onEdit;

  /// `features.customerSelfService` (`GET /settings/public`).
  final bool selfService;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool editable = state.canEdit;
    final List<Widget> children = <Widget>[];
    if (section == AdminSettingsSection.discountLimits) {
      children.add(_LimitsTable(state: state, onEdit: onEdit, editable: editable));
    } else {
      for (final SettingsField f in AdminSettingsCatalog.of(section)) {
        if (f.adminOnly && !editable && state.serverValue(f.key).isEmpty) continue;
        children.add(_FieldRow(field: f, state: state, onEdit: onEdit, editable: editable));
      }
    }
    if (section == AdminSettingsSection.registration) {
      children.add(
        Container(
          key: AdminSettingsKeys.customerMode,
          margin: EdgeInsets.only(bottom: context.space.s3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    // Переключателя нет: только env (ядро §19.2) — состояние показано неактивным тумблером.
                    child: AppSwitch(
                      value: selfService,
                      onChanged: null,
                      label: l10n.admin_settings_customer_mode_label,
                    ),
                  ),
                  AppTooltip(
                    message: l10n.admin_settings_env_hint,
                    child: Icon(Icons.lock_outline_rounded, size: 18, color: context.colors.textSecondary),
                  ),
                ],
              ),
              Text(
                l10n.admin_settings_customer_mode_env('CUSTOMER_SELF_SERVICE=$selfService'),
                style: context.text.caption.copyWith(color: context.colors.textSecondary),
              ),
            ],
          ),
        ),
      );
    }
    final AdminSettingsEnv? env = state.settings?.env;
    if (env != null) {
      for (final (String name, String? value) in AdminSettingsTexts.env(section, env, selfService: selfService)) {
        if (value == null) continue;
        children.add(_EnvRow(name: name, value: value));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

/// Строка значения окружения (UI-46-004).
class _EnvRow extends StatelessWidget {
  const _EnvRow({required this.name, required this.value});

  final String name;
  final String value;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Container(
      key: AdminSettingsKeys.env(name),
      margin: EdgeInsets.only(bottom: context.space.s2),
      padding: EdgeInsets.symmetric(horizontal: context.space.s3, vertical: context.space.s2),
      decoration: BoxDecoration(color: context.colors.surfaceVariant, borderRadius: BorderRadius.all(context.radii.sm)),
      child: Row(
        children: <Widget>[
          AppTooltip(
            message: l10n.admin_settings_env_hint,
            child: Icon(Icons.lock_outline_rounded, size: 16, color: context.colors.textSecondary),
          ),
          SizedBox(width: context.space.s2),
          Expanded(
            child: Text(
              name,
              style: context.text.caption.copyWith(color: context.colors.textSecondary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            value,
            style: context.text.body.copyWith(color: context.colors.textPrimary, fontFeatures: DsTypography.numeric),
          ),
        ],
      ),
    );
  }
}

/// Поле настройки.
class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.field, required this.state, required this.onEdit, required this.editable});

  final SettingsField field;
  final AdminSettingsState state;
  final void Function(String key, String value) onEdit;
  final bool editable;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String value = state.value(field.key);
    final bool changed = value.trim() != state.serverValue(field.key).trim();
    final String? error = AdminSettingsTexts.error(l10n, state.errorOf(field.key), field: field);
    final String label = field.key;
    final Widget input = switch (field.kind) {
      SettingsFieldKind.boolean => AppSwitch(
        value: value == 'true',
        label: label,
        onChanged: editable ? (bool v) => onEdit(field.key, '$v') : null,
      ),
      SettingsFieldKind.choice => AppDropdown<String>(
        label: label,
        value: value.isEmpty ? null : value,
        errorText: error,
        items: <AppDropdownItem<String>>[
          for (final String c in field.choices) AppDropdownItem<String>(value: c, label: _choiceLabel(l10n, c)),
        ],
        onChanged: editable ? (String v) => onEdit(field.key, v) : null,
      ),
      _ => DraftTextField(
        label: label,
        value: value,
        errorText: error,
        enabled: editable,
        numeric: field.kind == SettingsFieldKind.integer,
        onChanged: (String v) => onEdit(field.key, v),
      ),
    };
    return AnimatedContainer(
      key: AdminSettingsKeys.field(field.key),
      duration: context.motion.of(context.motion.fast),
      margin: EdgeInsets.only(bottom: context.space.s3),
      padding: EdgeInsets.all(context.space.s2),
      decoration: BoxDecoration(
        color: changed ? context.colors.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.all(context.radii.sm),
      ),
      child: input,
    );
  }

  static String _choiceLabel(AppLocalizations l10n, String code) => switch (code) {
    'a4' => l10n.settings_printer_format_a4,
    'thermal80' => l10n.settings_printer_format_80mm,
    _ => code,
  };
}

/// Таблица лимитов (UI-46-002, UI-46-013, предупреждение SEC-034).
class _LimitsTable extends StatelessWidget {
  const _LimitsTable({required this.state, required this.onEdit, required this.editable});

  final AdminSettingsState state;
  final void Function(String key, String value) onEdit;
  final bool editable;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final Map<String, String> values = <String, String>{
      for (final RoleCodeKey k in RoleCodeKey.all) ...<String, String>{
        k.limit: state.value(k.limit),
        k.override: state.value(k.override),
      },
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          key: AdminSettingsKeys.onecBanner,
          padding: EdgeInsets.only(bottom: context.space.s3),
          child: ErrorState.banner(message: l10n.admin_settings_onec_rules_banner, tone: ErrorStateTone.info),
        ),
        if (LimitsDraft.overrideWarning(values))
          Padding(
            key: AdminSettingsKeys.overrideWarning,
            padding: EdgeInsets.only(bottom: context.space.s3),
            child: ErrorState.banner(
              message: l10n.admin_settings_limits_override_warning,
              tone: ErrorStateTone.warning,
            ),
          ),
        for (final RoleCode r in discountLimitRoles) _limitRow(context, l10n, r),
      ],
    );
  }

  Widget _limitRow(BuildContext context, AppLocalizations l10n, RoleCode r) {
    final String limitKey = LimitsDraft.limitKey(r);
    final String overrideKey = LimitsDraft.overrideKey(r);
    final String server = state.serverValue(limitKey);
    final String value = state.value(limitKey);
    final bool changed = value.trim() != server.trim() || state.value(overrideKey) != state.serverValue(overrideKey);
    return AnimatedContainer(
      key: AdminSettingsKeys.field(limitKey),
      duration: context.motion.of(context.motion.fast),
      margin: EdgeInsets.only(bottom: context.space.s2),
      padding: EdgeInsets.all(context.space.s2),
      decoration: BoxDecoration(
        color: changed ? context.colors.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.all(context.radii.sm),
      ),
      child: Wrap(
        spacing: context.space.s3,
        runSpacing: context.space.s2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          SizedBox(
            width: 160,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: RoleBadge(role: r),
            ),
          ),
          SizedBox(
            width: 140,
            child: DraftTextField(
              key: ValueKey<String>('admin-settings-input-$limitKey'),
              value: value,
              suffixText: '%',
              semanticLabel: '${AdminLabels.role(l10n, r)} %',
              errorText: AdminSettingsTexts.error(l10n, state.errorOf(limitKey)),
              helper: value.trim() != server.trim() ? l10n.admin_settings_limit_was(server) : null,
              enabled: editable,
              decimal: true,
              onChanged: (String v) => onEdit(limitKey, v),
            ),
          ),
          SizedBox(
            width: 280,
            child: AppCheckbox(
              key: ValueKey<String>('admin-settings-input-$overrideKey'),
              value: state.value(overrideKey) == 'true',
              label: l10n.admin_settings_limit_override,
              onChanged: editable ? (bool? v) => onEdit(overrideKey, '${v ?? false}') : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// Текстовое поле черновика: контроллер синхронизируется со значением состояния, пока поле не в фокусе.
class DraftTextField extends StatefulWidget {
  const DraftTextField({
    required this.value,
    required this.onChanged,
    this.label,
    this.errorText,
    this.helper,
    this.suffixText,
    this.semanticLabel,
    this.enabled = true,
    this.numeric = false,
    this.decimal = false,
    super.key,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final String? label;
  final String? errorText;
  final String? helper;
  final String? suffixText;
  final String? semanticLabel;
  final bool enabled;
  final bool numeric;
  final bool decimal;

  @override
  State<DraftTextField> createState() => _DraftTextFieldState();
}

class _DraftTextFieldState extends State<DraftTextField> {
  late final TextEditingController _controller = TextEditingController(text: widget.value);
  final FocusNode _focus = FocusNode();

  @override
  void didUpdateWidget(DraftTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focus.hasFocus && _controller.text != widget.value) _controller.text = widget.value;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppTextField(
    controller: _controller,
    focusNode: _focus,
    label: widget.label,
    errorText: widget.errorText,
    helper: widget.helper,
    enabled: widget.enabled,
    semanticLabel: widget.semanticLabel,
    suffix: widget.suffixText == null
        ? null
        : Padding(
            padding: EdgeInsetsDirectional.only(end: context.space.s2),
            child: Text(widget.suffixText!, style: context.text.body.copyWith(color: context.colors.textSecondary)),
          ),
    keyboardType: widget.numeric
        ? TextInputType.number
        : widget.decimal
        ? const TextInputType.numberWithOptions(decimal: true)
        : null,
    onChanged: widget.onChanged,
  );
}
