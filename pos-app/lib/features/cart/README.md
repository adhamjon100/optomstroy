# features/cart

Экраны: SCR-20 `/cart`, SCR-23 `/cart/parked`.
Может зависеть (DAG фич, 06 §6.1): customers.
Реализация: этап F (RM-F-005, RM-F-013, RM-F-015 — агент F-fe-cart):
- `data/sync/drift_cart_sync.dart` — `CartSync`: черновик drift ↔ сервер, очередь `cart.sync` (`mode=set`, сжатие по
  паре, цепочка `rowVersion`, `409` → решение пользователя), обработчик очереди (`cartOutboxHandlerProvider`);
- `presentation/providers/cart_controller.dart` — `cartControllerProvider` (02 SCR-20.9 `cartProvider`): итоги только
  с сервера, оптимистичные количества, debounce 500 мс, «Отменить» 5 с;
- `presentation/widgets/cart_panel_view.dart` — SCR-20 для `panel` (expanded, в каталоге), `overlay` (medium),
  `screen` (compact); `cart_fab_view.dart` — `CartFab`; `screens/parked_carts_screen.dart` — SCR-23;
- DS: `design_system/components/cart_{panel,line,summary,fab}.dart`, `discount_input.dart`;
- корень: `app/di/overrides.dart` → `cartUiOverrides` (CartPanel/CartFab/«+ Добавить» каталога, реестр очереди).

Шаблон модуля — 06 §6.14: `domain/` (entities, repositories, usecases) · `data/` (`cart_bindings.dart`, datasources, repositories) · `presentation/` (screens, widgets, notifiers) · `cart_providers.dart` (публичный контракт фичи).
Маршрут регистрируется в `lib/app/router/routes.dart`; до реализации он показывает `RouteStubScreen`.
Правила импортов проверяет `python -I -X utf8 scripts/check_layers.py` (pos-app/NOTES.md §4).
