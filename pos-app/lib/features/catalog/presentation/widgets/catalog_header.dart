// Шапка рабочего пространства SCR-10/11/12 (зона A, 02 SCR-10.3; 03 §9.57) по классу окна:
// medium/expanded/large — `TopAppBarPos.full` 68 по прототипу 2026-10-29 (ADR-112): «бургер» (drawer навигации
// оболочки) → логотип (знак 38 + «Оптомстрой») → `SearchBar.header` от логотипа (240…680) → справа `SyncIndicator`
// → кнопка-итог корзины (роли с корзиной) → часы и дата сотрудника (UI-10-005, UI-10-032; на «Кассе» — полная дата,
// UI-30-013) → `NotificationBell` → аватар с именем и ролью. Необязательное (строка «Корзина · N шт», роль, имя,
// «Оптомстрой», дата) шапка сворачивает по доступной ширине, а не по классу окна (`TopAppBarFit`, 02 §3.1 п. 7,
// ADR-112 «паритет функций, раунд 2»): свёрнутое — в тултипах, `Semantics` и заголовке меню аватара.
// compact — `TopAppBarPos.compact` 56 (знак · заголовок · аватар · колокольчик-точка) + отдельная строка
// `SearchBar.compact` — без изменений.
// Тот же класс рисует шапку оболочки на прочих экранах сотрудника (`StaffShellHeader`, app/router/shells).
import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/date_range_picker.dart' show DsBishkekTime;
import 'package:optomstroy/design_system/components/notification_bell.dart';
import 'package:optomstroy/design_system/components/search_bar.dart';
import 'package:optomstroy/design_system/components/top_app_bar_pos.dart';
import 'package:optomstroy/design_system/layout/content_region.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/presentation/catalog_paths.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
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

/// Есть ли у роли корзина (кнопка-итог в шапке; navigation.md G-7: у owner `/cart` закрыт, у customer — своя шапка).
bool catalogRoleHasCart(RoleCode? role) => role != RoleCode.owner && role != RoleCode.customer;

/// Колокольчик шапки и `Ctrl+Shift+N` (UI-10-007, 02 SCR-44.6, §3.8): на expanded/large — popover центра уведомлений
/// (если подключён), иначе — экран SCR-44 поверх текущего (`push`). Одно правило для шапки каталога, шапки оболочки
/// и оболочки.
void openCatalogNotifications(BuildContext context, WidgetRef ref, WindowClass windowClass) {
  final Future<void> Function(BuildContext)? popover = ref.read(catalogNotificationsPopoverProvider);
  if ((windowClass == WindowClass.expanded || windowClass == WindowClass.large) && popover != null) {
    unawaited(popover(context));
  } else {
    unawaited(GoRouter.maybeOf(context)?.push<Object?>(CatalogPaths.notifications));
  }
}

/// Кнопка сканера в поле поиска шапки (UI-10-044): Android/iOS — SCR-17 (`push`); Windows — камеры нет (D-42):
/// подсказка HID-сканера и фокус в поле [searchFocus]. Одно правило для шапки каталога и шапки оболочки.
void handleCatalogScanButton(BuildContext context, FocusNode searchFocus) {
  if (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS) {
    unawaited(GoRouter.maybeOf(context)?.push<Object?>(CatalogPaths.scan()));
    return;
  }
  searchFocus.requestFocus();
  AppSnackbar.show(context, message: AppLocalizations.of(context).catalog_scanner_hid_hint);
}

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

  /// «Бургер» medium+ — drawer навигации оболочки (`DsShellScope.openNavigation`); `null` — кнопки нет
  /// (compact, клиент, экран вне оболочки).
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
    this.clockLongDate = false,
  });

  final WindowClass windowClass;

  /// Поле поиска (`SearchBar.header` / `.compact`) — строит экран (контроллер, debounce).
  final Widget search;
  final CatalogHeaderActions actions;

  /// Заголовок compact («Каталог», имя категории).
  final String? compactTitle;

  /// compact: поле поиска прямо в шапке (SCR-11), иначе — отдельной строкой под ней.
  final bool searchInTopBar;

  /// Дата часов — «Пн, 29 июня 2026» (шапка оболочки на ветке «Касса», AC-UI-30-020), иначе «пн, 29 июн» (UI-10-032).
  final bool clockLongDate;

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
    final String userRole = name == null ? '' : roleText;
    final Widget user = Builder(
      builder: (BuildContext anchor) => TopAppBarUser(
        name: userName,
        role: userRole,
        // medium+: имя и роль; не хватает места — сначала только имя (не шире 96), затем только аватар
        // (`TopAppBarFit`, ADR-112). compact — только аватар. Полностью они — в заголовке меню аватара и в
        // `Semantics` (02 A8, SRC-C-004a).
        showText: !compact,
        semanticLabel: userRole.isEmpty
            ? l10n.profile_avatar_a11y_name(userName)
            : l10n.profile_avatar_a11y(userName, userRole),
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
              semanticLabel: l10n.search_field_a11y,
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
    // Вариант `customer` (02 UI-50-001): без «бургера», `SyncIndicator`, корзины и часов в шапке — рабочие элементы
    // staff.
    final bool staff = role != RoleCode.customer;
    final WidgetBuilder? syncIndicator = staff ? ref.watch(catalogSyncIndicatorProvider) : null;
    final WidgetBuilder? cartButton = staff && catalogRoleHasCart(role) ? ref.watch(catalogCartButtonProvider) : null;
    return TopAppBarPos(
      windowClass: windowClass,
      onMenu: staff ? actions.onMenu : null,
      menuLabel: l10n.shell_menu_open,
      // «Оптомстрой» шапка сворачивает по ширине (`TopAppBarFit.wordmark`) — остаётся знак.
      logo: CatalogLogo.header(onTap: actions.onLogo),
      search: search,
      actions: <Widget>[
        if (syncIndicator != null) Builder(builder: syncIndicator),
        // Сквозная область (02 SCR-14.2 ред. 1.16, ADR-112): при открытой панели SCR-14 кнопка-итог открывает drawer
        // корзины поверх панели и панель не закрывает.
        if (cartButton != null) DsPanelPassThrough(child: Builder(builder: cartButton)),
        // Часы и дата (UI-10-005, UI-10-032; на ветке «Касса» — UI-30-013): компактный вторичный текст перед
        // колокольчиком; дата сворачивается последней (на «Кассе» — сначала до короткой «чт, 22 окт»), свёрнутая — в
        // тултипе и `Semantics`.
        if (staff) CatalogHeaderClock(longDate: clockLongDate),
      ],
      bell: bell,
      user: user,
    );
  }
}

/// Часы и дата шапки сотрудника (02 UI-10-005, UI-10-032; на SCR-30 — UI-30-013, AC-UI-30-020): время магазина
/// (Asia/Bishkek) из `clockProvider`, перерисовка по границе минуты. [longDate] — «Пн, 29 июня 2026» (шапке не
/// хватает места — короткая «пн, 29 июн»), иначе «пн, 29 июн»; [timeOnly] — только время, дата — в тултипе и
/// `Semantics`. Дату по ширине сворачивает шапка (`TopAppBarFit.date`).
class CatalogHeaderClock extends ConsumerStatefulWidget {
  const CatalogHeaderClock({super.key, this.longDate = false, this.timeOnly = false});

  /// Ключ часов (тесты).
  static const Key clockKey = ValueKey<String>('header-clock');

  final bool longDate;
  final bool timeOnly;

  @override
  ConsumerState<CatalogHeaderClock> createState() => _CatalogHeaderClockState();
}

class _CatalogHeaderClockState extends ConsumerState<CatalogHeaderClock> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  /// Следующая перерисовка — на границе минуты по часам приложения (не каждую секунду).
  void _schedule() {
    _timer?.cancel();
    final int ms = ref.read(clockProvider).nowUtc().millisecondsSinceEpoch;
    final int rest = Duration.millisecondsPerMinute - ms % Duration.millisecondsPerMinute;
    _timer = Timer(Duration(milliseconds: rest), () {
      if (!mounted) {
        return;
      }
      setState(() {});
      _schedule();
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
    return TopAppBarClock(
      key: CatalogHeaderClock.clockKey,
      time: DsBishkekTime.time(now),
      date: widget.longDate ? DsBishkekTime.headerDate(now, locale) : DsBishkekTime.headerDateShort(now, locale),
      shortDate: widget.longDate ? DsBishkekTime.headerDateShort(now, locale) : null,
      timeOnly: widget.timeOnly,
    );
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
    this.fieldKey = defaultFieldKey,
  });

  /// Ключ поля в шапке каталога (тесты, integration_test).
  static const Key defaultFieldKey = ValueKey<String>('catalog-search-field');

  final TextEditingController controller;
  final FocusNode focusNode;
  final WindowClass windowClass;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback? onScan;
  final bool loading;
  final bool autofocus;

  /// Ключ `SearchBar` (шапка оболочки — свой, чтобы на ветке каталога поле было одно).
  final Key fieldKey;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return SearchBar(
      key: fieldKey,
      variant: windowClass == WindowClass.compact ? SearchBarVariant.compact : SearchBarVariant.header,
      controller: controller,
      focusNode: focusNode,
      placeholder: l10n.search_placeholder,
      // Поле ввода — «Поиск товара» (03 §9.7), не «Результаты поиска»: шапка стоит на всех экранах сотрудника.
      semanticLabel: l10n.search_field_a11y,
      scannerLabel: l10n.search_scanner_tooltip,
      onScan: onScan,
      loading: loading,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      autofocus: autofocus,
    );
  }
}
