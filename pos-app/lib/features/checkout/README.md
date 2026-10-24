# features/checkout

Экраны: SCR-21 `/checkout`, SCR-22 `/orders/:orderId/created`.
Может зависеть (DAG фич, 06 §6.1): cart, customers, orders, cashier.
Реализация: этап F.

Шаблон модуля — 06 §6.14: `domain/` (entities, repositories, usecases) · `data/` (`checkout_bindings.dart`, datasources, repositories) · `presentation/` (screens, widgets, notifiers) · `checkout_providers.dart` (публичный контракт фичи).
Маршрут регистрируется в `lib/app/router/routes.dart`; до реализации он показывает `RouteStubScreen`.
Правила импортов проверяет `python -I -X utf8 scripts/check_layers.py` (pos-app/NOTES.md §4).
