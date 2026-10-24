# features/admin

Экраны: SCR-45 `/admin/users` (RM-D-010, UI RM-D-016 — реализован), SCR-46 `/admin/settings`, SCR-47 `/admin/audit` (этап G).
Может зависеть (DAG фич, 06 §6.1): —.

## SCR-45 «Пользователи, роли, приглашения»

| Слой | Файлы |
|---|---|
| domain | `domain/users/`: `AdminUser`, `AdminUsersQuery`, `AdminPage`, `Invitation` (+ `InvitationRules`, `invitableRoles`), `CustomerLinkCase`, `EmergencyLoginCode` (+ `EmergencyCodeRules`), `AdminViewer`, `AdminUsersPolicy` (режимы admin/owner, ядро §21 п.3), `StepUpRunner` / `StepUpGateway` / `AdminActionResult`, порт `AdminUsersRepository` |
| data | `data/users/`: `DioAdminUsersRepository`, `DioStepUpGateway`, ручной разбор DTO `AdminUsersDto` (ADR-085); `data/admin_bindings.dart` — `adminOverrides` |
| presentation | `presentation/users/`: `AdminUsersScreen` (`?tab=`, `?userId=`), `AdminUsersController` (Riverpod `Notifier`), виджеты карточки, приглашений, привязок, аварийного кода, `RoleBadge`, резервный `AdminStepUpDialog` |
| контракт | `admin_providers.dart`: `adminUsersRepositoryProvider`, `adminStepUpGatewayProvider`, `adminStepUpPrompterProvider` (порт StepUpDialog core/session), `adminCustomerSelfServiceProvider` |

Подключение (владелец `app/`):

```dart
// app/di/overrides.dart
import 'package:optomstroy/features/admin/data/admin_bindings.dart';
final List<Override> appOverrides = <Override>[...adminOverrides];

// app/router/routes.dart — AdminUsersRoute.build
AdminUsersScreen(initialTab: AdminUsersTab.tryParse(tab), initialUserId: userId)
```

Step-up: порт `adminStepUpPrompterProvider` (если переопределён) → StepUpDialog core/session через
`stepUpCoordinatorProvider`, когда презентер смонтирован (по `403` диалог показывает AuthInterceptor,
до запроса — `StepUpCoordinator.obtain`) → иначе резервный `AdminStepUpDialog` фичи.
Данные пользователей не кэшируются (ПДн); аварийный код живёт только в состоянии диалога.

Тесты: `flutter test test/features/admin`. Правила импортов — `python -I -X utf8 scripts/check_layers.py`.
