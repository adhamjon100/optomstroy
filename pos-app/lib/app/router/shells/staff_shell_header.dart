// Шапка оболочки сотрудника на medium и шире вне ветки «Каталог» (D2, ADR-112; 02 §3.1 п. 7): тот же
// `CatalogHeader`, что у SCR-10/11/12 (на ветке каталога шапку рисует `CatalogWorkspace` — ADR-110, одно поле
// поиска). Поиск ведёт в SCR-11 (`/catalog/search?q=`) по Enter или после паузы ввода при допустимой строке;
// ввод продолжается в поле каталога (`catalogSearchFocusRequestProvider`). Сканер — SCR-17 на Android/iOS, на
// Windows и в браузере — подсказка HID-сканера; логотип — главный экран режима; колокольчик — popover на expanded/large,
// иначе SCR-44; меню аватара — `showCatalogProfileMenu`; часы и дата перед колокольчиком (UI-10-005, UI-10-032; на
// ветке «Касса» — с полной датой, UI-30-013). Данные — только через порты каталога со значениями по
// умолчанию (оболочка строится в тестах без привязок корзины, уведомлений и синхронизации).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/app_router.dart' show homeLocationFor;
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/core/hardware/hardware_providers.dart' show cameraScannerSupportedProvider;
import 'package:optomstroy/design_system/layout/shell_scope.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/catalog/presentation/catalog_paths.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';
import 'package:optomstroy/features/catalog/presentation/state/search_input_policy.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_header.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_profile_menu.dart';

/// Шапка оболочки сотрудника (medium+, ветки кроме «Каталога»).
class StaffShellHeader extends ConsumerStatefulWidget {
  /// Создаёт шапку.
  const StaffShellHeader({
    super.key,
    required this.mode,
    required this.windowClass,
    required this.focusNode,
    required this.controller,
    this.clockLongDate = false,
  });

  /// Режим оболочки (главный экран режима — по логотипу).
  final AppMode mode;

  /// Класс окна (medium/expanded/large).
  final WindowClass windowClass;

  /// Узел фокуса поля поиска (F2 / Ctrl+F оболочки).
  final FocusNode focusNode;

  /// Текст поля поиска (оболочка очищает поле, когда скан в нём — номер заказа на SCR-30).
  final TextEditingController controller;

  /// Дата часов шапки — «Пн, 29 июня 2026» (ветка «Касса», UI-30-013, AC-UI-30-020).
  final bool clockLongDate;

  /// Ключ поля поиска шапки оболочки (у поля каталога — `catalog-search-field`).
  static const Key searchFieldKey = ValueKey<String>('shell-search-field');

  @override
  ConsumerState<StaffShellHeader> createState() => _StaffShellHeaderState();
}

class _StaffShellHeaderState extends ConsumerState<StaffShellHeader> {
  late final SearchInputController _input = SearchInputController(onQuery: _search);

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  /// Допустимая строка (Enter или пауза ввода) → SCR-11; фокус переходит в поле каталога после перехода. Запрос,
  /// которого в поле уже нет (оболочка очистила поле — скан номера заказа на SCR-30), не выполняется.
  void _search(String q) {
    final GoRouter? router = GoRouter.maybeOf(context);
    if (router == null || widget.controller.text.trim() != q.trim()) {
      return;
    }
    final ProviderContainer container = ProviderScope.containerOf(context, listen: false);
    router.go(CatalogPaths.search(q: q));
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => container.read(catalogSearchFocusRequestProvider.notifier).request(),
    );
  }

  void _onScan() =>
      handleCatalogScanButton(context, widget.focusNode, cameraSupported: ref.read(cameraScannerSupportedProvider));

  void _openNotifications() => openCatalogNotifications(context, ref, widget.windowClass);

  void _push(String location) => unawaited(GoRouter.maybeOf(context)?.push<Object?>(location));

  @override
  Widget build(BuildContext context) {
    return CatalogHeader(
      windowClass: widget.windowClass,
      clockLongDate: widget.clockLongDate,
      search: CatalogSearchField(
        fieldKey: StaffShellHeader.searchFieldKey,
        controller: widget.controller,
        focusNode: widget.focusNode,
        windowClass: widget.windowClass,
        onChanged: _input.changed,
        onSubmitted: _input.submit,
        onScan: _onScan,
      ),
      actions: CatalogHeaderActions(
        onLogo: () => GoRouter.maybeOf(context)?.go(homeLocationFor(widget.mode)),
        onMenu: DsShellScope.maybeOf(context)?.openNavigation,
        onScan: _onScan,
        onNotifications: _openNotifications,
        onProfileMenu: (BuildContext anchor) =>
            unawaited(showCatalogProfileMenu(context: context, anchor: anchor, ref: ref, onNavigate: _push)),
      ),
    );
  }
}
