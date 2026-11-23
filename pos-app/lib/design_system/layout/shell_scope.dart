import 'package:flutter/widgets.dart';

/// Мост «экран → оболочка» (03 §9.54, ADR-112): действия оболочки, которые нужны шапке экрана, без импорта
/// `app/` из фич (AP-01) и фич друг из друга (FL-03).
///
/// * [openNavigation] — открыть drawer навигации (`NavigationDrawerApp`; «бургер» шапки staff на medium+);
///   `null` — навигации через drawer нет (compact, клиент, экран вне оболочки) — «бургер» не показывается.
///
/// * [phoneHeader] — над экраном стоит шапка телефона оболочки (compact, корни веток; ADR-122): экран не рисует
///   вторую шапку с логотипом, колокольчиком и аватаром — только строку заголовка со своими действиями.
///
/// Корзину (drawer 420, D5) шапки открывают сами — кнопкой-итогом пакета корзины (`CartDrawer.open`), мост для этого
/// не нужен.
///
/// Ставит `app/router/shells/app_shell.dart`; читают шапки экранов через [maybeOf].
class DsShellScope extends InheritedWidget {
  /// Создаёт область оболочки.
  const DsShellScope({super.key, this.openNavigation, this.phoneHeader = false, required super.child});

  /// Открыть drawer навигации оболочки.
  final VoidCallback? openNavigation;

  /// Над экраном — шапка телефона оболочки (ADR-122).
  final bool phoneHeader;

  /// Ближайшая область оболочки или `null` (экран вне `AppShell`: тесты экранов, витрина).
  static DsShellScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<DsShellScope>();

  @override
  bool updateShouldNotify(DsShellScope oldWidget) =>
      oldWidget.openNavigation != openNavigation || oldWidget.phoneHeader != phoneHeader;
}
