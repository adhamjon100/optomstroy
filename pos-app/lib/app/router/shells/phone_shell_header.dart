// Шапка телефона оболочки (compact < 600 lp; 15 ADR-122 п. 1; 02 §3.1 п. 8): на корнях веток `BottomNavBar`, кроме
// «Каталога» (SCR-10 рисует её сам — одно поле поиска, ADR-110) и главной клиента SCR-50 (рисует сама). Та же шапка
// `CatalogPhoneHeader`, что у каталога: логотип → главный экран режима; поиск — у сотрудника со сканером, ведёт в
// SCR-11 (`/catalog/search?q=`) по Enter или после паузы ввода, ввод продолжается в поле каталога; у клиента — без
// камеры, SCR-11 поверх (`push`, как на SCR-50); кнопка корзины, синхронизация, колокольчик (SCR-44), аватар → лист
// профиля. Экран под шапкой оставляет свою строку заголовка с действиями (функции не теряются, ADR-112).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/app_router.dart' show homeLocationFor;
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/core/hardware/hardware_providers.dart' show cameraScannerSupportedProvider;
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/catalog/presentation/catalog_paths.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/catalog/presentation/state/search_input_policy.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_header.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_phone_header.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_profile_menu.dart';

/// Корни веток, над которыми оболочка рисует шапку телефона (каталог и главная клиента рисуют её сами). В ветке
/// «Админ» разделы SCR-46 `/admin/settings`, SCR-47 `/admin/audit` и SCR-54 `/admin/tablets` — на одном уровне с
/// `/admin/users` (переход `AdminNavMenu` → `go`, без «Назад»), поэтому шапка на них та же.
const Set<String> phoneShellHeaderRoots = <String>{
  '/favorites',
  '/cart',
  '/customers',
  '/cashier',
  '/transactions',
  '/orders',
  '/admin/users',
  '/admin/settings',
  '/admin/audit',
  '/admin/tablets',
  '/profile',
  '/reports',
};

/// Нужна ли шапка телефона оболочки на адресе [path] (верхний маршрут стека) в классе окна [windowClass].
bool phoneShellHeaderAt(String path, WindowClass windowClass) =>
    windowClass == WindowClass.compact && phoneShellHeaderRoots.contains(path);

/// Шапка телефона оболочки.
class PhoneShellHeader extends ConsumerStatefulWidget {
  /// Создаёт шапку.
  const PhoneShellHeader({super.key, required this.mode});

  /// Режим оболочки.
  final AppMode mode;

  /// Ключ поля поиска шапки оболочки (у поля каталога — `catalog-search-field`).
  static const Key searchFieldKey = ValueKey<String>('phone-shell-search-field');

  @override
  ConsumerState<PhoneShellHeader> createState() => _PhoneShellHeaderState();
}

class _PhoneShellHeaderState extends ConsumerState<PhoneShellHeader> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode(debugLabel: 'PhoneShellHeader.search');
  late final SearchInputController _input = SearchInputController(onQuery: _search);

  @override
  void dispose() {
    _input.dispose();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool get _customer => widget.mode == AppMode.customer;

  /// Допустимая строка → SCR-11: сотрудник — переход в ветку каталога (как шапка medium+), клиент — поверх (`push`,
  /// как SCR-50). Поле очищается: запрос продолжается в поле SCR-11.
  void _search(String q) {
    final GoRouter? router = GoRouter.maybeOf(context);
    if (router == null || _text.text.trim() != q.trim()) {
      return;
    }
    _text.clear();
    _input.reset('');
    _focus.unfocus();
    if (_customer) {
      unawaited(router.push<Object?>(CatalogPaths.search(q: q)));
      return;
    }
    final ProviderContainer container = ProviderScope.containerOf(context, listen: false);
    router.go(CatalogPaths.search(q: q));
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => container.read(catalogSearchFocusRequestProvider.notifier).request(),
    );
  }

  void _onScan() => handleCatalogScanButton(context, _focus, cameraSupported: ref.read(cameraScannerSupportedProvider));

  void _push(String location) => unawaited(GoRouter.maybeOf(context)?.push<Object?>(location));

  @override
  Widget build(BuildContext context) {
    return CatalogPhoneHeader(
      search: CatalogSearchField(
        fieldKey: PhoneShellHeader.searchFieldKey,
        controller: _text,
        focusNode: _focus,
        windowClass: WindowClass.compact,
        onChanged: _input.changed,
        onSubmitted: _input.submit,
        // Сканер у клиента закрыт (10 CUST-021; 02 SCR-17 п. 10).
        onScan: _customer ? null : _onScan,
      ),
      onLogo: () => GoRouter.maybeOf(context)?.go(homeLocationFor(widget.mode)),
      onNotifications: () => openCatalogNotifications(context, ref, WindowClass.compact),
      onProfileMenu: (BuildContext anchor) =>
          unawaited(showCatalogProfileMenu(context: context, anchor: anchor, ref: ref, onNavigate: _push)),
    );
  }
}
