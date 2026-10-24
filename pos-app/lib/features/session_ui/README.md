# features/session_ui — глобальный слой сессии (RM-D-009)

Только `presentation/` (domain/data нет: логика — `lib/core/session`). Фича не импортирует другие фичи.

| Файл | Что | Источник |
|---|---|---|
| `presentation/session_gate.dart` | `SessionGate` — ставится в `MaterialApp.builder`: SCR-08 overlay (холодный старт, idle 30 мин, фон > 5 мин, `Ctrl+L`, `UNLOCK_REQUIRED`) с сохранением экрана под слоем; StepUpDialog по `403 STEP_UP_REQUIRED`; SCR-90 C «Сессия завершена», C3 «Требуется обновление»; учёт активности и жизненного цикла; «Назад» при слое поглощается | 02 SCR-08, SCR-90; 09 §8.8 |
| `presentation/widgets/step_up_dialog.dart` | `StepUpDialog` — чистый виджет: PIN / «Код из SMS», без биометрии (R1); compact — нижний лист, иначе диалог 400 | 03 §9.46 |
| `presentation/widgets/step_up_flow.dart` | `StepUpFlow` — состояния по ответам `POST /auth/step-up` (`attemptsLeft` только из ответа, `PIN_LOCKED` → SMS) | 08 §4.1.7 |
| `presentation/widgets/session_lock_overlay.dart` | PIN-вариант SCR-08 overlay по умолчанию (`POST /auth/unlock`) | 02 SCR-08 |
| `presentation/widgets/session_ended_dialog.dart`, `update_required_view.dart` | SCR-90 C, C3 | 02 §3.3 |

## Подключение (app/, вне этой задачи)

```dart
builder: (context, child) => EnvBanner(
  environmentCode: …,
  child: AppVersionGate(
    child: SessionGate(
      // SCR-08 фичи auth (биометрия + PIN), иначе — PIN-слой по умолчанию:
      lockScreenBuilder: (context, reason) => …,
      // false — холодный старт показывает маршрут /auth/unlock?mode=cold (app/router), а не слой:
      coverColdStart: true,
      child: child ?? const SizedBox.shrink(),
    ),
  ),
),
```

API ядра (`lib/core/session`): `sessionControllerProvider` (`restore`, `establish`, `lock`, `unlockWithPin`,
`unlockWithBiometric`, `logout`, `logoutAll`, `leaveToPhoneLogin`, `pendingLocalChanges`), `sessionStatusProvider`,
`sessionEndReasonProvider`, `sessionLockProvider`, `sessionOverlayProvider`, `stepUpCoordinatorProvider`,
`sessionCleanupHooksProvider`; для слоя data — `SessionRequestExtra.stepUpOperation` (подстановка токена области без `403`).
