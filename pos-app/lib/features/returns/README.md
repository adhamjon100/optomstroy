# features/returns

Экраны: SCR-39 `/returns/new`, `/returns/:returnId`.
Может зависеть (DAG фич, 06 §6.1): orders, cashier, customers.
Реализация: этап G.

Шаблон модуля — 06 §6.14: `domain/` (entities, repositories, usecases) · `data/` (`returns_bindings.dart`, datasources, repositories) · `presentation/` (screens, widgets, notifiers) · `returns_providers.dart` (публичный контракт фичи).
Маршрут регистрируется в `lib/app/router/routes.dart`; до реализации он показывает `RouteStubScreen`.
Правила импортов проверяет `python -I -X utf8 scripts/check_layers.py` (pos-app/NOTES.md §4).
