// Страница-«запись истории» без собственного содержимого (medium/expanded/large, семейство каталога SCR-10/11/12):
// маршрут `/catalog/c/{id}` или `/catalog/search` остаётся в стеке навигатора (URL, «Назад» Android, `canPop`),
// а экран рисует страница родителя `/catalog` — одно рабочее пространство для всех режимов (02 SCR-10.5,
// SCR-12.5 ANIM-024: на expanded SB и CP не анимируются; заказчик 2026-10-28 — «мигает весь экран»).
//
// Маршрут — не [ModalRoute]: нет барьера, фокус-области и анимации, точки проходят в страницу под ним,
// фокус остаётся в поле поиска/списке родителя (сканер HID и горячие клавиши работают как на SCR-10).
import 'package:flutter/widgets.dart';
import 'package:optomstroy/design_system/layout/route_activity.dart';

/// Прозрачная запись истории без содержимого; экран под ней остаётся активным ([dsRouteIsCurrent]).
class PassThroughPage<T> extends Page<T> implements DsTransparentPage {
  /// Создаёт страницу.
  const PassThroughPage({super.key, super.name, super.arguments, super.restorationId});

  @override
  Route<T> createRoute(BuildContext context) => _PassThroughRoute<T>(this);
}

class _PassThroughRoute<T> extends OverlayRoute<T> {
  _PassThroughRoute(PassThroughPage<T> page) : super(settings: page);

  @override
  Iterable<OverlayEntry> createOverlayEntries() => <OverlayEntry>[
    // Пустой слой без hit-test: клики и семантика — у страницы родителя.
    OverlayEntry(builder: (BuildContext context) => const SizedBox.shrink()),
  ];
}
