// Адаптер порта SCR-08 [BiometricUnlock] к `BiometricAuthenticator` core/biometrics (RM-D-008;
// D-13; ядро §21 п.2 — собственный platform channel: Android Keystore + BiometricPrompt.CryptoObject,
// iOS Keychain biometryCurrentSet; Windows Hello — только UX-гейт перед PIN).
// Секрет (`biometric_refresh`) не логируется; биометрические данные приложение не получает.
//
// Windows Hello (режим W1; 15 ADR-116 п. 3; 09 BIO-034): кнопка гейта — только у пользователя, включившего его на этом
// устройстве (`auth.hello_gate_users`, вне ключей сессии; core/biometrics/hello_gate_users.dart). Пользователь — `userId`
// сессии, на холодном старте — из кэша профиля (02 §0.4); неизвестен (кэш прежней версии) — кнопки нет до первой
// разблокировки PIN.
//
// Ключ Windows Hello (режим W2 — вход без PIN приложения; 15 ADR-116 п. 3; 09 BIO-038, BIO-039; 02 SCR-08.4): кнопка
// «Войти через Windows Hello» — у пользователя с признаком `auth.hello_key_users` (core/biometrics/hello_key_users.dart)
// при порте с ключом (`BiometricHelloKey`); признак ключа важнее признака гейта. Доступность Windows Hello для кнопки
// не проверяется: если ключ пропал в Windows, подпись сообщит об этом (`unlock_hello_key_lost`). Подпись — [HelloKeyUnlock].
//
// Уровень W Android (15 ADR-116 п. 2; 09 BIO-030…BIO-033; 02 SCR-08.4 п. 9, п. 10): вид [BiometricUnlockKind.weakBound] —
// сохранён секрет уровня W (`BiometricCapability.storedTier`) и устройство сейчас допускает уровень W; заголовок диалога —
// `auth_bio_prompt_face`; новый токен после разблокировки пишется в то же место без второго диалога
// (`BiometricSecretReplacer.replace`), на уровень S (новый ключ, диалог) не переходит.
//
// Планшет магазина (09 BIO-037; 12 T-BIO-033): в сессии планшета и на устройстве с признаком планшета порт core не
// вызывается — вид `none`, чтение и подтверждение недоступны (SCR-08 планшету и так не показывается, G-15).
import 'dart:ui' show Locale;

import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/biometrics/hello_gate_users.dart';
import 'package:optomstroy/core/biometrics/hello_key_users.dart';
import 'package:optomstroy/core/biometrics/windows_hello_key.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/profile_cache.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/features/auth/domain/ports/biometric_unlock.dart';

final class BiometricUnlockAdapter implements BiometricUnlock, HelloKeyUnlock {
  /// [currentUserId] — пользователь SCR-08 (`userId` сессии, иначе кэш профиля); по умолчанию — кэш профиля.
  BiometricUnlockAdapter({
    required BiometricAuthenticator authenticator,
    required SecureStorage storage,
    String Function()? languageCode,
    Future<String?> Function()? currentUserId,
    bool Function()? kioskMode,
  }) : _auth = authenticator,
       _helloGate = HelloGateUsers(storage),
       _helloKey = HelloKeyUsers(storage),
       _languageCode = languageCode ?? _ru,
       _currentUserId = currentUserId ?? (() async => (await ProfileCacheStore(storage).read())?.userId),
       _kioskMode = kioskMode ?? _never;

  static String _ru() => 'ru';

  static bool _never() => false;

  final BiometricAuthenticator _auth;
  final HelloGateUsers _helloGate;
  final HelloKeyUsers _helloKey;
  final String Function() _languageCode;
  final Future<String?> Function() _currentUserId;

  /// Режим планшета магазина (сессия `kind=kiosk` или признак планшета на устройстве): биометрия не вызывается.
  final bool Function() _kioskMode;

  /// Уровень сохранённого секрета по последнему ответу порта ([kind], [readSecret]); [_tierKnown] = `false` — ещё не
  /// спрашивали.
  BiometricTier? _tier;
  bool _tierKnown = false;

  /// Тексты системного диалога — ARB: уровень S — `unlock_bio_button`, уровень W — `auth_bio_prompt_face` (02 SCR-08.4
  /// п. 9); отрицательная кнопка — `ds_button_cancel`.
  BiometricPromptText _prompt({bool face = false}) {
    final AppLocalizations l10n = lookupAppLocalizations(Locale(_languageCode()));
    return BiometricPromptText(
      title: face ? l10n.auth_bio_prompt_face : l10n.unlock_bio_button,
      cancel: l10n.ds_button_cancel,
    );
  }

  bool get _weak => _tier == BiometricTier.weak;

  void _remember(BiometricTier? tier) {
    _tier = tier;
    _tierKnown = true;
  }

  bool _kiosk() {
    try {
      return _kioskMode();
    } on Object {
      return false;
    }
  }

  /// Возможность устройства для `AuthDeviceInfo.biometricClass` (device_info_source.dart): уровень S надёжнее и
  /// важнее — при Class 3 и уровне W `cryptoBound`; устройство только с уровнем W (15 ADR-116, 09 BIO-030) —
  /// `weakBound` (`class2`). Вид текущего пользователя (сохранённый секрет, SCR-08) — [kind].
  @override
  Future<BiometricUnlockKind> capability() async {
    if (_kiosk()) return BiometricUnlockKind.none;
    final BiometricCapability c = await _auth.capability();
    if (c.supportsCryptoLogin) {
      return BiometricUnlockKind.cryptoBound;
    }
    if (c.supportsWeakLogin) {
      return BiometricUnlockKind.weakBound;
    }
    if (c.kind == BiometricKind.windowsHello && c.isAvailable) {
      return BiometricUnlockKind.windowsHelloGate;
    }
    return BiometricUnlockKind.none;
  }

  /// Вид для SCR-08: уровень W — сохранён секрет уровня W и уровень W доступен (секрет при недоступном уровне W —
  /// кнопки нет, как у уровня S без доступной биометрии; удаляет его чтение по BIO-033 или выход); уровень S — уровень
  /// S доступен и сохранён секрет не уровня W; Windows — ключ (W2) или гейт (W1) этого пользователя.
  @override
  Future<BiometricUnlockKind> kind() async {
    if (_kiosk()) return BiometricUnlockKind.none;
    final BiometricCapability c = await _auth.capability();
    _remember(c.storedTier);
    if (c.storedTier == BiometricTier.weak) {
      return c.supportsWeakLogin && await _auth.hasStoredSecret()
          ? BiometricUnlockKind.weakBound
          : BiometricUnlockKind.none;
    }
    if (c.supportsCryptoLogin && await _auth.hasStoredSecret()) {
      return BiometricUnlockKind.cryptoBound;
    }
    if (c.kind == BiometricKind.windowsHello) {
      final String? userId = await _userId();
      if (_auth is BiometricHelloKey && await _helloKey.contains(userId)) {
        return BiometricUnlockKind.windowsHelloKey;
      }
      if (c.isAvailable && await _helloGate.contains(userId)) {
        return BiometricUnlockKind.windowsHelloGate;
      }
    }
    return BiometricUnlockKind.none;
  }

  @override
  Future<BiometricSecretResult> readSecret() async {
    if (_kiosk()) return const BiometricSecretUnavailable();
    if (!_tierKnown) _remember((await _auth.capability()).storedTier);
    final BiometricResult<String> r = await _auth.read(_prompt(face: _weak));
    if (r.isSuccess && r.value != null) {
      return BiometricSecretOk(r.value!);
    }
    return switch (r.error) {
      BiometricError.cancelled => const BiometricSecretCancelled(),
      BiometricError.lockout => const BiometricSecretLockedOut(),
      BiometricError.invalidated => const BiometricSecretInvalidated(),
      _ => const BiometricSecretUnavailable(),
    };
  }

  /// Новый biometric refresh после `/auth/unlock {method: biometric}` (02 SCR-08.4 п. 3; AU-07): тем же ключом
  /// (`BiometricSecretReplacer.replace`); ключа нет или канал без метода `replace` — `store` (новый ключ). Уровень W
  /// (02 SCR-08.4 п. 10) — только запись в то же место без диалога: не удалась — `false` без перехода на уровень S.
  @override
  Future<bool> storeSecret(String secret) async {
    final BiometricAuthenticator auth = _auth;
    final bool weak = _weak;
    if (auth is BiometricSecretReplacer) {
      final BiometricResult<void> replaced = await (auth as BiometricSecretReplacer).replace(
        secret,
        _prompt(face: weak),
      );
      if (replaced.isSuccess) return true;
      if (weak) return false;
      if (replaced.error != BiometricError.noCredential && replaced.error != BiometricError.notAvailable) {
        return false;
      }
    }
    if (weak) return false;
    return (await auth.store(secret, _prompt())).isSuccess;
  }

  @override
  Future<void> clear() async {
    _tierKnown = false;
    _tier = null;
    await _auth.clear();
  }

  @override
  Future<bool> confirmPresence() async {
    if (_kiosk()) return false;
    return (await _auth.confirmPresence(_prompt())).isSuccess;
  }

  /// Подпись challenge ключом Windows Hello текущего пользователя (W2; 09 §9.2 W2 п. 3–4). Пользователь неизвестен или
  /// порт без ключа — [HelloKeySignFailed] без диалога.
  @override
  Future<HelloKeySignResult> signHelloChallenge(String challenge) async {
    final BiometricAuthenticator auth = _auth;
    if (_kiosk()) return const HelloKeySignFailed();
    final String? userId = await _userId();
    if (auth is! BiometricHelloKey || userId == null) return const HelloKeySignFailed();
    final BiometricResult<String> signed = await (auth as BiometricHelloKey).signHelloChallenge(userId, challenge);
    final String? signature = signed.value;
    if (signed.isSuccess && signature != null) return HelloKeySigned(signature);
    return switch (signed.error) {
      BiometricError.cancelled => const HelloKeySignCancelled(),
      BiometricError.noCredential => const HelloKeyLost(),
      _ => const HelloKeySignFailed(),
    };
  }

  /// Признак ключа текущего пользователя снимается, ключ в Windows удаляется (без диалога); гейт W1 не трогается.
  @override
  Future<void> forgetHelloKey() async {
    final String? userId = await _userId();
    if (userId == null) return;
    await _helloKey.remove(userId);
    final BiometricAuthenticator auth = _auth;
    if (auth is BiometricHelloKey) await (auth as BiometricHelloKey).deleteHelloKey(userId);
  }

  Future<String?> _userId() async {
    try {
      return await _currentUserId();
    } on Object {
      return null;
    }
  }
}
