# features/settings

Экран: SCR-42 `/settings?section=` (02 ч. E; RM-D-009 — «Устройства и сессии», «Защита входа»).
Может зависеть (DAG фич, 06 §6.1): auth, profile.

- `settings_providers.dart` — публичный контракт: порты `deviceSessionsRepositoryProvider`,
  `loginProtectionRepositoryProvider`, `displayPreferencesRepositoryProvider`, `appAboutSourceProvider`;
  `displayPreferencesProvider` (плотность, размер текста, уменьшение анимаций — применяет корень приложения);
  точки расширения секций других фич: `settingsScannerSectionProvider` (секция фичи scan, подключена в
  `app/di/overrides.dart`), `settingsPrinterSectionProvider` (печать — пока не подключена, секция скрыта).
- `domain/` — сущности SCR-42, порты, предпроверка нового PIN (`SettingsPinPolicy`).
- `data/` — `SettingsApi` (`/auth/sessions*`, `/me`, `/me/pin`, `/me/biometrics`, `/me/consents`, `/me/settings`),
  реализации портов; биометрия — порт core/biometrics; выход и «выйти везде» — SessionController (core/session);
  step-up — AuthInterceptor + StepUpDialog (операции `session.revoke.other`, `profile.pin.set`,
  `profile.biometrics.toggle`, `session.logout_all`). Привязки — `data/settings_bindings.dart` (`settingsBindings`).
- `presentation/` — `SettingsScreen` (compact: список → секция; medium/expanded: навигация 240 + содержимое ≤ 640),
  секции «Язык», «Защита входа», «Устройства и сессии», «Сканер» (режим и «Сразу добавлять в корзину» +
  секция scan), «Отображение», «О приложении».

Правила импортов проверяет `python -I -X utf8 scripts/check_layers.py` (pos-app/NOTES.md §4).
