// Подписи и варианты чипов SCR-45 (ARB `role_<code>`, `status_user_*`, `status_invitation_*`; 03 §9.39, §9.61).
import 'package:flutter/material.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';

abstract final class AdminLabels {
  static String role(AppLocalizations l10n, RoleCode role) => switch (role) {
    RoleCode.seller => l10n.role_seller,
    RoleCode.cashier => l10n.role_cashier,
    RoleCode.seniorSeller => l10n.role_senior_seller,
    RoleCode.admin => l10n.role_admin,
    RoleCode.owner => l10n.role_owner,
    RoleCode.customer => l10n.role_customer,
    RoleCode.integration => l10n.role_integration,
  };

  /// Неизвестная роль показывается кодом (совместимость вперёд, 08 §2.11).
  static String roleRaw(AppLocalizations l10n, String value) {
    final code = RoleCode.tryParse(value);
    return code == null ? value : role(l10n, code);
  }

  /// Иконки ролей (03 §14 карта иконок).
  static IconData roleIcon(RoleCode role) => switch (role) {
    RoleCode.seller => Icons.storefront_rounded,
    RoleCode.cashier => Icons.point_of_sale_rounded,
    RoleCode.seniorSeller => Icons.workspace_premium_rounded,
    RoleCode.admin => Icons.admin_panel_settings_rounded,
    RoleCode.owner => Icons.verified_user_rounded,
    RoleCode.customer => Icons.person_rounded,
    RoleCode.integration => Icons.settings_ethernet_rounded,
  };

  static String userStatus(AppLocalizations l10n, String value) => switch (UserStatus.tryParse(value)) {
    UserStatus.pending => l10n.status_user_pending,
    UserStatus.pendingActivation => l10n.status_user_pending_activation,
    UserStatus.active => l10n.status_user_active,
    UserStatus.blocked => l10n.status_user_blocked,
    UserStatus.deleted => l10n.status_user_deleted,
    null => value,
  };

  static StatusChipVariant userStatusVariant(String value) => switch (UserStatus.tryParse(value)) {
    UserStatus.active => StatusChipVariant.success,
    UserStatus.pendingActivation => StatusChipVariant.warning,
    UserStatus.pending => StatusChipVariant.info,
    UserStatus.blocked => StatusChipVariant.error,
    UserStatus.deleted || null => StatusChipVariant.neutral,
  };

  static String invitationStatus(AppLocalizations l10n, String value) => switch (InvitationStatus.tryParse(value)) {
    InvitationStatus.pending => l10n.status_invitation_pending,
    InvitationStatus.accepted => l10n.status_invitation_accepted,
    InvitationStatus.revoked => l10n.status_invitation_revoked,
    InvitationStatus.expired => l10n.status_invitation_expired,
    null => value,
  };

  static StatusChipVariant invitationStatusVariant(String value) => switch (InvitationStatus.tryParse(value)) {
    InvitationStatus.pending => StatusChipVariant.info,
    InvitationStatus.accepted => StatusChipVariant.success,
    InvitationStatus.revoked || InvitationStatus.expired || null => StatusChipVariant.neutral,
  };

  /// `StatusChip` привязки (03 §9.39; ключи `status_link_*` — 03 §16.7, D FA-03).
  static String linkStatus(AppLocalizations l10n, String value) => switch (CustomerLinkStatus.tryParse(value)) {
    CustomerLinkStatus.proposed => l10n.status_link_proposed,
    CustomerLinkStatus.conflict => l10n.status_link_conflict,
    CustomerLinkStatus.confirmed => l10n.status_link_confirmed,
    CustomerLinkStatus.rejected => l10n.status_link_rejected,
    null => value,
  };

  static StatusChipVariant linkStatusVariant(String value) =>
      StatusChipMapping.variantOf('link', value) ?? StatusChipVariant.neutral;
}
