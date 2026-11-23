// Пункты профиля — один список для экрана SCR-41 и меню профиля по аватару шапки телефона (02 SCR-41.3, UI-41-003;
// 15 ADR-122 п. 2). Порядок: «История заказов» (SCR-25 со своими заказами `?mine=1`; у держателей `order.read.all` на
// SCR-25 остаётся переключатель «Мои / Все») → «Избранное» (SCR-40: «Товары»; вкладка «Клиенты» — по роли, как на
// SCR-40) → прежние пункты в прежнем порядке и по прежним правам: «Мои транзакции» (staff с `transactions.read.*`),
// «Уведомления», «Синхронизация» (staff), «Настройки», «Сменить номер телефона» (когда профиль загружен), «Заблокировать»
// (staff) → разделитель → «Выйти», «Выйти на всех устройствах». Порядок телефона ([phoneOrder]) — лист профиля и
// SCR-41 на compact; на medium и шире SCR-41 не меняется (ADR-122 п. 8): первым — прежний «Мои заказы», без
// «Избранного» (оно — в drawer навигации и вкладкой). Ключи пунктов — `{keyPrefix}-orders` и т. д.: у
// экрана — `profile-…` (как прежде), у листа — `profile-sheet-…`.
import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_list_tile.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';

/// Переход пункта профиля: адрес и способ (`push` — экран поверх текущего, иначе `go`).
typedef ProfileMenuNavigate = void Function(String location, bool push);

/// Адреса пунктов профиля (02 SCR-41.3).
abstract final class ProfileMenuLocations {
  /// SCR-25 со своими заказами (`mine=1`; держатель `order.read.all` переключает «Мои / Все» на самом экране).
  static const String orderHistory = '/orders?mine=1';

  /// SCR-40 «Избранное» (вкладка «Товары»; «Клиенты» — по роли на самом экране).
  static const String favorites = '/favorites';

  /// SCR-36 со своими транзакциями.
  static const String transactions = '/transactions?mine=1';

  /// SCR-44.
  static const String notifications = '/notifications';

  /// SCR-43.
  static const String sync = '/sync';

  /// SCR-42.
  static const String settings = '/settings';

  /// SCR-41.
  static const String profile = '/profile';
}

/// Список пунктов профиля (SCR-41 и лист профиля, ADR-122).
class ProfileMenuList extends StatelessWidget {
  /// Создаёт список.
  const ProfileMenuList({
    super.key,
    required this.staff,
    required this.showTransactions,
    required this.online,
    required this.loggingOut,
    required this.onNavigate,
    required this.onLogout,
    required this.onLogoutAll,
    this.onPhoneChange,
    this.onLock,
    this.keyPrefix = 'profile',
    this.phoneOrder = true,
  });

  /// Порядок телефона (ADR-122): «История заказов», «Избранное», затем прежние пункты; `false` — прежний список SCR-41
  /// на medium и шире («Мои заказы» первым, без «Избранного»).
  final bool phoneOrder;

  /// Сотрудник (пункты «Синхронизация»; «Заблокировать» — по [onLock]).
  final bool staff;

  /// «Мои транзакции» (staff с `transactions.read.*`).
  final bool showTransactions;

  /// Есть сеть (смена номера и «Выйти на всех устройствах» — только онлайн).
  final bool online;

  /// Идёт выход — пункты выхода недоступны.
  final bool loggingOut;

  /// Переход по пункту.
  final ProfileMenuNavigate onNavigate;

  /// «Выйти».
  final VoidCallback onLogout;

  /// «Выйти на всех устройствах».
  final VoidCallback onLogoutAll;

  /// «Сменить номер телефона»; `null` — пункта нет (профиль не загружен).
  final VoidCallback? onPhoneChange;

  /// «Заблокировать» (staff); `null` — пункта нет.
  final VoidCallback? onLock;

  /// Префикс ключей пунктов (`profile` — экран SCR-41, `profile-sheet` — лист).
  final String keyPrefix;

  Key _key(String name) => ValueKey<String>('$keyPrefix-$name');

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppListTile(
          key: _key('orders'),
          title: phoneOrder ? l10n.profile_menu_order_history : l10n.profile_menu_my_orders,
          leadingIcon: Icons.receipt_outlined,
          showChevron: true,
          onTap: () => onNavigate(ProfileMenuLocations.orderHistory, false),
        ),
        if (phoneOrder)
          AppListTile(
            key: _key('favorites'),
            title: l10n.profile_menu_favorites,
            leadingIcon: Icons.star_border,
            showChevron: true,
            onTap: () => onNavigate(ProfileMenuLocations.favorites, false),
          ),
        if (staff && showTransactions)
          AppListTile(
            key: _key('transactions'),
            title: l10n.profile_menu_my_transactions,
            leadingIcon: Icons.swap_horiz_rounded,
            showChevron: true,
            onTap: () => onNavigate(ProfileMenuLocations.transactions, false),
          ),
        AppListTile(
          key: _key('notifications'),
          title: l10n.profile_menu_notifications,
          leadingIcon: Icons.notifications_outlined,
          showChevron: true,
          onTap: () => onNavigate(ProfileMenuLocations.notifications, true),
        ),
        if (staff)
          AppListTile(
            key: _key('sync'),
            title: l10n.profile_menu_sync,
            leadingIcon: Icons.sync_rounded,
            showChevron: true,
            onTap: () => onNavigate(ProfileMenuLocations.sync, true),
          ),
        AppListTile(
          key: _key('settings'),
          title: l10n.profile_menu_settings,
          leadingIcon: Icons.settings_outlined,
          showChevron: true,
          onTap: () => onNavigate(ProfileMenuLocations.settings, true),
        ),
        if (onPhoneChange != null)
          AppListTile(
            key: _key('phone-change'),
            title: l10n.profile_phone_change,
            subtitle: online ? null : l10n.profile_offline_action_disabled,
            leadingIcon: Icons.phone_iphone_rounded,
            showChevron: true,
            enabled: online,
            onTap: online ? onPhoneChange : null,
          ),
        if (staff && onLock != null)
          AppListTile(
            key: _key('lock'),
            title: l10n.profile_menu_lock,
            leadingIcon: Icons.lock_outline_rounded,
            onTap: onLock,
          ),
        Divider(height: 1, color: context.colors.border),
        AppListTile(
          key: _key('logout'),
          title: l10n.profile_logout,
          leading: Icon(Icons.logout_rounded, color: context.colors.error),
          enabled: !loggingOut,
          onTap: loggingOut ? null : onLogout,
        ),
        AppListTile(
          key: _key('logout-all'),
          title: l10n.profile_logout_all,
          subtitle: online ? null : l10n.profile_offline_action_disabled,
          leading: Icon(Icons.logout_rounded, color: context.colors.error),
          enabled: online && !loggingOut,
          onTap: online && !loggingOut ? onLogoutAll : null,
        ),
      ],
    );
  }
}
