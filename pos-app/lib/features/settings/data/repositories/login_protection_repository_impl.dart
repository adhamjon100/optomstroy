// «Защита входа» SCR-42 (08 §4.3.4–§4.3.6; 09 §8.8, §9.2–§9.6; D-13, D-48; UI-42-009/010/023/026).
//
// Биометрия — через порт core/biometrics ([BiometricAuthenticator]): Android/iOS — `biometric_refresh`
// шифруется ключом Keystore/Keychain внутри системного диалога (секрет нигде больше не сохраняется);
// Windows — Windows Hello только как UX-гейт перед PIN (локальный признак, сервер токен не выдаёт).
// Признак «биометрия включена на этом устройстве» — secure storage `auth.biometrics_enabled` (`true` —
// криптопривязка), как у регистрации (SCR-04). Гейт Windows Hello (режим W1; 15 ADR-116 п. 3; 09 BIO-034) — по
// `userId` вне ключей сессии (`auth.hello_gate_users`, core/biometrics/hello_gate_users.dart): включение и выключение
// меняют признак только текущего пользователя; прежнее значение `windows_hello` ключа сессии не пишется.
//
// Ключ Windows Hello (режим W2 — вход без PIN приложения; ответ владельца на Q-355; 15 ADR-116 п. 3; 09 §9.2 «Вход по
// ключу Windows Hello» п. 1, §9.5 п. 3–4, BIO-038, BIO-040; 02 SCR-42.4 UI-42-010, UI-42-029): режим — по
// `security.windowsHelloKeyAllowed` и `availability` канала `kg.optomstroy/windows_hello` (порт `BiometricHelloKey`).
// Включение: согласие (лист экрана) → создание ключа (диалог Windows Hello) → `POST /me/biometrics {biometricClass:
// windows_hello, helloKey, consent}` (step-up по `403 STEP_UP_REQUIRED` — интерцептор, или 15 мин после входа по SMS)
// → признак `auth.hello_key_users` своего `userId`, признак гейта этого пользователя снимается. `[ВЫВОД исполнителя]`
// Ключ создаётся до запроса: открытый ключ входит в тело, поэтому диалог Windows Hello идёт раньше StepUpDialog (02
// пишет «step-up → создание ключа»); при любом отказе сервера и отмене step-up созданный ключ удаляется. Выключение:
// `POST /me/biometrics {enabled:false}` (S!) → ключ в Windows удаляется, признак снимается; гейт не включается.
// Веб-демо, браузер на Windows (09 BIO-041; 15 ADR-116 п. 4): тот же путь через порт `WebPasskeyAuthenticator` —
// источник ключа `webauthn_prf`; без PRF у браузера или у Windows Hello ключ не создаётся, включается гейт перед PIN
// (`BiometricToggleOutcome.helloKeyNoPrf`, снекбар `settings_hello_key_no_prf`).
//
// Уровень W Android «лицо или отпечаток» (ответ владельца на Q-353; 15 ADR-116 п. 2; 09 BIO-030…BIO-033; 02 SCR-42.4
// «UI-42-010 Android, уровень W», UI-42-024, UI-42-027, UI-42-028): режим — по `security.biometricWeakAllowed`, уровню W
// устройства (`BiometricCapability.supportsWeakLogin`) и порту с записью уровня W (`BiometricWeakStore`); при обоих
// уровнях — выбор, по умолчанию уровень S (Q-354). Включение W: `POST /me/biometrics {biometricClass: class2, consent}`
// → диалог `local_auth` и запись `auth.biometric_refresh_weak` (`BiometricWeakStore.storeWeak`); отказ в диалоге —
// выданная семья отзывается, как у уровня S. `[ВЫВОД исполнителя]` Порядок «запрос → диалог» — как у уровня S (02
// SCR-42 «Уточнения по реализации» п. 2): токена до запроса нет, а диалог один. Отказ сервера `weak_biometrics_disabled`
// — [BiometricToggleOutcome.weakDisabled]. Выключение — общее с уровнем S (`clear` порта удаляет оба уровня).
import 'package:logging/logging.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/biometrics/hello_gate_users.dart';
import 'package:optomstroy/core/biometrics/hello_key_users.dart';
import 'package:optomstroy/core/biometrics/windows_hello_key.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/error_mapper.dart';
import 'package:optomstroy/core/network/interceptors/session_hooks.dart';
import 'package:optomstroy/core/network/models/me_biometrics_dtos.dart';
import 'package:optomstroy/core/session/profile_cache.dart';
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
  /// [currentUserId] — `userId` сессии (гейт Windows Hello по пользователю, 09 BIO-034); без него — `Me.id`
  /// последнего `GET /me`, затем кэш профиля.
  LoginProtectionRepositoryImpl({
    required SettingsApi api,
    required BiometricAuthenticator biometrics,
    required SecureStorage storage,
    required StepUpObtainer obtainStepUp,
    required Clock clock,
    required BiometricPlatformLabel fallbackLabel,
    ProfileSettingsEnqueue? enqueueOffline,
    Future<String?> Function()? currentUserId,
  }) : _api = api,
       _bio = biometrics,
       _storage = storage,
       _helloGate = HelloGateUsers(storage),
       _helloKey = HelloKeyUsers(storage),
       _obtainStepUp = obtainStepUp,
       _clock = clock,
       _fallbackLabel = fallbackLabel,
       _enqueueOffline = enqueueOffline,
       _currentUserId = currentUserId;

  /// Версия согласия `biometrics_device`, если `GET /me/consents` её не вернул (как SCR-04; тексты — Q-027).
  static const String fallbackBiometricsConsentVersion = '2026-10-01';

  final SettingsApi _api;
  final BiometricAuthenticator _bio;
  final SecureStorage _storage;
  final HelloGateUsers _helloGate;
  final HelloKeyUsers _helloKey;
  final StepUpObtainer _obtainStepUp;
  final Clock _clock;
  final BiometricPlatformLabel _fallbackLabel;
  final Future<String?> Function()? _currentUserId;

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

  /// Android с уровнем W (UI-42-010, UI-42-027; 09 BIO-030): уровень W предлагается, если сервер разрешает
  /// ([weakAllowed] = `security.biometricWeakAllowed`), порт умеет записывать секрет уровня W ([weakStore]) и
  /// устройство допускает уровень W; при доступном уровне S — выбор [BiometricSupport.strongOrWeak], иначе
  /// [BiometricSupport.weakLogin]. Иначе — прежнее правило [supportOf].
  static BiometricSupport androidSupportOf(
    BiometricCapability c, {
    required bool weakAllowed,
    required bool weakStore,
  }) {
    if (weakAllowed && weakStore && c.supportsWeakLogin) {
      return c.supportsCryptoLogin ? BiometricSupport.strongOrWeak : BiometricSupport.weakLogin;
    }
    return supportOf(c);
  }

  /// Windows (UI-42-010, UI-42-029): режим ключа (W2) — сервер разрешает ([keyAllowed] =
  /// `security.windowsHelloKeyAllowed`), порт умеет ключи ([keyCapable]) и канал сообщает Windows Hello с поддержкой
  /// ключей; иначе режим гейта (W1), если Windows Hello доступен; иначе недоступно с причиной канала. Канал не ответил
  /// (`unknown`) — как до канала: доступность по `local_auth` ([c]), режим гейта.
  static ({BiometricSupport support, WindowsHelloIssue? issue}) windowsSupportOf(
    BiometricCapability c,
    WindowsHelloStatus status, {
    required bool keyAllowed,
    required bool keyCapable,
  }) {
    final bool known = status.availability != WindowsHelloAvailability.unknown;
    if (!(known ? status.isAvailable : c.isAvailable)) {
      return (support: BiometricSupport.unavailable, issue: issueOf(status.availability));
    }
    if (keyAllowed && keyCapable && status.supportsKey) {
      return (support: BiometricSupport.windowsHelloKey, issue: null);
    }
    return (support: BiometricSupport.windowsHelloGate, issue: null);
  }

  /// `availability` канала → причина UI-42-029; доступен или неизвестно — `null`.
  static WindowsHelloIssue? issueOf(WindowsHelloAvailability a) => switch (a) {
    WindowsHelloAvailability.notConfigured => WindowsHelloIssue.notConfigured,
    WindowsHelloAvailability.deviceNotPresent => WindowsHelloIssue.noDevice,
    WindowsHelloAvailability.disabledByPolicy => WindowsHelloIssue.disabledByPolicy,
    WindowsHelloAvailability.deviceBusy => WindowsHelloIssue.busy,
    WindowsHelloAvailability.available || WindowsHelloAvailability.unknown => null,
  };

  /// Режим Windows по последнему `GET /me` и каналу (без диалога).
  Future<({BiometricSupport support, WindowsHelloIssue? issue})> _windowsMode(BiometricCapability capability) async {
    final BiometricAuthenticator bio = _bio;
    final bool keyCapable = bio is BiometricHelloKey;
    final WindowsHelloStatus status = keyCapable
        ? await (bio as BiometricHelloKey).helloStatus()
        : WindowsHelloStatus.unknown;
    return windowsSupportOf(
      capability,
      status,
      keyAllowed: _map(_me?['security'])['windowsHelloKeyAllowed'] == true,
      keyCapable: keyCapable,
    );
  }

  BiometricPlatformLabel _labelOf(BiometricKind kind) => switch (kind) {
    // Устройство только с уровнем W (15 ADR-116) — та же подпись Android «Вход по отпечатку или лицу»; способ входа —
    // UI-42-027, пояснение уровня W — UI-42-028.
    BiometricKind.androidClass3 || BiometricKind.androidClass2 => BiometricPlatformLabel.android,
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
    final ({BiometricSupport support, WindowsHelloIssue? issue})? windows =
        capability.kind == BiometricKind.windowsHello ? await _windowsMode(capability) : null;
    // Windows Hello: признак этого пользователя, а не общий признак устройства (09 BIO-034); в режиме ключа (W2) — признак
    // ключа, сверенный со свежим `GET /me`. Android: уровень W — по секрету уровня W (`storedTier`), без криптопривязки.
    final bool weakStored = capability.storedTier == BiometricTier.weak;
    final bool enabled = windows != null
        ? await _windowsEnabled(windows.support, security, fresh: staleAt == null)
        : switch (flag) {
            null || HelloGateUsers.legacyFlag => false,
            _ => (weakStored || capability.cryptoBinding) && await _bio.hasStoredSecret(),
          };
    final BiometricLoginTier? tier = windows != null || !enabled
        ? null
        : (weakStored ? BiometricLoginTier.weak : BiometricLoginTier.strong);
    return Success<LoginProtectionState>(
      LoginProtectionState(
        userKind: UserKind.tryParse(json['kind'] as String?),
        pinSet: security['pinSet'] == true,
        biometricsEnabled: enabled,
        support:
            windows?.support ??
            androidSupportOf(
              capability,
              weakAllowed: security['biometricWeakAllowed'] == true,
              weakStore: _bio is BiometricWeakStore,
            ),
        enabledTier: tier,
        // Включён W, а устройство теперь даёт S — подсказка перехода (UI-42-028 upgradeHint; 09 BIO-033).
        upgradeAvailable: tier == BiometricLoginTier.weak && capability.supportsCryptoLogin,
        helloIssue: windows?.issue,
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

  /// Тумблер Windows по режиму: ключ (W2) — признак ключа этого пользователя; гейт (W1) — признак гейта; Windows Hello
  /// недоступен — любой из них (тумблер disabled). Сверка: свежий `GET /me` без ключа устройства на сервере
  /// (`biometricsPlatform` ≠ `windows_hello_key` — ключ отозван: `logout-all`, смена номера, правило `personal`) —
  /// признак ключа снимается, чтобы SCR-08 не предлагал ключ, который сервер не примет (09 BIO-040).
  Future<bool> _windowsEnabled(BiometricSupport mode, Map<String, Object?> security, {required bool fresh}) async {
    final String? userId = await _userId();
    bool key = await _helloKey.contains(userId);
    final Object? platform = security['biometricsPlatform'];
    if (key && fresh && userId != null && platform is String && platform != 'windows_hello_key') {
      await _helloKey.remove(userId);
      key = false;
    }
    return switch (mode) {
      BiometricSupport.windowsHelloKey => key,
      BiometricSupport.windowsHelloGate => await _helloGate.contains(userId),
      _ => key || await _helloGate.contains(userId),
    };
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
  Future<BiometricToggleOutcome> enableBiometrics(
    BiometricPromptCopy prompt, {
    BiometricLoginTier tier = BiometricLoginTier.strong,
  }) async {
    final BiometricCapability capability = await _bio.capability();
    final BiometricPromptText text = BiometricPromptText(
      title: prompt.title,
      subtitle: prompt.subtitle,
      cancel: prompt.cancel,
    );
    if (capability.kind == BiometricKind.windowsHello) {
      final ({BiometricSupport support, WindowsHelloIssue? issue}) mode = await _windowsMode(capability);
      if (mode.support == BiometricSupport.windowsHelloKey) {
        final String? userId = await _userId();
        return userId == null ? BiometricToggleOutcome.failed : _enableHelloKey(userId, text);
      }
      if (!capability.isAvailable) return BiometricToggleOutcome.failed;
      final String? userId = await _userId();
      if (userId == null) return BiometricToggleOutcome.failed;
      final BiometricResult<void> res = await _bio.confirmPresence(text);
      if (!res.isSuccess) return _bioError(res.error!);
      return await _helloGate.add(userId) ? BiometricToggleOutcome.enabled : BiometricToggleOutcome.failed;
    }
    if (tier == BiometricLoginTier.weak) return _enableWeak(capability, text);
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
        await _revokeIssued();
        return _bioError(stored.error!);
    }
  }

  /// Уровень W (15 ADR-116 п. 2; 09 BIO-030; 02 SCR-42.4): `POST /me/biometrics {enabled, biometricClass: class2,
  /// consent}` (step-up — интерцептор) → диалог `local_auth` «лицо или отпечаток» и запись секрета уровня W. Без порта
  /// с записью уровня W или без доступного уровня W — [BiometricToggleOutcome.failed] без запроса.
  Future<BiometricToggleOutcome> _enableWeak(BiometricCapability capability, BiometricPromptText text) async {
    final BiometricAuthenticator bio = _bio;
    if (bio is! BiometricWeakStore || !capability.supportsWeakLogin) return BiometricToggleOutcome.failed;
    final String version = await _consentVersion();
    final Result<Map<String, Object?>> issued = await ErrorMapper.guard(
      () => _api.biometrics(
        MeBiometricsRequestDto.toJson(
          enabled: true,
          biometricClass: capability.kindFor(BiometricTier.weak).apiClass,
          consent: MeBiometricsConsentDto(version: version),
        ),
      ),
    );
    switch (issued) {
      case FailureResult<Map<String, Object?>>(:final failure):
        return _serverOutcome(failure);
      case Success<Map<String, Object?>>(:final value):
        final MeBiometricsResponseDto response = MeBiometricsResponseDto.fromJson(value);
        if (!response.enabled) {
          return response.reason == MeBiometricsRefusal.weakBiometricsDisabled
              ? BiometricToggleOutcome.weakDisabled
              : BiometricToggleOutcome.failed;
        }
        final String? token = response.biometricRefreshToken;
        if (token == null) return BiometricToggleOutcome.failed;
        final BiometricResult<void> stored = await (bio as BiometricWeakStore).storeWeak(token, text);
        if (stored.isSuccess) {
          await _storage.write(SecureKey.biometricsEnabled, 'true');
          return BiometricToggleOutcome.enabled;
        }
        await _revokeIssued();
        return _bioError(stored.error!);
    }
  }

  /// Диалог после выдачи семьи не подтверждён — семья отзывается (токен области step-up ещё действует).
  Future<void> _revokeIssued() async {
    final Result<Map<String, Object?>> revoked = await ErrorMapper.guard(
      () => _api.biometrics(const <String, Object?>{'enabled': false}),
    );
    if (!revoked.isSuccess) _log.warning('отзыв biometric_refresh после отмены: не выполнен');
  }

  /// Ключ Windows Hello (W2): создание ключа → `POST /me/biometrics` с открытым ключом. Отказ сервера, отмена step-up,
  /// ошибка сети — созданный ключ удаляется (на сервере его нет). Источник ключа — порта ([helloKeySourceOf]):
  /// приложение Windows — `windows_hello`, браузер на Windows в веб-демо — `webauthn_prf` (09 BIO-041); браузер без PRF —
  /// гейт перед PIN и [BiometricToggleOutcome.helloKeyNoPrf] (02 SCR-42.4 «UI-42-010 веб-демо»).
  Future<BiometricToggleOutcome> _enableHelloKey(String userId, BiometricPromptText text) async {
    final BiometricHelloKey key = _bio as BiometricHelloKey;
    final BiometricAuthenticator bio = _bio;
    final BiometricResult<String> created;
    if (bio is BrowserHelloKey) {
      final BrowserHelloKeyCreation creation = await (bio as BrowserHelloKey).createBrowserHelloKey(userId);
      if (creation.noPrf) return _helloKeyNoPrf(userId, text, gateReady: creation.gate);
      created = creation.key;
    } else {
      created = await key.createHelloKey(userId);
    }
    final String? publicKey = created.value;
    if (!created.isSuccess || publicKey == null) return _bioError(created.error ?? BiometricError.failed);
    final String version = await _consentVersion();
    final Result<Map<String, Object?>> issued = await ErrorMapper.guard(
      () => _api.biometrics(
        MeBiometricsRequestDto.toJson(
          enabled: true,
          biometricClass: BiometricKind.windowsHello.apiClass,
          helloKey: MeBiometricsHelloKeyDto(publicKey: publicKey, source: helloKeySourceOf(key)),
          consent: MeBiometricsConsentDto(version: version),
        ),
      ),
    );
    switch (issued) {
      case FailureResult<Map<String, Object?>>(:final failure):
        await key.deleteHelloKey(userId);
        return _serverOutcome(failure);
      case Success<Map<String, Object?>>(:final value):
        final MeBiometricsResponseDto response = MeBiometricsResponseDto.fromJson(value);
        if (response.enabled) {
          if (!await _helloKey.add(userId)) {
            _log.warning('признак ключа Windows Hello не записан');
            return BiometricToggleOutcome.failed;
          }
          // Ключ заменяет гейт этого пользователя (02 SCR-42.4); гейты других пользователей не меняются.
          await _helloGate.remove(userId);
          return BiometricToggleOutcome.enabled;
        }
        await key.deleteHelloKey(userId);
        return switch (response.reason) {
          MeBiometricsRefusal.helloKeyDisabled => BiometricToggleOutcome.helloKeyDisabled,
          MeBiometricsRefusal.helloKeySharedDevice => BiometricToggleOutcome.helloKeySharedDevice,
          _ => BiometricToggleOutcome.failed,
        };
    }
  }

  /// Веб-демо, браузер на Windows без PRF (09 BIO-041; 02 SCR-42.4 «UI-42-010 веб-демо»): passkey браузера остаётся
  /// ключом гейта — включается гейт этого пользователя (сервер о гейте не знает). [gateReady] — присутствие уже
  /// подтверждено диалогом создания passkey; иначе — диалог гейта, как у режима W1. `[ВЫВОД исполнителя]`
  Future<BiometricToggleOutcome> _helloKeyNoPrf(
    String userId,
    BiometricPromptText text, {
    required bool gateReady,
  }) async {
    if (!gateReady) {
      final BiometricResult<void> res = await _bio.confirmPresence(text);
      if (!res.isSuccess) return _bioError(res.error!);
    }
    return await _helloGate.add(userId) ? BiometricToggleOutcome.helloKeyNoPrf : BiometricToggleOutcome.failed;
  }

  @override
  Future<BiometricToggleOutcome> disableBiometrics() async {
    final String? flag = await _storage.read(SecureKey.biometricsEnabled);
    final String? userId = await _userId();
    // Ключ Windows Hello (W2): отзыв на сервере (S!), затем ключ в Windows и признак; гейт не включается.
    if (userId != null && await _helloKey.contains(userId)) {
      final BiometricCapability capability = await _bio.capability();
      if (capability.kind == BiometricKind.windowsHello &&
          (await _windowsMode(capability)).support == BiometricSupport.windowsHelloKey) {
        return _disableHelloKey(userId);
      }
    }
    // Гейт Windows Hello — признак на устройстве, сервер о нём не знает: без запроса; снимается только свой (BIO-034).
    final bool gate = flag == HelloGateUsers.legacyFlag || await _helloGate.contains(userId);
    if (!gate) {
      final Result<Map<String, Object?>> res = await ErrorMapper.guard(
        () => _api.biometrics(const <String, Object?>{'enabled': false}),
      );
      if (res case FailureResult<Map<String, Object?>>(:final failure)) return _serverOutcome(failure);
    }
    await _bio.clear();
    if (gate && userId != null) await _helloGate.remove(userId);
    await _storage.delete(SecureKey.biometricsEnabled);
    return BiometricToggleOutcome.disabled;
  }

  Future<BiometricToggleOutcome> _disableHelloKey(String userId) async {
    final Result<Map<String, Object?>> res = await ErrorMapper.guard(
      () => _api.biometrics(MeBiometricsRequestDto.toJson(enabled: false)),
    );
    if (res case FailureResult<Map<String, Object?>>(:final failure)) return _serverOutcome(failure);
    await _helloKey.remove(userId);
    await (_bio as BiometricHelloKey).deleteHelloKey(userId);
    await _storage.delete(SecureKey.biometricsEnabled);
    return BiometricToggleOutcome.disabled;
  }

  /// Пользователь сессии: [_currentUserId], иначе `Me.id` последнего `GET /me`, иначе кэш профиля (02 §0.4).
  Future<String?> _userId() async {
    try {
      final String? session = await _currentUserId?.call();
      if (session != null) return session;
      final Object? id = _me?['id'];
      if (id is String && id.isNotEmpty) return id;
      return (await ProfileCacheStore(_storage).read())?.userId;
    } on Object {
      return null;
    }
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
