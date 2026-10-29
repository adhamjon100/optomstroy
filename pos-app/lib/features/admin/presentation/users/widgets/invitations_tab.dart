// Вкладка «Приглашения» (UI-45-010, UI-45-011, UI-45-016). `owner` — только чтение, без меню
// «Отозвать»/«Пригласить снова» (AC-UI-45-009).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/admin/domain/users/invitation.dart';
import 'package:optomstroy/features/admin/domain/users/step_up.dart';
import 'package:optomstroy/features/admin/presentation/common/admin_format.dart';
import 'package:optomstroy/features/admin/presentation/users/admin_failure_text.dart';
import 'package:optomstroy/features/admin/presentation/users/admin_users_controller.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/admin_actions.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/admin_labels.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/invite_form.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/role_badge.dart';

class InvitationsTab extends ConsumerWidget {
  const InvitationsTab({super.key});

  Future<void> _revoke(BuildContext context, WidgetRef ref, Invitation invitation) async {
    final l10n = AppLocalizations.of(context);
    final obtain = adminStepUpObtainer(context, ref);
    final controller = ref.read(adminUsersControllerProvider.notifier);
    final result = await confirmAndRun<void>(
      context,
      title: l10n.admin_invites_revoke,
      message: invitation.phoneMasked,
      confirmLabel: l10n.admin_invites_revoke,
      variant: ConfirmDialogVariant.destructive,
      run: (_) => controller.revokeInvitation(invitation, obtain: obtain),
    );
    if (result is ActionFailed<void> && context.mounted) showAdminFailure(context, result);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(adminUsersControllerProvider);
    final slice = state.invitations;
    final manage = state.policy?.canManageInvitations ?? false;
    if (slice.loading && slice.items.isEmpty) {
      return ListView(
        children: [for (var i = 0; i < 6; i++) const Padding(padding: EdgeInsets.all(16), child: SkeletonBox.text())],
      );
    }
    if (slice.failure != null && slice.items.isEmpty) {
      return Center(
        child: ErrorState.inline(
          message: AdminFailureText.of(l10n, slice.failure!),
          onRetry: () => unawaited(ref.read(adminUsersControllerProvider.notifier).reloadInvitations()),
        ),
      );
    }
    if (slice.items.isEmpty) {
      return EmptyState(
        variant: EmptyStateVariant.search,
        title: l10n.admin_invites_empty,
        actionLabel: manage ? l10n.admin_users_invite_button : null,
        onAction: manage ? () => unawaited(InviteForm.show(context)) : null,
      );
    }
    return ListView.separated(
      key: const ValueKey<String>('admin-invitations-list'),
      itemCount: slice.items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) => _InvitationRow(
        invitation: slice.items[i],
        manage: manage,
        onRevoke: (inv) => unawaited(_revoke(context, ref, inv)),
        onRenew: (inv) => unawaited(InviteForm.show(context, initial: inv)),
      ),
    );
  }
}

class _InvitationRow extends StatelessWidget {
  const _InvitationRow({required this.invitation, required this.manage, required this.onRevoke, required this.onRenew});

  final Invitation invitation;
  final bool manage;
  final ValueChanged<Invitation> onRevoke;
  final ValueChanged<Invitation> onRenew;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final c = context.colors;
    final locale = Localizations.localeOf(context).toString();
    final date = DateFormat('d MMM', locale);
    final caption = context.text.caption.copyWith(color: c.textSecondary);
    final meta = [
      if (invitation.createdByName != null || invitation.createdAt != null)
        [
          invitation.createdByName,
          if (invitation.createdAt != null) date.format(AdminFormat.wall(invitation.createdAt!)),
        ].whereType<String>().join(' · '),
      if (invitation.expiresAt != null && invitation.isPending)
        '${l10n.admin_invites_expires_label} ${date.format(AdminFormat.wall(invitation.expiresAt!))}',
    ].join(' · ');
    return Padding(
      key: ValueKey<String>('admin-invitation-${invitation.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(invitation.phoneMasked, style: context.text.body.copyWith(color: c.textPrimary)),
                const SizedBox(height: 4),
                RoleBadges(roles: invitation.roleCodes),
                if (meta.isNotEmpty) ...[const SizedBox(height: 4), Text(meta, style: caption)],
              ],
            ),
          ),
          StatusChip(
            label: AdminLabels.invitationStatus(l10n, invitation.status),
            variant: AdminLabels.invitationStatusVariant(invitation.status),
          ),
          if (manage && invitation.isPending) ...[
            const SizedBox(width: 8),
            AppButton(
              key: ValueKey<String>('admin-invitation-revoke-${invitation.id}'),
              label: l10n.admin_invites_revoke,
              variant: AppButtonVariant.danger,
              size: AppButtonSize.s,
              onPressed: () => onRevoke(invitation),
            ),
          ],
          if (manage && invitation.canBeRenewed) ...[
            const SizedBox(width: 8),
            AppButton(
              key: ValueKey<String>('admin-invitation-renew-${invitation.id}'),
              label: l10n.admin_invites_again,
              variant: AppButtonVariant.outlined,
              size: AppButtonSize.s,
              onPressed: () => onRenew(invitation),
            ),
          ],
        ],
      ),
    );
  }
}
