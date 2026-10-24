// Форма приглашения сотрудника (UI-45-009; 02 SCR-45.4, SCR-45.8; ядро v1.9 §24.2; 09 §7.6, REG-022).
// Поля: телефон (обязательно), ФИО (необязательно, 2…150), роль (seller/cashier/senior_seller —
// 11 SEC-136 п.2), «Действует до» (по умолчанию +30 дней, 1…90). `POST /admin/invitations` +
// `Idempotency-Key` (один ключ на набор полей: двойное нажатие → одно приглашение, AC-UI-45-010) + step-up.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_radio.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/phone_field.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/admin/domain/users/invitation.dart';
import 'package:optomstroy/features/admin/domain/users/step_up.dart';
import 'package:optomstroy/features/admin/presentation/users/admin_failure_text.dart';
import 'package:optomstroy/features/admin/presentation/users/admin_users_controller.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/admin_actions.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/admin_labels.dart';

class InviteForm extends ConsumerStatefulWidget {
  const InviteForm({super.key, this.initial});

  /// «Пригласить снова»: роль из прежнего приглашения (телефон — маска, вводится заново).
  final Invitation? initial;

  /// Диалог 480 (expanded/medium) или экран (compact). Результат — созданное приглашение.
  static Future<Invitation?> show(BuildContext context, {Invitation? initial}) {
    final form = InviteForm(initial: initial);
    if (DsBreakpoints.of(context) == WindowClass.compact) {
      return Navigator.of(context).push<Invitation>(
        MaterialPageRoute<Invitation>(
          fullscreenDialog: true,
          builder: (ctx) => Scaffold(
            appBar: AppBar(title: Text(AppLocalizations.of(ctx).admin_invites_title)),
            body: SafeArea(child: form),
          ),
        ),
      );
    }
    return showDialog<Invitation>(
      context: context,
      builder: (ctx) => Dialog(
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: form),
      ),
    );
  }

  @override
  ConsumerState<InviteForm> createState() => _InviteFormState();
}

class _InviteFormState extends ConsumerState<InviteForm> {
  final TextEditingController _phoneText = TextEditingController();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _expiresText = TextEditingController();
  String? _phone;
  RoleCode? _role;
  late DateTime _today;
  DateTime? _expiresAt;
  Set<InvitationDraftError> _errors = const {};
  bool _submitted = false;
  bool _busy = false;
  String? _serverPhoneError;
  String? _formError;

  /// Ключ идемпотентности и набор полей, к которому он относится.
  String? _key;
  String? _keyFor;

  @override
  void initState() {
    super.initState();
    final now = ref.read(clockProvider).nowUtc().toLocal();
    _today = DateTime(now.year, now.month, now.day);
    _expiresAt = InvitationRules.defaultExpiry(_today);
    final initialRole = widget.initial?.roleCodes.firstOrNull;
    _role = initialRole != null && invitableRoles.contains(initialRole) ? initialRole : null;
    _name.addListener(_revalidate);
  }

  @override
  void dispose() {
    _phoneText.dispose();
    _name.dispose();
    _expiresText.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncExpiresText();
  }

  void _syncExpiresText() {
    final locale = Localizations.localeOf(context).toString();
    _expiresText.text = _expiresAt == null ? '' : DateFormat('d MMMM y', locale).format(_expiresAt!);
  }

  void _revalidate() {
    if (_submitted) setState(() => _errors = _validate());
  }

  Set<InvitationDraftError> _validate() => InvitationRules.validate(
    phoneE164: _phone,
    role: _role,
    fullName: _name.text,
    expiresAt: _expiresAt,
    today: _today,
  );

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _expiresAt ?? InvitationRules.defaultExpiry(_today),
      firstDate: InvitationRules.firstExpiry(_today),
      lastDate: InvitationRules.lastExpiry(_today),
    );
    if (picked == null || !mounted) return;
    setState(() => _expiresAt = picked);
    _syncExpiresText();
    _revalidate();
  }

  Future<void> _submit() async {
    if (_busy) return; // двойное нажатие игнорируется
    final l10n = AppLocalizations.of(context);
    final errors = _validate();
    setState(() {
      _submitted = true;
      _errors = errors;
      _serverPhoneError = null;
      _formError = null;
    });
    if (errors.isNotEmpty) return;
    final draft = InvitationDraft(phoneE164: _phone!, role: _role!, fullName: _name.text.trim(), expiresAt: _expiresAt);
    final fingerprint = '${draft.phoneE164}|${draft.role.value}|${draft.fullName}|${draft.expiresAt}';
    if (_keyFor != fingerprint) {
      _key = newIdempotencyKey();
      _keyFor = fingerprint;
    }
    final controller = ref.read(adminUsersControllerProvider.notifier);
    final existing = ref.read(adminUsersControllerProvider).invitations.items.map((i) => i.id).toSet();
    final obtain = adminStepUpObtainer(context, ref);
    setState(() => _busy = true);
    final result = await controller.createInvitation(draft, idempotencyKey: _key!, obtain: obtain);
    if (!mounted) return;
    setState(() => _busy = false);
    switch (result) {
      case ActionDone(:final value):
        final message = value.appliedToUserId != null
            ? l10n.admin_invites_applied_existing
            : existing.contains(value.id)
            ? l10n.admin_invites_updated
            : l10n.admin_invites_created(value.phoneMasked);
        Navigator.of(context).pop(value);
        showAdminSuccess(context, message);
      case ActionFailed(:final failure):
        setState(() {
          if (failure is ConflictFailure && failure.kind == ConflictKind.phoneAlreadyRegistered) {
            // FA-07: номер клиента (`reason: customer_account`) — отдельный текст (Q-312).
            _serverPhoneError = failure.reason == AdminFailureText.customerAccountReason
                ? l10n.admin_invites_error_customer_account
                : l10n.admin_invites_error_registered;
          } else if (failure is ValidationFailure && failure.errors.any((e) => e.field == 'phone')) {
            _serverPhoneError = l10n.admin_invites_error_phone;
          } else {
            _formError = AdminFailureText.of(l10n, failure, context: AdminFailureContext.invitation);
          }
        });
      case ActionCancelled():
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final c = context.colors;
    final caption = context.text.caption.copyWith(color: c.textSecondary);
    final compact = DsBreakpoints.of(context) == WindowClass.compact;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        key: const ValueKey<String>('admin-invite-form'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!compact) ...[
            Text(l10n.admin_invites_title, style: context.text.h3.copyWith(color: c.textPrimary)),
            const SizedBox(height: 4),
          ],
          Text(l10n.admin_invites_staff_only_hint, style: context.text.body.copyWith(color: c.textSecondary)),
          const SizedBox(height: 16),
          PhoneField(
            key: const ValueKey<String>('admin-invite-phone'),
            controller: _phoneText,
            semanticLabel: l10n.auth_phone_a11y,
            label: l10n.admin_invites_phone_label,
            enabled: !_busy,
            errorText:
                _serverPhoneError ??
                (_errors.contains(InvitationDraftError.phone) ? l10n.admin_invites_error_phone : null),
            onChanged: (e164) {
              _phone = e164;
              setState(() => _serverPhoneError = null);
              _revalidate();
            },
          ),
          const SizedBox(height: 16),
          AppTextField(
            key: const ValueKey<String>('admin-invite-name'),
            controller: _name,
            label: l10n.admin_invites_fullname_label,
            maxLength: InvitationRules.fullNameMax,
            enabled: !_busy,
            errorText: _errors.contains(InvitationDraftError.fullName) ? l10n.profile_fullname_error_length : null,
          ),
          const SizedBox(height: 16),
          Text(l10n.admin_users_role_section, style: context.text.label.copyWith(color: c.textPrimary)),
          for (final role in invitableRoles)
            AppRadio<RoleCode>(
              key: ValueKey<String>('admin-invite-role-${role.value}'),
              value: role,
              groupValue: _role,
              label: AdminLabels.role(l10n, role),
              onChanged: _busy
                  ? null
                  : (r) {
                      setState(() => _role = r);
                      _revalidate();
                    },
            ),
          if (_errors.contains(InvitationDraftError.role))
            Text(l10n.admin_invites_error_role, style: context.text.caption.copyWith(color: c.error)),
          const SizedBox(height: 16),
          AppTextField(
            key: const ValueKey<String>('admin-invite-expires'),
            controller: _expiresText,
            label: l10n.admin_invites_expires_label,
            variant: AppTextFieldVariant.readOnly,
            suffix: IconButton(
              tooltip: l10n.admin_invites_expires_label,
              icon: const Icon(Icons.calendar_month_rounded),
              onPressed: _busy ? null : () => unawaited(_pickDate()),
            ),
            errorText: _errors.contains(InvitationDraftError.expiry) ? l10n.admin_invites_error_expiry : null,
          ),
          const SizedBox(height: 8),
          Text(l10n.admin_invites_no_sms_hint, style: caption),
          if (_formError != null) ...[
            const SizedBox(height: 8),
            Text(
              _formError!,
              key: const ValueKey<String>('admin-invite-error'),
              style: context.text.body.copyWith(color: c.error),
            ),
          ],
          const SizedBox(height: 24),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              AppButton(
                label: l10n.ds_button_cancel,
                variant: AppButtonVariant.text,
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
              ),
              AppButton(
                key: const ValueKey<String>('admin-invite-submit'),
                label: l10n.admin_invites_send,
                size: AppButtonSize.l,
                loading: _busy,
                onPressed: () => unawaited(_submit()),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
