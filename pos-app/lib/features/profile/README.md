# features/profile

Экраны: SCR-41 `/profile`.
Может зависеть (DAG фич, 06 §6.1): auth.
Реализация: этап D.

Шаблон модуля — 06 §6.14: `domain/` (entities, repositories, usecases) · `data/` (`profile_bindings.dart`, datasources, repositories) · `presentation/` (screens, widgets, notifiers) · `profile_providers.dart` (публичный контракт фичи).
Маршрут регистрируется в `lib/app/router/routes.dart`; до реализации он показывает `RouteStubScreen`.
Правила импортов проверяет `python -I -X utf8 scripts/check_layers.py` (pos-app/NOTES.md §4).
