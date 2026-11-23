// Порт биометрии на Windows: гейт Windows Hello перед PIN (W1, `local_auth` — [WindowsHelloGate], без изменений) и
// ключ Windows Hello для входа без PIN приложения (W2 — канал `kg.optomstroy/windows_hello`; 15 ADR-116 п. 3;
// 09 §9.2 «Вход по ключу Windows Hello», BIO-005, BIO-038…BIO-040; 11 SEC-146, RR-10; 06 §6.2).
//
// Методы `BiometricAuthenticator` — как у гейта: `capability` — Windows Hello без криптопривязки (SCR-04, SCR-08 W1 и
// `AuthDeviceInfo.biometricClass = windows_hello` прежние), `store`/`read` недоступны, `confirmPresence` — диалог
// `local_auth`. [clear] ключ Windows Hello **не** удаляет: его вызывают выход, `logout-all`, `SESSION_REVOKED`
// (sessionCleanupHooksProvider), а ключ переживает выход и конец сессии (BIO-040); на сервере его отзывают
// `logout-all`, смена номера и подключение планшета, на устройстве ключ удаляют выключение в SCR-42, отказ сервера,
// пропажа ключа (фичи — через [deleteHelloKey]) и подключение планшета магазина (`SessionController.becomeKiosk` —
// [deleteHelloKey] для каждого пользователя из `auth.hello_key_users` до удаления списка; 09 BIO-037). Ключ W2 —
// необязательный интерфейс [BiometricHelloKey].
import 'dart:convert';
import 'dart:typed_data';

import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/biometrics/windows_hello_gate.dart';
import 'package:optomstroy/core/biometrics/windows_hello_key.dart';
import 'package:optomstroy/core/biometrics/windows_hello_key_channel.dart';

final class WindowsHelloKeyAuthenticator implements BiometricAuthenticator, BiometricHelloKey {
  /// [gate] — гейт W1 (по умолчанию [WindowsHelloGate] на `local_auth`); [channel] — канал ключа (подмена в тестах).
  WindowsHelloKeyAuthenticator({BiometricAuthenticator? gate, WindowsHelloKeyChannel? channel})
    : _gate = gate ?? WindowsHelloGate(),
      _channel = channel ?? WindowsHelloKeyChannel();

  final BiometricAuthenticator _gate;
  final WindowsHelloKeyChannel _channel;

  @override
  Future<BiometricCapability> capability() => _gate.capability();

  @override
  Future<BiometricResult<void>> store(String secret, BiometricPromptText prompt) async =>
      const BiometricResult.failure(BiometricError.notAvailable);

  @override
  Future<BiometricResult<String>> read(BiometricPromptText prompt) async =>
      const BiometricResult.failure(BiometricError.notAvailable);

  @override
  Future<bool> hasStoredSecret() async => false;

  /// Секретов `biometric_refresh` на Windows нет; ключ Windows Hello здесь не удаляется (см. шапку файла).
  @override
  Future<void> clear() async {}

  @override
  Future<BiometricResult<void>> confirmPresence(BiometricPromptText prompt) => _gate.confirmPresence(prompt);

  @override
  Future<WindowsHelloStatus> helloStatus() => _channel.availability();

  @override
  Future<BiometricResult<String>> createHelloKey(String userId) async {
    if (userId.trim().isEmpty) return const BiometricResult.failure(BiometricError.failed);
    final HelloChannelReply reply = await _channel.createKey(helloKeyName(userId));
    final Uint8List? key = reply.bytes;
    if (reply.isOk && key != null) return BiometricResult.success(base64UrlNoPadding(key));
    return BiometricResult.failure(errorOf(reply.status, creating: true));
  }

  @override
  Future<BiometricResult<String>> signHelloChallenge(String userId, String challenge) async {
    if (userId.trim().isEmpty || !challenge.startsWith(helloChallengePrefix)) {
      return const BiometricResult.failure(BiometricError.failed);
    }
    final HelloChannelReply reply = await _channel.sign(
      helloKeyName(userId),
      Uint8List.fromList(utf8.encode(challenge)),
    );
    final Uint8List? signature = reply.bytes;
    if (reply.isOk && signature != null) return BiometricResult.success(base64UrlNoPadding(signature));
    return BiometricResult.failure(errorOf(reply.status, creating: false));
  }

  @override
  Future<bool> deleteHelloKey(String userId) async {
    if (userId.trim().isEmpty) return false;
    return (await _channel.deleteKey(helloKeyName(userId))).isOk;
  }

  /// Статус канала → [BiometricError]. `not_found`: при создании — Windows Hello не настроен, при подписи — ключ
  /// пропал в Windows (09 §9.2 W2 п. 4). «Предпочитаю пароль» — как отмена.
  static BiometricError errorOf(String status, {required bool creating}) => switch (status) {
    WindowsHelloKeyChannel.statusCancelled ||
    WindowsHelloKeyChannel.statusUserPrefersPassword => BiometricError.cancelled,
    WindowsHelloKeyChannel.statusNotFound => creating ? BiometricError.notEnrolled : BiometricError.noCredential,
    WindowsHelloKeyChannel.statusSecurityDeviceLocked => BiometricError.lockout,
    WindowsHelloKeyChannel.statusUnavailable => BiometricError.notAvailable,
    _ => BiometricError.failed,
  };

  /// base64url без `=` — формат `MeBiometricsHelloKey.publicKey` и `AuthUnlockRequest.signature` (08 §4.1.8, §4.3.6).
  static String base64UrlNoPadding(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
}
