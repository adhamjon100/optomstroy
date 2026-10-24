// Шапка рабочего пространства SCR-10/11/12 (зона A, 02 SCR-10.3; 03 §9.57) по классу окна:
// expanded/large — `TopAppBarPos.full` 72 в порядке макета: логотип → «бургер» → `SearchBar.header` →
// часы/дата → профиль → `NotificationBell` крайним справа (AC-UI-10-030); medium — 64 без часов;
// compact — `TopAppBarPos.compact` 56 (знак · заголовок · аватар · колокольчик-точка) + отдельная
// строка `SearchBar.compact`. `SyncIndicator` (03 §9.40) — вне задачи RM-E-007 (EQ-CAT-08).
import 'dart:async';

import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/notification_bell.dart';
import 'package:optomstroy/design_system/components/search_bar.dart';
import 'package:optomstroy/design_system/components/top_app_bar_pos.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_formats.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_logo.dart';

/// Подпись роли (`role_<code>`, 03 §16.2).
String catalogRoleLabel(AppLocalizations l10n, RoleCode? role) => switch (role) {
  RoleCode.seller => l10n.role_seller,
  RoleCode.cashier => l10n.role_cashier,
  RoleCode.seniorSeller => l10n.role_senior_seller,
  RoleCode.admin => l10n.role_admin,
  RoleCode.owner => l10n.role_owner,
  RoleCode.customer => l10n.role_customer,
  RoleCode.integration || null => '',
};

/// Действия шапки (решает экран).
final class CatalogHeaderActions {
  const CatalogHeaderActions({
    required this.onLogo,
    required this.onMenu,
    required this.onScan,
    required this.onNotifications,
    required this.onProfileMenu,
    this.onBack,
    this.onSearchIcon,
  });

  final VoidCallback onLogo;
  final VoidCallback? onMenu;
  final VoidCallback? onScan;
  final VoidCallback onNotifications;
  final void Function(BuildContext anchor) onProfileMenu;

  /// «Назад» (compact SCR-11/12).
  final VoidCallback? onBack;

  /// Иконка поиска в шапке compact SCR-12 (поле поиска — на SCR-11).
  final VoidCallback? onSearchIcon;
}

class CatalogHeader extends ConsumerWidget {
  const CatalogHeader({
    super.key,
    required this.windowClass,
    required this.search,
    required this.actions,
    this.compactTitle,
    this.searchInTopBar = false,
  });

  final WindowClass windowClass;

  /// Поле поиска (`SearchBar.header` / `.compact`) — строит экран (контроллер, debounce).
  final Widget search;
  final CatalogHeaderActions actions;

  /// Заголовок compact («Каталог», имя категории).
  final String? compactTitle;

  /// compact: поле поиска прямо в шапке (SCR-11), иначе — отдельной строкой под ней.
  final bool searchInTopBar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final RoleCode? role = ref.watch(catalogViewerRoleProvider);
    final String? name = ref.watch(catalogViewerNameProvider);
    final int unread = ref.watch(catalogUnreadNotificationsProvider);
    final bool syncError = ref.watch(catalogSyncErrorNotificationProvider);
    final String roleText = catalogRoleLabel(l10n, role);
    final String userName = name ?? roleText;
    final bool compact = windowClass == WindowClass.compact;
    final Widget user = Builder(
      builder: (BuildContext anchor) => TopAppBarUser(
        name: userName,
        role: name == null ? '' : roleText,
        showText: windowClass == WindowClass.expanded || windowClass == WindowClass.large,
        onTap: () => actions.onProfileMenu(anchor),
      ),
    );
    final Widget bell = NotificationBell(
      unreadCount: unread,
      syncError: syncError,
      variant: compact ? NotificationBellVariant.dot : NotificationBellVariant.header,
      semanticLabel: unread > 0 ? l10n.notifications_bell_a11y(unread) : l10n.notifications_title,
      onPressed: actions.onNotifications,
    );
    if (compact) {
      final Widget top = TopAppBarPos(
        variant: TopAppBarVariant.compact,
        windowClass: windowClass,
        leading: actions.onBack == null
            ? null
            : AppIconButton(
                icon: Icons.arrow_back_rounded,
                semanticLabel: MaterialLocalizations.of(context).backButtonTooltip,
                onPressed: actions.onBack,
              ),
        logo: CatalogLogo(markSize: 28, wordmark: false, onTap: actions.onLogo),
        title: compactTitle,
        search: searchInTopBar ? search : null,
        actions: <Widget>[
          if (actions.onSearchIcon != null)
            AppIconButton(
              icon: Icons.search_rounded,
              semanticLabel: l10n.search_title,
              onPressed: actions.onSearchIcon,
            ),
          if (!searchInTopBar) user,
          bell,
        ],
      );
      if (searchInTopBar || actions.onSearchIcon != null) {
        return top;
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          top,
          ColoredBox(
            color: context.colors.surface,
            child: Padding(
              padding: EdgeInsets.fromLTRB(context.space.s4, context.space.s1, context.space.s4, context.space.s1),
              child: search,
            ),
          ),
        ],
      );
    }
    // Вариант `customer` (02 UI-50-001): без часов/даты и `SyncIndicator` — это рабочие элементы staff.
    final bool showClock =
        role != RoleCode.customer && (windowClass == WindowClass.expanded || windowClass == WindowClass.large);
    final WidgetBuilder? syncIndicator = role == RoleCode.customer ? null : ref.watch(catalogSyncIndicatorProvider);
    return TopAppBarPos(
      windowClass: windowClass,
      logo: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CatalogLogo(onTap: actions.onLogo),
          if (actions.onMenu != null) ...<Widget>[
            SizedBox(width: context.space.s6),
            AppIconButton(
              icon: Icons.menu_rounded,
              semanticLabel: l10n.catalog_sidebar_categories_title,
              onPressed: actions.onMenu,
            ),
          ],
        ],
      ),
      search: search,
      actions: <Widget>[
        if (showClock) const CatalogHeaderClock(),
        if (syncIndicator != null) Builder(builder: syncIndicator),
      ],
      user: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          user,
          SizedBox(width: context.space.s4),
          bell,
        ],
      ),
    );
  }
}

/// Часы и дата шапки (UI-10-005, UI-10-032): обновление раз в минуту, время магазина (Бишкек).
class CatalogHeaderClock extends ConsumerStatefulWidget {
  const CatalogHeaderClock({super.key});

  @override
  ConsumerState<CatalogHeaderClock> createState() => _CatalogHeaderClockState();
}

class _CatalogHeaderClockState extends ConsumerState<CatalogHeaderClock> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final DateTime now = ref.watch(clockProvider).nowUtc();
    final String locale = Localizations.localeOf(context).toLanguageTag();
    return TopAppBarClock(time: CatalogFormats.time(now), date: CatalogFormats.headerDate(now, locale));
  }
}

/// Поле поиска товаров для шапки (плейсхолдер `search_placeholder`, кнопка сканера).
class CatalogSearchField extends StatelessWidget {
  const CatalogSearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.windowClass,
    required this.onChanged,
    required this.onSubmitted,
    this.onScan,
    this.loading = false,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final WindowClass windowClass;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback? onScan;
  final bool loading;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return SearchBar(
      key: const ValueKey<String>('catalog-search-field'),
      variant: windowClass == WindowClass.compact ? SearchBarVariant.compact : SearchBarVariant.header,
      controller: controller,
      focusNode: focusNode,
      placeholder: l10n.search_placeholder,
      semanticLabel: l10n.search_title,
      scannerLabel: l10n.search_scanner_tooltip,
      onScan: onScan,
      loading: loading,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      autofocus: autofocus,
    );
  }
}
