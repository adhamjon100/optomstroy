# features/sync_status

Экраны: SCR-43 `/sync`.
Может зависеть (DAG фич, 06 §6.1): —.
Реализация: этап E; только `presentation/`, использует `core/sync`.

Шаблон модуля — 06 §6.14: `domain/` (entities, repositories, usecases) · `data/` (`sync_status_bindings.dart`, datasources, repositories) · `presentation/` (screens, widgets, notifiers) · `sync_status_providers.dart` (публичный контракт фичи).
Маршрут регистрируется в `lib/app/router/routes.dart`; до реализации он показывает `RouteStubScreen`.
Правила импортов проверяет `python -I -X utf8 scripts/check_layers.py` (pos-app/NOTES.md §4).
