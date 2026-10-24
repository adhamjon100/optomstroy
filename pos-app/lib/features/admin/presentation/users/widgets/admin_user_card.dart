// Карточка пользователя SCR-45, зона D (UI-45-004…007, 012, 020, 021, 023).
// Режим `owner` (ядро §21 п.3): просмотр, роли только `admin`/`owner`, «Завершить все сессии»
// только для учётных записей `admin`/`owner`; нет «Сбросить PIN», «Заблокировать», аварийного кода.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_radio.dart';
import 'package:optomstroy/design_system/components/app_tooltip.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/formats/ds_phone_format.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/admin/domain/users/admin_user.dart';
import 'package:optomstroy/features/admin/domain/users/admin_users_policy.dart';
import 'package:optomstroy/features/admin/domain/users/step_up.dart';
import 'package:optomstroy/features/admin/presentation/users/admin_failure_text.dart';
import 'package:optomstroy/features/admin/presentation/users/admin_users_controller.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/admin_actions.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/admin_labels.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/emergency_code_dialog.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/role_badge.dart';

class AdminUserCard extends ConsumerStatefulWidget {
  const AdminUserCard({super.key});

  @override
  ConsumerState<AdminUserCard> createState() => _AdminUserCardState();
}

class _AdminUserCardState extends ConsumerState<AdminUserCard> {
  RoleCode? _draftRole;
  String? _draftFor;

  AdminUsersController get _controller => ref.read(adminUsersControllerProvider.notifier);

  String _name(AdminUser u) => (u.fullName?.trim().isNotEmpty ?? false) ? u.fullName!.trim() : '—';

  String _date(BuildContext context, DateTime? d, {bool time = false}) {
    if (d == null) return '—';
    final locale = Localizations.localeOf(context).toString();
    return DateFormat(time ? 'd MMM, HH:mm' : 'd MMM y', locale).format(d.toLocal());
  }

  Future<void> _saveRole(AdminUser user, RoleCode role) async {
    final l10n = AppLocalizations.of(context);
    final key = newIdempotencyKey();
    final obtain = adminStepUpObtainer(context, ref);
    final old = user.primaryRole;
    final result = await confirmAndRun<AdminUser>(
      context,
      title: l10n.admin_users_role_save,
      message:
          '${l10n.admin_users_role_diff(_name(user), AdminLabels.role(l10n, role), old == null ? '—' : AdminLabels.role(l10n, old))}\n'
          '${l10n.admin_users_effect_hint}',
      confirmLabel: l10n.admin_users_role_save,
      run: (reason) => _controller.changeRole(user, role, reason: reason ?? '', idempotencyKey: key, obtain: obtain),
    );
    if (!mounted || result == null) return;
    switch (result) {
      case ActionDone():
        setState(() => _draftRole = null);
        if (old != role) showAdminSuccess(context, l10n.admin_users_role_saved);
      case ActionFailed(:final failure):
        // VERSION_CONFLICT показывает баннер UI-45-020 над карточкой, без снекбара.
        if (failure is! ConflictFailure || failure.kind != ConflictKind.versionConflict) {
          showAdminFailure(context, result, kind: AdminFailureContext.roles);
        }
      case ActionCancelled():
        break;
    }
  }

  Future<void> _activate(AdminUser user, RoleCode role) async {
    final l10n = AppLocalizations.of(context);
    final key = newIdempotencyKey();
    final obtain = adminStepUpObtainer(context, ref);
    final result = await confirmAndRun<AdminUser>(
      context,
      title: l10n.admin_users_activate,
      message: '${_name(user)} · ${AdminLabels.role(l10n, role)}',
      confirmLabel: l10n.admin_users_activate,
      variant: ConfirmDialogVariant.standard,
      run: (_) => _controller.activate(user, role, idempotencyKey: key, obtain: obtain),
    );
    if (!mounted || result == null) return;
    switch (result) {
      case ActionDone():
        setState(() => _draftRole = null);
        showAdminSuccess(context, l10n.admin_users_activated);
      case ActionFailed():
        showAdminFailure(context, result);
      case ActionCancelled():
        break;
    }
  }

  Future<void> _logoutAll(AdminUser user) async {
    final l10n = AppLocalizations.of(context);
    final key = newIdempotencyKey();
    final obtain = adminStepUpObtainer(context, ref);
    final result = await confirmAndRun<void>(
      context,
      title: l10n.admin_users_revoke_sessions,
      message: _name(user),
      confirmLabel: l10n.admin_users_revoke_sessions,
      destructiveCta: true,
      run: (_) => _controller.logoutAll(user, idempotencyKey: key, obtain: obtain),
    );
    if (!mounted || result == null) return;
    switch (result) {
      case ActionDone():
        showAdminSuccess(context, l10n.admin_users_sessions_revoked);
      case ActionFailed():
        showAdminFailure(context, result);
      case ActionCancelled():
        break;
    }
  }

  Future<void> _resetPin(AdminUser user) async {
    final l10n = AppLocalizations.of(context);
    final obtain = adminStepUpObtainer(context, ref);
    final result = await confirmAndRun<void>(
      context,
      title: l10n.admin_users_reset_pin,
      message: l10n.admin_users_reset_pin_confirm,
      confirmLabel: l10n.admin_users_reset_pin,
      run: (reason) => _controller.resetPin(user, reason: reason ?? '', obtain: obtain),
    );
    if (!mounted || result == null) return;
    switch (result) {
      case ActionDone():
        showAdminSuccess(context, l10n.admin_users_pin_reset);
      case ActionFailed():
        showAdminFailure(context, result);
      case ActionCancelled():
        break;
    }
  }

  Future<void> _toggleBlock(AdminUser user) async {
    final l10n = AppLocalizations.of(context);
    final block = !user.isBlocked;
    final key = newIdempotencyKey();
    final obtain = adminStepUpObtainer(context, ref);
    final result = await confirmAndRun<AdminUser>(
      context,
      title: block ? l10n.admin_users_block : l10n.admin_users_unblock,
      message: block ? l10n.admin_users_block_confirm(_name(user)) : _name(user),
      confirmLabel: block ? l10n.admin_users_block : l10n.admin_users_unblock,
      destructiveCta: block,
      run: (reason) =>
          _controller.setBlocked(user, blocked: block, reason: reason ?? '', idempotencyKey: key, obtain: obtain),
    );
    if (!mounted || result == null) return;
    if (result is ActionFailed<AdminUser>) showAdminFailure(context, result, kind: AdminFailureContext.block);
  }

  Future<void> _emergency(AdminUser user) async {
    final obtain = adminStepUpObtainer(context, ref);
    await EmergencyCodeDialog.show(
      context,
      userName: _name(user),
      issue: (reason, comment) =>
          _controller.issueEmergencyCode(user, reason: reason, comment: comment, obtain: obtain),
    );
  }

  /// Тултип `admin_users_owner_hint` у недоступного радио «Руководитель» (SEC-040).
  Widget _withOwnerHint({required bool show, required String message, required Widget child}) =>
      show ? AppTooltip(message: message, child: child) : child;

  void _openAudit(AdminUser user) {
    final router = GoRouter.maybeOf(context);
    if (router == null) return;
    unawaited(router.push<void>(Uri(path: '/admin/audit', queryParameters: {'userId': user.id}).toString()));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final c = context.colors;
    final state = ref.watch(adminUsersControllerProvider);
    final user = state.selected;
    final policy = state.policy;
    if (user == null || policy == null) {
      if (state.selectedFailure != null) {
        return ErrorState.inline(
          message: AdminFailureText.of(l10n, state.selectedFailure!),
          onRetry: () => unawaited(_controller.refreshSelected()),
        );
      }
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [SkeletonBox.avatar(size: 64), SizedBox(height: 16), SkeletonBox.text(width: 240)],
        ),
      );
    }
    if (_draftFor != user.id || (_draftRole != null && _draftRole == user.primaryRole)) {
      _draftFor = user.id;
      _draftRole = null;
    }
    final selectedRole = _draftRole ?? user.primaryRole;
    final roleOptions = policy.roleOptions(user);
    final canEditRoles = policy.canEditRoles(user);
    final blockReason = policy.rolesBlockReason(user);
    final caption = context.text.caption.copyWith(color: c.textSecondary);
    final phone = user.phone == null ? '—' : (user.hasFullPhone ? DsPhoneFormat.display(user.phone!) : user.phone!);

    // Карточка короткая (≈ 1,5 экрана): все блоки, включая «Устройства и сессии» и «Действия», строятся сразу —
    // кнопки доступны клавиатуре без прокрутки (ленивый список не строил бы их за краем экрана).
    return SingleChildScrollView(
      key: ValueKey<String>('admin-user-card-${user.id}'),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (state.versionConflict) ...[
            ErrorState.banner(
              message: l10n.admin_users_conflict_banner,
              tone: ErrorStateTone.warning,
              onRetry: () => unawaited(_controller.refreshSelected()),
            ),
            const SizedBox(height: 16),
          ],
          // UI-45-004 шапка
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Avatar(name: _name(user), size: 64, disabled: user.isBlocked),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_name(user), style: context.text.h3.copyWith(color: c.textPrimary)),
                    const SizedBox(height: 4),
                    Text(phone, style: context.text.body.copyWith(color: c.textSecondary)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        StatusChip(
                          label: AdminLabels.userStatus(l10n, user.status),
                          variant: AdminLabels.userStatusVariant(user.status),
                        ),
                        RoleBadges(roles: user.roleCodes),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${user.invitation != null ? l10n.admin_users_source_invitation : l10n.admin_users_source_self}'
                      ' · ${_date(context, user.createdAt)}',
                      style: caption,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          // UI-45-005 / UI-45-012 роль
          Text(l10n.admin_users_role_section, style: context.text.title.copyWith(color: c.textPrimary)),
          const SizedBox(height: 8),
          if (user.isPendingActivation && policy.canActivate(user)) ...[
            for (final role in staffRoles.where((r) => r != RoleCode.owner && r != RoleCode.admin))
              AppRadio<RoleCode>(
                key: ValueKey<String>('role-${role.value}'),
                value: role,
                groupValue: _draftRole,
                label: AdminLabels.role(l10n, role),
                onChanged: (r) => setState(() => _draftRole = r),
              ),
            const SizedBox(height: 8),
            AppButton(
              key: const ValueKey<String>('admin-user-activate'),
              label: l10n.admin_users_activate,
              size: AppButtonSize.m,
              onPressed: _draftRole == null ? null : () => unawaited(_activate(user, _draftRole!)),
            ),
          ] else ...[
            for (final option in roleOptions)
              _withOwnerHint(
                show: option.block == RoleOptionBlock.ownerReserved && option.role == RoleCode.owner,
                message: l10n.admin_users_owner_hint,
                child: AppRadio<RoleCode>(
                  key: ValueKey<String>('role-${option.role.value}'),
                  value: option.role,
                  groupValue: selectedRole,
                  label: AdminLabels.role(l10n, option.role),
                  onChanged: canEditRoles && option.enabled ? (r) => setState(() => _draftRole = r) : null,
                ),
              ),
            if (blockReason == RoleOptionBlock.self)
              Text(l10n.admin_users_error_self_demotion, style: caption)
            else if (blockReason == RoleOptionBlock.ownerReserved)
              Text(l10n.admin_users_owner_hint, style: caption),
            if (canEditRoles) ...[
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: AppButton(
                  key: const ValueKey<String>('admin-user-save-role'),
                  label: l10n.admin_users_role_save,
                  size: AppButtonSize.m,
                  onPressed: _draftRole != null && _draftRole != user.primaryRole
                      ? () => unawaited(_saveRole(user, _draftRole!))
                      : null,
                ),
              ),
              const SizedBox(height: 4),
              Text(l10n.admin_users_effect_hint, style: caption.copyWith(color: c.warning)),
            ],
          ],
          const SizedBox(height: 24),
          // UI-45-006 устройства и сессии
          Text(l10n.admin_users_sessions_section, style: context.text.title.copyWith(color: c.textPrimary)),
          const SizedBox(height: 8),
          Text(
            l10n.admin_users_devices(user.devicesCount, _date(context, user.lastLoginAt, time: true)),
            style: context.text.body.copyWith(color: c.textPrimary),
          ),
          if (policy.showsLogoutAll(user)) ...[
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: AppButton(
                key: const ValueKey<String>('admin-user-logout-all'),
                label: l10n.admin_users_revoke_sessions,
                variant: AppButtonVariant.danger,
                size: AppButtonSize.s,
                onPressed: policy.canLogoutAll(user) ? () => unawaited(_logoutAll(user)) : null,
              ),
            ),
          ],
          const SizedBox(height: 24),
          // UI-45-007 / UI-45-023 действия
          Text(l10n.admin_users_actions_section, style: context.text.title.copyWith(color: c.textPrimary)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (policy.showsResetPin)
                AppButton(
                  key: const ValueKey<String>('admin-user-reset-pin'),
                  label: l10n.admin_users_reset_pin,
                  variant: AppButtonVariant.outlined,
                  size: AppButtonSize.s,
                  onPressed: policy.canResetPin(user) ? () => unawaited(_resetPin(user)) : null,
                ),
              if (policy.showsEmergencyCode(user))
                AppButton(
                  key: const ValueKey<String>('admin-user-emergency-code'),
                  label: l10n.admin_users_emergency_code,
                  icon: Icons.key_rounded,
                  variant: AppButtonVariant.outlined,
                  size: AppButtonSize.s,
                  onPressed: () => unawaited(_emergency(user)),
                ),
              if (policy.showsBlock)
                AppButton(
                  key: const ValueKey<String>('admin-user-block'),
                  label: user.isBlocked ? l10n.admin_users_unblock : l10n.admin_users_block,
                  variant: user.isBlocked ? AppButtonVariant.outlined : AppButtonVariant.danger,
                  size: AppButtonSize.s,
                  onPressed: policy.canBlock(user) ? () => unawaited(_toggleBlock(user)) : null,
                ),
              AppButton(
                key: const ValueKey<String>('admin-user-audit'),
                label: l10n.admin_users_audit_link,
                variant: AppButtonVariant.text,
                size: AppButtonSize.s,
                onPressed: () => _openAudit(user),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Аватар с инициалами (`AppAvatar` 03 §9.60 в DS нет — [ДОПУЩЕНИЕ RM-D-010]).
class _Avatar extends StatelessWidget {
  const _Avatar({required this.name, required this.size, this.disabled = false});

  final String name;
  final double size; // money-double: allow — геометрия UI (lp)
  final bool disabled;

  String get _initials {
    final parts = name.split(RegExp(r'\s+')).where((p) => p.isNotEmpty && p != '—').toList();
    if (parts.isEmpty) return '?';
    return parts.take(2).map((p) => p.characters.first.toUpperCase()).join();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: disabled ? c.disabledBg : c.primaryContainer, shape: BoxShape.circle),
        child: Text(
          _initials,
          style: (size >= 64 ? context.text.title : context.text.body).copyWith(
            color: disabled ? c.disabledText : c.primaryText,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// Аватар для строк списка.
class AdminAvatar extends StatelessWidget {
  const AdminAvatar({super.key, required this.name, this.disabled = false});

  final String name;
  final bool disabled;

  @override
  Widget build(BuildContext context) => _Avatar(name: name, size: 40, disabled: disabled);
}
