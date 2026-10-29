// Класс окна для построителей страниц маршрутов (`GoRouteData.buildPage`). Навигатор ветки go_router пересобирает
// все страницы при любом изменении зависимостей своего контекста: `context.windowClass` (`MediaQuery.sizeOf`)
// давал пересборку списка страниц на каждый пиксель изменения размера окна. Область сообщает только о смене
// класса (compact/medium/expanded/large). Ставит её оболочка (`AppShell`) над навигаторами веток.
import 'package:flutter/widgets.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';

/// Класс окна для поддерева; уведомляет зависимых только при смене класса.
class WindowClassScope extends InheritedWidget {
  /// Создаёт область.
  const WindowClassScope({super.key, required this.windowClass, required super.child});

  /// Текущий класс окна.
  final WindowClass windowClass;

  /// Класс окна для построителя страницы: из ближайшей области, без неё — по `MediaQuery`.
  static WindowClass of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WindowClassScope>()?.windowClass ?? context.windowClass;

  @override
  bool updateShouldNotify(WindowClassScope oldWidget) => oldWidget.windowClass != windowClass;
}
