# features/auth

Экраны: SCR-01 `/auth/phone`, SCR-02 `/auth/otp`, SCR-08 `/auth/unlock` (+ overlay `idle`).
Может зависеть (DAG фич, 06 §6.1): —. От auth зависят registration, profile, settings (через `auth_providers.dart`).
Реализация: RM-D-007 (вход). Регистрация/PIN/биометрия-адаптер — RM-D-008, сессия/idle/refresh — RM-D-009.

## Структура (06 §6.14)

```
auth_providers.dart            публичный контракт: authRepositoryProvider (по умолчанию UnboundAuthRepository),
                               biometricUnlockProvider (NoBiometricUnlock), authOfflineSignalProvider,
                               use cases, authSessionProvider (мост к core/session), registrationTicketProvider
domain/entities/               OtpChallenge, OtpChallengeStatus, VerifyOutcome (+RegistrationTicket),
                               SessionProfile, AuthEntryReason, UnlockMode/UnlockSuccess
domain/repositories/           AuthRepository
domain/ports/biometric_unlock  порт к BiometricAuthenticator (core/hardware; platform channel — RM-D-008)
domain/usecases/               ValidatePhone, RequestOtp, VerifyOtp, GetOtpDeliveryStatus, UnlockWithPin, UnlockWithBiometric
data/dto/auth_dtos.dart        DTO вручную по contracts/openapi (ADR-085), сверка — test/features/auth/data
data/datasources/              AuthRemoteDataSource: /auth/otp/request|verify, /auth/otp/challenges/{id}, /auth/unlock
data/repositories/             AuthRepositoryImpl (токены — TokenStore до возврата успеха)
data/device_info_source.dart   AuthDeviceInfo (device_info_plus)
data/auth_bindings.dart        authBindings → app/di/overrides.dart
presentation/mascot/           MascotController (6 состояний D-40, входы MascotAuth), Mascot (заглушка-рендерер,
                               Q-035), SuccessCheck
presentation/notifiers/        AuthFlowNotifier (SCR-01/02, только память), UnlockNotifier (SCR-08)
presentation/screens/          PhoneScreen, NoSessionScreen (маршрут SCR-01), OtpScreen, UnlockScreen/UnlockView,
                               showUnlockOverlay
presentation/widgets/          AuthLayout (compact/medium/expanded), AuthLogo
presentation/navigation/       AuthPaths (пути графа маршрутов; сверка с routes.dart — тест)
```

## Подключение (композиционный корень, вне путей фичи)

1. `app/di/overrides.dart`: `appOverrides = [...authBindings]` (+ адаптер биометрии `biometricUnlockProvider`).
2. `app/router/routes.dart`: `AuthOtpRoute.build` → `const OtpScreen()`, `AuthUnlockRoute.build` →
   `UnlockScreen.fromRoute(context)`; `AuthPhoneRoute` уже ведёт на `NoSessionScreen` (= SCR-01).
3. `app/router/guards/auth_guard.dart`: на `/splash` решение принимает SplashScreen (не редиректить сразу);
   `sessionStatusProvider` (core/session, RM-D-009) учитывает `authSessionProvider`.
4. Idle-блокировка (RM-D-009): `showUnlockOverlay(context, idleMinutes: 30)`.

Правила импортов проверяет `python -I -X utf8 scripts/check_layers.py` (pos-app/NOTES.md §4).
Тесты: `flutter test test/features/auth` (unit, widget, golden 3 брейкпоинта).
