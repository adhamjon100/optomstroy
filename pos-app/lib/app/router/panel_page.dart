// Страница панели на expanded/large (02 SCR-14.2; navigation.md §5 «Панель на expanded»; EQ-PD-05):
// прозрачный маршрут того же навигатора **без модального барьера**. Экран сам решает, какие клики вне панели
// закрывают её (`DsPanelDismissLayer`: SB, пустая область шапки), а какие проходят в область под ней
// (`DsPanelPassThrough`: CP — постоянная соседняя область, SearchBar). Барьер маршрута перехватывал бы любой
// клик по окну, в том числе по CP (02 SCR-14.2: работа с CP панель не закрывает).
import 'package:flutter/widgets.dart';

/// Прозрачная страница без барьера с плавным появлением.
class PanelPage<T> extends Page<T> {
  /// Создаёт страницу.
  const PanelPage({
    required this.child,
    required this.transitionDuration,
    required this.reverseTransitionDuration,
    super.key,
    super.name,
    super.arguments,
    super.restorationId,
  });

  /// Содержимое (экран рисует панель и слой закрытия сам).
  final Widget child;

  /// Длительность появления.
  final Duration transitionDuration;

  /// Длительность исчезновения.
  final Duration reverseTransitionDuration;

  @override
  Route<T> createRoute(BuildContext context) => _PanelPageRoute<T>(this);
}

class _PanelPageRoute<T> extends PageRoute<T> {
  _PanelPageRoute(PanelPage<T> page) : super(settings: page);

  PanelPage<T> get _page => settings as PanelPage<T>;

  @override
  bool get opaque => false;

  @override
  bool get barrierDismissible => false;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => _page.transitionDuration;

  @override
  Duration get reverseTransitionDuration => _page.reverseTransitionDuration;

  /// Без барьера: точки вне содержимого страницы проходят в маршрут под ней.
  @override
  Widget buildModalBarrier() => const SizedBox.shrink();

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation, // money-double: allow — анимация перехода, не деньги
    Animation<double> secondaryAnimation, // money-double: allow — анимация перехода, не деньги
  ) => Semantics(scopesRoute: true, explicitChildNodes: true, child: _page.child);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation, // money-double: allow — анимация перехода, не деньги
    Animation<double> secondaryAnimation, // money-double: allow — анимация перехода, не деньги
    Widget child,
  ) => FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
    child: child,
  );
}
