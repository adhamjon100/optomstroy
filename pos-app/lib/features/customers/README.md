# features/customers

Экраны: SCR-26 `/customers/new`, SCR-31 `/customers`, SCR-32…35 `/customers/:customerId[/history|/receivables|/discounts]`.
Может зависеть (DAG фич, 06 §6.1): —.
Реализация: этап G.

Шаблон модуля — 06 §6.14: `domain/` (entities, repositories, usecases) · `data/` (`customers_bindings.dart`, datasources, repositories) · `presentation/` (screens, widgets, notifiers) · `customers_providers.dart` (публичный контракт фичи).
Маршрут регистрируется в `lib/app/router/routes.dart`; до реализации он показывает `RouteStubScreen`.
Правила импортов проверяет `python -I -X utf8 scripts/check_layers.py` (pos-app/NOTES.md §4).
