import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Временный экран для маршрута, у которого ещё нет реализации (RM-C-002).
///
/// Показывает ID экрана по карте ядра R0 §9 и текущий адрес. Текст служебный,
/// в ARB не выносится: экран живёт только до реализации фичи и заменяется
/// экраном из `features/<f>/presentation/screens/`.
class RouteStubScreen extends StatelessWidget {
  /// Создаёт заглушку экрана [screenId] (например, `SCR-10`).
  const RouteStubScreen({required this.screenId, super.key});

  /// ID экрана по R0 §9.
  final String screenId;

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).uri.toString();
    final text = Theme.of(context).textTheme;
    return Scaffold(
      key: ValueKey<String>('stub-$screenId'),
      appBar: AppBar(title: Text(screenId)),
      body: Center(
        child: Text(location, style: text.bodyLarge, textAlign: TextAlign.center),
      ),
    );
  }
}
