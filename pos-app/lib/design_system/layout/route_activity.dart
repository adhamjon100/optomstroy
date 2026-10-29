// Активен ли экран маршрута для клавиш и жестов, когда над его страницей лежат записи истории без содержимого.
//
// Семейство каталога на medium+ рисует SCR-10/11/12 одной страницей `/catalog`, а записи `/catalog/c/{id}` и
// `/catalog/search` над ней — страницы без содержимого (app/router/pass_through_page.dart). Для навигатора страница
// `/catalog` в этот момент не верхняя (`ModalRoute.isCurrent == false`), хотя пользователь видит именно её. Проверки
// «экран активен» (F4 корзины, клавиши CP) используют [dsRouteIsCurrent] вместо `isCurrent`. Панель SCR-14 на
// expanded/large ([DsPanelPage]) экран тоже не закрывает: клавиши кнопки-итога корзины в шапке работают и при ней.
import 'package:flutter/widgets.dart';

/// Страница навигатора без собственного содержимого: экран под ней остаётся активным ([dsRouteIsCurrent]).
abstract interface class DsTransparentPage {}

/// Боковая панель поверх экрана без барьера (SCR-14 на expanded/large, `PanelPage`): экран под ней виден, его шапка
/// принимает нажатия (`DsPanelPassThrough`). Для клавиш шапки (кнопка-итог корзины: `F4`/`F8`/`F9`, 02 §3.8) такой
/// экран остаётся активным — [dsRouteIsCurrent] с `allowPanels: true`.
abstract interface class DsPanelPage {}

/// Маршрут [context] — верхний видимый: `isCurrent` или над его страницей только [DsTransparentPage] (и
/// [DsPanelPage] при [allowPanels]). Без маршрута — `true`. Диалоги и листы поверх (маршруты без страницы)
/// проверяет вызывающий (фокус в `PopupRoute`).
bool dsRouteIsCurrent(BuildContext context, {bool allowPanels = false}) {
  final ModalRoute<Object?>? route = ModalRoute.of(context);
  if (route == null || route.isCurrent) {
    return true;
  }
  final NavigatorState? navigator = route.navigator;
  if (!route.isActive || navigator == null) {
    return false;
  }
  final List<Page<Object?>> pages = navigator.widget.pages;
  final int index = pages.indexWhere((Page<Object?> p) => identical(p, route.settings));
  if (index < 0) {
    return false;
  }
  return pages.skip(index + 1).every((Page<Object?> p) => p is DsTransparentPage || (allowPanels && p is DsPanelPage));
}
