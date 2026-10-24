# features/notifications

Экраны: SCR-44 `/notifications`.
Может зависеть (DAG фич, 06 §6.1): —.
Реализация: этап F (RM-F-008): SCR-44 (`presentation/screens/notifications_screen.dart`), popover и колокольчик с
бейджем (`presentation/widgets/notifications_connected.dart`), баннеры экранов (`NotificationBannerSlot`), состояние
(`presentation/notifiers/notifications_center_controller.dart`), офлайн-отметки — outbox `notification.read`
(`data/offline/notification_read_outbox.dart`; обработчик — `notificationsOutboxHandlers(ref)` в реестр корня).

Шаблон модуля — 06 §6.14: `domain/` (entities, repositories, usecases) · `data/` (`notifications_bindings.dart`, datasources, repositories) · `presentation/` (screens, widgets, notifiers) · `notifications_providers.dart` (публичный контракт фичи).
Маршрут регистрируется в `lib/app/router/routes.dart`; до реализации он показывает `RouteStubScreen`.
Правила импортов проверяет `python -I -X utf8 scripts/check_layers.py` (pos-app/NOTES.md §4).
