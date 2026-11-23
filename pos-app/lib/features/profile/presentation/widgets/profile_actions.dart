// Действия профиля, общие для экрана SCR-41 и листа профиля по аватару шапки телефона (02 SCR-41.3; 15 ADR-122):
// подтверждения выхода и выхода на всех устройствах, мастер смены номера (UI-41-010). Тексты и поведение — прежние
// (до ADR-122 жили в `ProfileScreen`).
import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/profile/domain/entities/user_profile.dart';
import 'package:optomstroy/features/profile/domain/repositories/profile_repository.dart';
import 'package:optomstroy/features/profile/presentation/widgets/phone_change_flow.dart';

/// «Выйти»: подтверждение «Выйти из аккаунта?» (при неотправленных изменениях — предупреждение «Выйти всё равно»).
/// `true` — пользователь подтвердил выход (сам выход — `SessionController.logout` у вызывающего).
/// [session] — контроллер сессии (читается до закрытия листа: `ref` листа после закрытия недоступен).
Future<bool> confirmProfileLogout(BuildContext context, SessionController session) async {
  final AppLocalizations l10n = AppLocalizations.of(context);
  bool unsent = false;
  try {
    unsent = !(await session.pendingLocalChanges()).isEmpty;
  } on Object {
    // Сбой чтения локальной БД не блокирует выход.
  }
  if (!context.mounted) return false;
  return ConfirmDialog.show(
    context,
    title: l10n.profile_logout_confirm,
    message: unsent ? l10n.profile_logout_unsynced_cart : l10n.pending_logout_body,
    confirmLabel: unsent ? l10n.profile_logout_anyway : l10n.profile_logout,
  );
}

/// «Выйти на всех устройствах»: подтверждение (destructive). `true` — подтверждено.
Future<bool> confirmProfileLogoutAll(BuildContext context) {
  final AppLocalizations l10n = AppLocalizations.of(context);
  return ConfirmDialog.show(
    context,
    title: l10n.profile_logout_all,
    message: l10n.profile_logout_all_confirm,
    confirmLabel: l10n.profile_logout_all,
    variant: ConfirmDialogVariant.destructive,
    destructiveCta: true,
  );
}

/// «Сменить номер телефона» (UI-41-010): подтверждение «Получить код» → мастер смены номера (лист на compact, боковая
/// панель 480 на medium+). `true` — номер сменён.
Future<bool> startProfilePhoneChange(BuildContext context, ProfileRepository repository, UserProfile me) async {
  final AppLocalizations l10n = AppLocalizations.of(context);
  final bool go = await ConfirmDialog.show(
    context,
    title: l10n.profile_phone_change,
    message: l10n.profile_phone_change_confirm,
    confirmLabel: l10n.profile_phone_get_code,
  );
  if (!go || !context.mounted) return false;
  final Widget flow = PhoneChangeFlow(repository: repository, currentPhoneE164: me.profile.phoneE164);
  final PhoneChangeResult? done;
  if (context.windowClass == WindowClass.compact) {
    done = await AppBottomSheet.show<PhoneChangeResult>(
      context,
      title: l10n.profile_phone_change,
      body: flow,
      variant: AppBottomSheetVariant.fullHeight,
    );
  } else {
    done = await AppBottomSheet.showSide<PhoneChangeResult>(
      context,
      title: l10n.profile_phone_change,
      width: AppBottomSheet.sideExpanded,
      body: flow,
    );
  }
  return done != null;
}
