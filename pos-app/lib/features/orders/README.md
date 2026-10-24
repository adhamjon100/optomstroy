# features/orders

Экраны: SCR-24 `/orders/:orderId`, SCR-25 `/orders`.
Может зависеть (DAG фич, 06 §6.1): customers.
Реализация: этап F.

Шаблон модуля — 06 §6.14: `domain/` (entities, repositories, usecases) · `data/` (`orders_bindings.dart`, datasources, repositories) · `presentation/` (screens, widgets, notifiers) · `orders_providers.dart` (публичный контракт фичи).
Маршрут регистрируется в `lib/app/router/routes.dart`; до реализации он показывает `RouteStubScreen`.
Правила импортов проверяет `python -I -X utf8 scripts/check_layers.py` (pos-app/NOTES.md §4).
