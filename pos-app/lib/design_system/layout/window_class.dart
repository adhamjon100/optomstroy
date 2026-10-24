import 'package:flutter/widgets.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';

export 'package:optomstroy/design_system/tokens/ds_breakpoints.dart' show DsBreakpoints, WindowClass;

/// Строит содержимое по классу окна (03 §7.2, §8.6): класс — по ширине окна
/// (`MediaQuery.sizeOf`), а не контейнера; для ширины контейнера (колонки сетки) —
/// `LayoutBuilder` + `DsBreakpoints.gridColumns`.
class WindowClassBuilder extends StatelessWidget {
  /// Создаёт построитель.
  const WindowClassBuilder({super.key, required this.builder});

  /// Построитель.
  final Widget Function(BuildContext context, WindowClass windowClass) builder;

  @override
  Widget build(BuildContext context) => builder(context, DsBreakpoints.of(context));
}
