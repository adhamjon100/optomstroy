# features/splash

Экраны: SCR-00 `/splash`.
Может зависеть (DAG фич, 06 §6.1): —.
Реализация: только `presentation/` (06 §6.2); сессию читает через `core/session` (RM-D-007).

- `presentation/screens/splash_screen.dart` — SCR-00: `SplashLogo` (ANIM-001, 600 мс), индикатор после 400 мс,
  «Проверяем сессию…» после 2 с, переход в max(решение, 600 мс) (reduce-motion — сразу), сбой инициализации после
  автоповтора — `ErrorState` «Не удалось запустить приложение», строка версии.
- `presentation/notifiers/splash_decision.dart` — `decideSplash` (02 SCR-00.6): нет сессии → SCR-01; `staff` → SCR-08
  `cold`; `customer` с PIN/биометрией → SCR-08; `customer` без них → SCR-50; кэша профиля нет → SCR-08 `cold`.
  `splashSnapshotProvider` по умолчанию строится из `sessionStatusProvider`; полный снимок (refresh + кэш профиля
  `app_meta.profile_*`) подставляет SessionController (RM-D-009) переопределением провайдера.
- `presentation/widgets/splash_logo.dart` — `SplashLogo` (03 §9.53): `assets/brand/logo_orange.png` (оранжевый знак,
  ядро v1.9 §24.1) + wordmark; `Hero` `splash_logo` → SCR-01.

Тесты: `test/features/auth/splash/`, golden — `test/features/auth/golden/`.
Правила импортов проверяет `python -I -X utf8 scripts/check_layers.py` (pos-app/NOTES.md §4).
