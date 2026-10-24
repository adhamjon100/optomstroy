# features/reports

Экраны: SCR-48 `/reports`.
Может зависеть (DAG фич, 06 §6.1): transactions.
Реализация: этап G.

Шаблон модуля — 06 §6.14: `domain/` (entities, repositories, usecases) · `data/` (`reports_bindings.dart`, datasources, repositories) · `presentation/` (screens, widgets, notifiers) · `reports_providers.dart` (публичный контракт фичи).
Маршрут регистрируется в `lib/app/router/routes.dart`; до реализации он показывает `RouteStubScreen`.
Правила импортов проверяет `python -I -X utf8 scripts/check_layers.py` (pos-app/NOTES.md §4).
