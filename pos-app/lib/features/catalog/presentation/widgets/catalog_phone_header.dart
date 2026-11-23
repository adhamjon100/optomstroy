// Шапка телефона (compact < 600 lp) на данных каталога — 15 ADR-122 п. 1, 2; 02 §3.1 п. 8; 03 §9.57.1.
// Одна для всех ролей и основных экранов режима: SCR-10 (корень каталога, `CatalogWorkspace`), SCR-50 (главная
// клиента) и корни прочих веток `BottomNavBar` (шапка оболочки `PhoneShellHeader`, app/router/shells). Состав
// слева направо: знак логотипа (главный экран режима) → поле поиска (у сотрудника — со сканером; второй строкой,
// если не помещается) → кнопка корзины с числом позиций (роли с корзиной: не `owner`) → `SyncIndicator` иконкой
// (staff) → колокольчик со счётчиком → аватар с инициалами. Аватар открывает меню профиля нижним листом (порт
// [catalogProfileSheetProvider], фича profile); без порта — прежнее меню аватара.
import 'dart:async';

import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_badge.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/notification_bell.dart';
import 'package:optomstroy/design_system/components/phone_top_bar.dart';
import 'package:optomstroy/design_system/components/top_app_bar_pos.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/presentation/catalog_paths.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/catalog/presentation/providers/customer_mode_ports.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_header.dart' show catalogRoleLabel;
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_logo.dart';

/// Шапка телефона на данных каталога.
class CatalogPhoneHeader extends ConsumerWidget {
  /// Создаёт шапку.
  const CatalogPhoneHeader({
    super.key,
    required this.search,
    required this.onLogo,
    required this.onNotifications,
    required this.onProfileMenu,
  });

  /// Поле поиска (`CatalogSearchField` compact; у сотрудника — с кнопкой сканера).
  final Widget? search;

  /// Логотип — главный экран режима.
  final VoidCallback onLogo;

  /// Колокольчик — SCR-44.
  final VoidCallback onNotifications;

  /// Прежнее меню аватара (если лист профиля не подключён).
  final void Function(BuildContext anchor) onProfileMenu;

  /// Ключ шапки (тесты).
  static const Key headerKey = ValueKey<String>('phone-header');

  /// Ключ кнопки корзины (тесты).
  static const Key cartKey = ValueKey<String>('phone-header-cart');

  /// Ключ аватара (тесты).
  static const Key avatarKey = ValueKey<String>('phone-header-avatar');

  /// Ключ колокольчика (тесты).
  static const Key bellKey = ValueKey<String>('phone-header-bell');

  /// Ключ индикатора синхронизации (тесты).
  static const Key syncKey = ValueKey<String>('phone-header-sync');

  /// Есть ли у роли корзина в шапке телефона (navigation.md G-7: у `owner` `/cart` закрыт; у `customer` — своя).
  static bool roleHasCart(RoleCode? role) => role != RoleCode.owner && role != RoleCode.kiosk;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final RoleCode? role = ref.watch(catalogViewerRoleProvider);
    final String? name = ref.watch(catalogViewerNameProvider);
    final int unread = ref.watch(catalogUnreadNotificationsProvider);
    final bool syncError = ref.watch(catalogSyncErrorNotificationProvider);
    final bool staff = role != RoleCode.customer;
    final WidgetBuilder? syncIndicator = staff ? ref.watch(catalogSyncIndicatorProvider) : null;
    final bool hasCart = roleHasCart(role);
    final int cartCount = hasCart ? (ref.watch(catalogCartDraftCountProvider).value ?? 0) : 0;
    final Future<void> Function(BuildContext, String, String)? sheet = ref.watch(catalogProfileSheetProvider);
    final String roleText = catalogRoleLabel(l10n, role);
    final String userName = name ?? roleText;
    final String userRole = name == null ? '' : roleText;
    return KeyedSubtree(
      key: headerKey,
      child: PhoneTopBar(
        logo: const CatalogLogo.header(wordmark: false),
        logoLabel: l10n.splash_logo_a11y,
        onLogo: onLogo,
        search: search,
        actions: <Widget>[
          if (hasCart)
            AppIconButton(
              key: cartKey,
              icon: Icons.shopping_cart_outlined,
              semanticLabel: cartCount > 0 ? l10n.cart_fab_a11y_nototal(cartCount) : l10n.cart_title,
              tooltip: l10n.cart_title,
              onPressed: () => GoRouter.maybeOf(context)?.go(CatalogPaths.cart),
              badge: cartCount > 0 ? AppBadge(count: cartCount, tone: AppBadgeTone.cart) : null,
            ),
          if (syncIndicator != null)
            // Цель касания — 48, как у соседних элементов (ADR-122 п. 7; 03 §9.57.1): `SyncIndicator` сам даёт 44.
            ConstrainedBox(
              key: syncKey,
              constraints: BoxConstraints(minWidth: context.space.s9, minHeight: context.space.s9),
              child: Builder(builder: syncIndicator),
            ),
        ],
        bell: KeyedSubtree(
          key: bellKey,
          child: NotificationBell(
            unreadCount: unread,
            syncError: syncError,
            variant: NotificationBellVariant.header,
            semanticLabel: unread > 0 ? l10n.notifications_bell_a11y(unread) : l10n.notifications_title,
            onPressed: onNotifications,
          ),
        ),
        user: Builder(
          builder: (BuildContext anchor) => TopAppBarUser(
            key: avatarKey,
            name: userName,
            role: userRole,
            showText: false,
            initials: TopAppBarUser.initialsOf(userName),
            semanticLabel: userRole.isEmpty
                ? l10n.profile_avatar_a11y_name(userName)
                : l10n.profile_avatar_a11y(userName, userRole),
            onTap: () => sheet == null ? onProfileMenu(anchor) : unawaited(sheet(context, userName, roleText)),
          ),
        ),
      ),
    );
  }
}
