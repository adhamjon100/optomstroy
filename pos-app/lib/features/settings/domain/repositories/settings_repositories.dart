// Порты SCR-42 «Настройки» (06 §6.14). Реализации — features/settings/data (подключает `settingsBindings`
// в app/di/overrides.dart). Step-up (`STEP_UP_REQUIRED`) обрабатывает AuthInterceptor + StepUpDialog
// core/session; порты получают итог: успех или отказ (`AuthFailure(stepUpRequired)` — диалог отменён).
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/settings/domain/entities/settings_entities.dart';

/// Устройства и сессии (08 §4.1.5–§4.1.6; 09 §8.4).
abstract interface class DeviceSessionsRepository {
  /// `GET /auth/sessions` — только свои (≤ 3 staff / ≤ 5 customer).
  Future<Result<List<DeviceSession>>> list();

  /// `DELETE /auth/sessions/{id}`: другая сессия — step-up `session.revoke.other`; `404` — уже завершена
  /// (успех для UI: строка удаляется без ошибки).
  Future<Result<void>> revoke(String sessionId);

  /// `PATCH /auth/sessions/{id} {deviceName}`.
  Future<Result<DeviceSession>> rename(String sessionId, String deviceName);

  /// «Выйти» для текущей сессии (= UI-41-005, `POST /auth/logout` и локальная очистка).
  Future<void> logoutCurrent();

  /// «Выйти на всех устройствах» (`POST /auth/logout-all`, step-up `session.logout_all`).
  Future<Result<void>> logoutAll();
}

/// Защита входа: PIN, биометрия, автоблокировка (08 §4.3.4–§4.3.6; 09 §9.5–§9.6; D-13, D-48).
abstract interface class LoginProtectionRepository {
  /// `GET /me` (`security.pinSet`, `settings.idleLockMinutes`) + возможности биометрии устройства.
  /// Без сети — последний известный ответ ([LoginProtectionState.settingsAsOf] ≠ `null`) или ошибка.
  Future<Result<LoginProtectionState>> load();

  /// `POST /me/pin {newPin}` (step-up `profile.pin.set`: текущим PIN или OTP).
  Future<Result<void>> changePin(String newPin);

  /// `DELETE /me/pin` — «Требовать PIN при запуске» выкл. (только `customer` при включённой биометрии, D-48).
  Future<Result<void>> removePin();

  /// Подтверждение перед сменой PIN (step-up `profile.pin.set`): «Сменить PIN» — текущим PIN или кодом из SMS
  /// (UI-42-009); «Забыли PIN?» ([otpOnly]) — сразу «Код из SMS» (UI-42-026). `true` — токен получен (кэш области).
  Future<bool> stepUpForPin({required bool otpOnly});

  /// Включить вход по биометрии: Android/iOS — `POST /me/biometrics {enabled, biometricClass, consent}`
  /// (step-up `profile.biometrics.toggle`) → системный диалог → токен под ключом Keystore/Keychain;
  /// Windows — только подтверждение Windows Hello (локальный UX-гейт).
  Future<BiometricToggleOutcome> enableBiometrics(BiometricPromptCopy prompt);

  /// Выключить: `POST /me/biometrics {enabled:false}` (Android/iOS) → удаление ключа и токена.
  Future<BiometricToggleOutcome> disableBiometrics();

  /// `PUT /me/settings {idleLockMinutes}` (полный объект с `rowVersion`; `409` — одна попытка поверх `current`).
  Future<Result<int>> setIdleLockMinutes(int minutes);

  /// Изменить серверные настройки пользователя (`PUT /me/settings`: текущие значения + [patch], например
  /// `{'scanner': {'suffix': 'tab'}}` из секции «Сканер»). Возвращает сохранённый `Settings`.
  Future<Result<Map<String, Object?>>> patchSettings(Map<String, Object?> patch);
}

/// Локальные настройки отображения устройства (drift `settings(scope=device)`).
abstract interface class DisplayPreferencesRepository {
  Future<DisplayPreferences> load();

  Future<void> save(DisplayPreferences value);
}

/// «О приложении»: версия сборки, платформа, идентификатор устройства, версии сервера.
abstract interface class AppAboutSource {
  AppAboutInfo current();
}
