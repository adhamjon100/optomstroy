# features/cashier

Экраны: SCR-30 `/cashier`, SCR-38 `/payments/new`.
Может зависеть (DAG фич, 06 §6.1): orders, customers.
Реализация: этап F.

Шаблон модуля — 06 §6.14: `domain/` (entities, repositories, usecases) · `data/` (`cashier_bindings.dart`, datasources, repositories) · `presentation/` (screens, widgets, notifiers) · `cashier_providers.dart` (публичный контракт фичи).
Маршрут регистрируется в `lib/app/router/routes.dart`; до реализации он показывает `RouteStubScreen`.
Правила импортов проверяет `python -I -X utf8 scripts/check_layers.py` (pos-app/NOTES.md §4).
