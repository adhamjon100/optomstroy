// «Выйти» из меню профиля шапки (02 SCR-10.3 A9, UI-10-033; SCR-10.4.A; SCR-50) и предупреждение
// FLOW-009.E1 (04): перед выходом проверяются неотправленные изменения владельца (`pendingLocalChanges`):
// черновик корзины / очередь `outbox_actions` остаются в файле пользователя и уйдут при его следующем входе.
// ConfirmDialog — фокус на «Отмена» (компонент DS); выход — `SessionController.logout()` (`POST /auth/logout`).
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';

/// Подтвердить выход и выйти. Возвращает `true`, если выход выполнен.
Future<bool> confirmCatalogLogout(BuildContext context, WidgetRef ref) async {
  final AppLocalizations l10n = AppLocalizations.of(context);
  final SessionController session = ref.read(sessionControllerProvider.notifier);
  bool unsent = false;
  try {
    unsent = !(await session.pendingLocalChanges()).isEmpty;
  } on Object {
    // Сбой чтения локальной БД не блокирует выход: предупреждение не показывается.
  }
  if (!context.mounted) {
    return false;
  }
  final bool ok = await ConfirmDialog.show(
    context,
    title: l10n.catalog_profile_logout_confirm,
    message: unsent ? l10n.profile_logout_unsynced_cart : l10n.pending_logout_body,
    confirmLabel: unsent ? l10n.profile_logout_anyway : l10n.profile_logout,
  );
  if (!ok || !context.mounted) {
    return false;
  }
  await session.logout();
  return true;
}
