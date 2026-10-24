// «Защита входа» SCR-42 (08 §4.3.4–§4.3.6; 09 §8.8, §9.2–§9.6; D-13, D-48; UI-42-009/010/023/026).
//
// Биометрия — через порт core/biometrics ([BiometricAuthenticator]): Android/iOS — `biometric_refresh`
// шифруется ключом Keystore/Keychain внутри системного диалога (секрет нигде больше не сохраняется);
// Windows — Windows Hello только как UX-гейт перед PIN (локальный признак, сервер токен не выдаёт).
// Признак «биометрия включена на этом устройстве» — secure storage `auth.biometrics_enabled`
// (`true` — криптопривязка, `windows_hello` — гейт), как у регистрации (SCR-04).
import 'package:logging/logging.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/core/network/interceptors/session_hooks.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/features/settings/data/datasources/settings_api.dart';
import 'package:optomstroy/features/settings/data/outbox/profile_settings_outbox.dart';
import 'package:optomstroy/features/settings/domain/entities/settings_entities.dart';
import 'package:optomstroy/features/settings/domain/repositories/settings_repositories.dart';

final Logger _log = Logger('settings.security');

/// Получить `stepUpToken` для [challenge] (StepUpCoordinator core/session); `null` — отменено.
typedef StepUpObtainer = Future<String?> Function(StepUpChallenge challenge);

final class LoginProtectionRepositoryImpl implements LoginProtectionRepository {
  LoginProtectionRepositoryImpl({
    required SettingsApi api,
    required BiometricAuthenticator biometrics,
    required SecureStorage storage,
    required StepUpObtainer obtainStepUp,
    required Clock clock,
    required BiometricPlatformLabel fallbackLabel,
    ProfileSettingsEnqueue? enqueueOffline,
  }) : _api = api,
       _bio = biometrics,
       _storage = storage,
       _obtainStepUp = obtainStepUp,
       _clock = clock,
       _fallbackLabel = fallbackLabel,
       _enqueueOffline = enqueueOffline;

  /// Версия согласия `biometrics_device`, если `GET /me/consents` её не вернул (как SCR-04; тексты — Q-027).
  static const String fallbackBiometricsConsentVersion = '2026-10-01';

  /// Значение `auth.biometrics_enabled` для Windows Hello (локальный UX-гейт).
  static const String windowsHelloFlag = 'windows_hello';

  final SettingsApi _api;
  final BiometricAuthenticator _bio;
  final SecureStorage _storage;
  final StepUpObtainer _obtainStepUp;
  final Clock _clock;
  final BiometricPlatformLabel _fallbackLabel;

  /// Outbox `profile.settings` (EQ-DREST-07): `null` — обработчик очереди не подключён, офлайн-изменение
  /// возвращает ошибку сети (прежнее поведение, UI откатывает значение).
  final ProfileSettingsEnqueue? _enqueueOffline;

  /// Последний успешный `GET /me` (память процесса) — для «Настройки от {time}» и полного `PUT /me/settings`.
  Map<String, Object?>? _me;
  DateTime? _meAt;

  /// Возможность устройства → вид тумблера (02 UI-42-010).
  static BiometricSupport supportOf(BiometricCapability c) {
    if (c.kind == BiometricKind.windowsHello) {
      return c.isAvailable ? BiometricSupport.windowsHelloGate : BiometricSupport.unavailable;
    }
    return switch (c.availability) {
      BiometricAvailability.available => c.cryptoBinding ? BiometricSupport.cryptoLogin : BiometricSupport.unavailable,
      BiometricAvailability.notEnrolled => BiometricSupport.notEnrolled,
      BiometricAvailability.lockedOut || BiometricAvailability.unsupported => BiometricSupport.unavailable,
    };
  }

  BiometricPlatformLabel _labelOf(BiometricKind kind) => switch (kind) {
    BiometricKind.androidClass3 => BiometricPlatformLabel.android,
    BiometricKind.ios => BiometricPlatformLabel.ios,
    BiometricKind.windowsHello => BiometricPlatformLabel.windows,
    BiometricKind.none => _fallbackLabel,
  };

  @override
  Future<Result<LoginProtectionState>> load() async {
    final Result<Map<String, Object?>> me = await ErrorMapper.guard(_api.me);
    DateTime? staleAt;
    switch (me) {
      case Success<Map<String, Object?>>(:final value):
        _me = value;
        _meAt = _clock.nowUtc();
      case FailureResult<Map<String, Object?>>(:final failure):
        if (_me == null) return FailureResult<LoginProtectionState>(failure);
        staleAt = _meAt;
    }
    final Map<String, Object?> json = _me!;
    final Map<String, Object?> security = _map(json['security']);
    final Map<String, Object?> settings = _map(json['settings']);
    final Map<String, Object?> profile = _map(json['profile']);
    final BiometricCapability capability = await _bio.capability();
    final String? flag = await _storage.read(SecureKey.biometricsEnabled);
    final bool enabled = switch (flag) {
      windowsHelloFlag => capability.kind == BiometricKind.windowsHello,
      null => false,
      _ => capability.cryptoBinding && await _bio.hasStoredSecret(),
    };
    return Success<LoginProtectionState>(
      LoginProtectionState(
        userKind: UserKind.tryParse(json['kind'] as String?),
        pinSet: security['pinSet'] == true,
        biometricsEnabled: enabled,
        support: supportOf(capability),
        platformLabel: _labelOf(capability.kind),
        idleLockMinutes:
            (settings['idleLockMinutes'] as num?) // money-double: allow — геометрия UI (lp)
                ?.toInt(),
        birthYear: (profile['birthYear'] as num?)?.toInt(), // money-double: allow — JSON-число → int (не деньги)
        settingsAsOf: staleAt,
        scannerMode: _map(settings['scanner'])['mode'] as String?,
        scanAddsToCart: settings['scanAddsToCart'] as bool?,
        printerFormat: _map(settings['printer'])['defaultFormat'] as String?,
        printerAutoPrint: _map(settings['printer'])['autoPrint'] as bool?,
      ),
    );
  }

  @override
  Future<Result<void>> changePin(String newPin) => ErrorMapper.guard(() => _api.setPin(newPin));

  @override
  Future<Result<void>> removePin() => ErrorMapper.guard(_api.deletePin);

  @override
  Future<bool> stepUpForPin({required bool otpOnly}) async {
    final String? token = await _obtainStepUp(
      StepUpChallenge(
        operation: SettingsStepUpOperations.pinSet,
        allowedMethods: otpOnly ? const <String>['otp'] : const <String>['pin', 'otp'],
      ),
    );
    return token != null;
  }

  @override
  Future<BiometricToggleOutcome> enableBiometrics(BiometricPromptCopy prompt) async {
    final BiometricCapability capability = await _bio.capability();
    final BiometricPromptText text = BiometricPromptText(
      title: prompt.title,
      subtitle: prompt.subtitle,
      cancel: prompt.cancel,
    );
    if (capability.kind == BiometricKind.windowsHello) {
      if (!capability.isAvailable) return BiometricToggleOutcome.failed;
      final BiometricResult<void> res = await _bio.confirmPresence(text);
      if (!res.isSuccess) return _bioError(res.error!);
      await _storage.write(SecureKey.biometricsEnabled, windowsHelloFlag);
      return BiometricToggleOutcome.enabled;
    }
    if (!capability.supportsCryptoLogin) return BiometricToggleOutcome.failed;

    final String version = await _consentVersion();
    final Result<Map<String, Object?>> issued = await ErrorMapper.guard(
      () => _api.biometrics(<String, Object?>{
        'enabled': true,
        'biometricClass': ?capability.kind.apiClass,
        'consent': <String, Object?>{'kind': ConsentKind.biometricsDevice.value, 'version': version, 'granted': true},
      }),
    );
    switch (issued) {
      case FailureResult<Map<String, Object?>>(:final failure):
        return _serverOutcome(failure);
      case Success<Map<String, Object?>>(:final value):
        final Object? token = value['biometricRefreshToken'];
        if (value['enabled'] != true || token is! String || token.isEmpty) return BiometricToggleOutcome.failed;
        final BiometricResult<void> stored = await _bio.store(token, text);
        if (stored.isSuccess) {
          await _storage.write(SecureKey.biometricsEnabled, 'true');
          return BiometricToggleOutcome.enabled;
        }
        // Системный диалог не подтверждён: выданная семья отзывается (токен области ещё действует — без диалога).
        final Result<Map<String, Object?>> revoked = await ErrorMapper.guard(
          () => _api.biometrics(const <String, Object?>{'enabled': false}),
        );
        if (!revoked.isSuccess) _log.warning('отзыв biometric_refresh после отмены: не выполнен');
        return _bioError(stored.error!);
    }
  }

  @override
  Future<BiometricToggleOutcome> disableBiometrics() async {
    final String? flag = await _storage.read(SecureKey.biometricsEnabled);
    if (flag != windowsHelloFlag) {
      final Result<Map<String, Object?>> res = await ErrorMapper.guard(
        () => _api.biometrics(const <String, Object?>{'enabled': false}),
      );
      if (res case FailureResult<Map<String, Object?>>(:final failure)) return _serverOutcome(failure);
    }
    await _bio.clear();
    await _storage.delete(SecureKey.biometricsEnabled);
    return BiometricToggleOutcome.disabled;
  }

  @override
  Future<Result<int>> setIdleLockMinutes(int minutes) async {
    final Result<Map<String, Object?>> saved = await patchSettings(<String, Object?>{'idleLockMinutes': minutes});
    return saved.map(
      (Map<String, Object?> v) =>
          (v['idleLockMinutes'] as num?)?.toInt() ?? minutes, // money-double: allow — JSON-число → int (не деньги)
    );
  }

  @override
  Future<Result<Map<String, Object?>>> patchSettings(Map<String, Object?> patch) async {
    Map<String, Object?>? cached = _me;
    if (cached == null) {
      final Result<Map<String, Object?>> loaded = await ErrorMapper.guard(_api.me);
      switch (loaded) {
        case FailureResult<Map<String, Object?>>(:final failure):
          return FailureResult<Map<String, Object?>>(failure);
        case Success<Map<String, Object?>>(:final value):
          cached = _me = value;
          _meAt = _clock.nowUtc();
      }
    }
    final Map<String, Object?> me = cached;
    final Map<String, Object?> body = settingsBody(_map(me['settings']), patch);
    Result<Map<String, Object?>> saved = await _put(body);
    // Без сети (02 SCR-42.4, SCR-42.7 (а); EQ-DREST-07): применить локально и отправить через outbox
    // `profile.settings` с `rowVersion` кэша; `409` при отправке — правило «current + изменённые поля».
    if (saved case FailureResult<Map<String, Object?>>(failure: NetworkFailure())) {
      final ProfileSettingsEnqueue? enqueue = _enqueueOffline;
      if (enqueue != null && await enqueue(ProfileSettingsPayload(settings: body, patch: patch).toJson())) {
        _me = <String, Object?>{...me, 'settings': body};
        return Success<Map<String, Object?>>(body);
      }
    }
    // 409 VERSION_CONFLICT: взять `current`, наложить только изменённые поля и отправить ещё раз (одна попытка).
    if (saved case FailureResult<Map<String, Object?>>(failure: ConflictFailure(:final details))) {
      final Object? current = details['current'];
      if (current is Map) saved = await _put(settingsBody(Map<String, Object?>.from(current), patch));
    }
    if (saved case Success<Map<String, Object?>>(:final value)) _me = <String, Object?>{...me, 'settings': value};
    return saved;
  }

  Future<Result<Map<String, Object?>>> _put(Map<String, Object?> body) =>
      ErrorMapper.guard(() => _api.putSettings(body));

  /// Поля `Settings` 08 §3.14 (`MeSettingsPutRequest`, `additionalProperties: false`).
  static const List<String> settingsKeys = <String>[
    'locale',
    'scanner',
    'scanAddsToCart',
    'printer',
    'catalogView',
    'defaultWarehouseId',
    'idleLockMinutes',
    'rowVersion',
  ];

  /// Тело `PUT /me/settings`: текущие значения [current] (только поля `Settings`) + [patch]; вложенные
  /// объекты (`scanner`, `printer`) сливаются по полям.
  static Map<String, Object?> settingsBody(Map<String, Object?> current, Map<String, Object?> patch) {
    final Map<String, Object?> body = <String, Object?>{
      for (final String k in settingsKeys)
        if (current.containsKey(k)) k: current[k],
    };
    for (final MapEntry<String, Object?> e in patch.entries) {
      if (!settingsKeys.contains(e.key) || e.key == 'rowVersion') continue;
      final Object? was = body[e.key];
      final Object? value = e.value;
      body[e.key] = was is Map && value is Map
          ? <String, Object?>{...Map<String, Object?>.from(was), ...Map<String, Object?>.from(value)}
          : value;
    }
    return body;
  }

  Future<String> _consentVersion() async {
    final Result<Map<String, Object?>> res = await ErrorMapper.guard(_api.consents);
    final Object? required = res.valueOrNull?['required'];
    if (required is List) {
      for (final Object? r in required) {
        if (r is Map && r['kind'] == ConsentKind.biometricsDevice.value && r['currentVersion'] is String) {
          return r['currentVersion']! as String;
        }
      }
    }
    return fallbackBiometricsConsentVersion;
  }

  static BiometricToggleOutcome _serverOutcome(Failure failure) => switch (failure) {
    AuthFailure(reason: AuthReason.stepUpRequired) => BiometricToggleOutcome.stepUpCancelled,
    ServerFailure(code: 'CONSENT_REQUIRED') => BiometricToggleOutcome.consentRequired,
    NetworkFailure() => BiometricToggleOutcome.offline,
    _ => BiometricToggleOutcome.failed,
  };

  static BiometricToggleOutcome _bioError(BiometricError e) => switch (e) {
    BiometricError.cancelled => BiometricToggleOutcome.cancelled,
    _ => BiometricToggleOutcome.failed,
  };

  static Map<String, Object?> _map(Object? v) => v is Map ? Map<String, Object?>.from(v) : const <String, Object?>{};
}
