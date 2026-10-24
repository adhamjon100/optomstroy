# features/registration

Экраны: SCR-03 `/register`, SCR-04 `/register/security`, SCR-06 `/register/customer-link`, SCR-07 `/pending-activation`; SCR-05 `/register/face-scan` — R2 (не зарегистрирован).
Может зависеть (DAG фич, 06 §6.1): auth.
Реализация: RM-D-008 (этап D).

## Состав

| Слой | Файлы |
|---|---|
| domain | `entities/registration_entities.dart` (тикет `registration_token`, черновик, политика PIN, привязка 1С, итог `201`), `usecases/registration_validation.dart` (ФИО, год 1920…текущий−14, слабый PIN), `usecases/registration_usecases.dart` (сборка тела `/registration/complete`, `EnableBiometricLogin`, `StepUpWithPin`), `repositories/registration_repositories.dart` (порты) |
| data | `datasources/registration_api.dart` (HTTP), `models/registration_dtos.dart` (ручные DTO, ADR-085), `repositories/*_impl.dart`, `device_descriptor.dart` (`AuthDeviceInfo`), `registration_bindings.dart` (`registrationOverrides`) |
| presentation | `controllers/` (поток SCR-03→SCR-04→«Готово», SCR-06, SCR-07), `screens/`, `widgets/` (`RegistrationStepper`, `SuccessCheck`, `StepUpPinDialog`, `RegistrationFrame`) |
| публичный контракт | `registration_providers.dart` |

Биометрия: порт `BiometricAuthenticator` — `lib/core/biometrics/` (platform channel `kg.optomstroy/biometric_crypto`:
Android `android/app/src/main/kotlin/.../BiometricCryptoChannel.kt`, iOS `BiometricCrypto` в `ios/Runner/AppDelegate.swift`;
Windows — `WindowsHelloGate` на `local_auth`, только UX-гейт). Решение — ADR-087 в 15_DECISION_LOG.

## Подключение (композиционный корень app — вне этой задачи)

1. `app/di/overrides.dart`: `appOverrides = <Override>[...registrationOverrides]` (импорт `features/registration/data/registration_bindings.dart`, FL-06).
2. `app/router/routes.dart`: заменить `RouteStubScreen` на `RegistrationFormScreen()`, `RegistrationSecurityScreen()`
   (для `nextStep=set_pin` — `RegistrationSecurityScreen(audience: RegistrationAudience.staffFirstLogin)`),
   `CustomerLinkScreen()`, `PendingActivationScreen()`.
3. После `/auth/otp/verify` → `registration_required`: `ref.read(registrationTicketProvider.notifier).start(RegistrationTicket(...))`,
   затем `/register`. Баннер SCR-01 «Продолжите регистрацию» — `registrationDraftPendingProvider`.
4. SCR-01 читает причину возврата из `?reason=` (`registration_cancelled | registration_expired | phone_registered | logged_out`)
   или app подменяет `registrationNavigatorProvider`.

Правила импортов проверяет `python -I -X utf8 scripts/check_layers.py` (pos-app/NOTES.md §4).
