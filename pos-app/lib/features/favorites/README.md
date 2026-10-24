# features/favorites

Экраны: SCR-40 `/favorites`.
Может зависеть (DAG фич, 06 §6.1): catalog, customers.
Реализация: этап E.

Шаблон модуля — 06 §6.14: `domain/` (entities, repositories, usecases) · `data/` (`favorites_bindings.dart`, datasources, repositories) · `presentation/` (screens, widgets, notifiers) · `favorites_providers.dart` (публичный контракт фичи).
Маршрут регистрируется в `lib/app/router/routes.dart`; до реализации он показывает `RouteStubScreen`.
Правила импортов проверяет `python -I -X utf8 scripts/check_layers.py` (pos-app/NOTES.md §4).
