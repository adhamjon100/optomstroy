// Сведения об устройстве для `OtpVerifyRequest.device` (08 §4.1.2; `AuthDeviceInfo`).
// Имя — модель устройства (Android/iOS) или имя компьютера (Windows-POS, «Касса-2»);
// пользовательское имя iPhone («iPhone Ивана») не берётся — это ПДн.
// В браузере (веб-демо) — название браузера и `navigator.platform`; платформа — `windows` в браузере на Windows,
// иначе `android` (значения `web` сервер не знает; core/network/browser_device.dart).
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:optomstroy/core/network/browser_device.dart';
import 'package:optomstroy/core/network/client_meta.dart';
import 'package:optomstroy/features/auth/data/dto/auth_dtos.dart';
import 'package:optomstroy/features/auth/domain/ports/biometric_unlock.dart';

/// Источник `AuthDeviceInfo` (в тестах — фейк).
abstract interface class DeviceInfoSource {
  Future<AuthDeviceInfoDto> read();
}

final class PlatformDeviceInfoSource implements DeviceInfoSource {
  PlatformDeviceInfoSource({
    required ClientMeta Function() meta,
    required BiometricUnlock Function() biometrics,
    DeviceInfoPlugin? plugin,
    bool isWeb = kIsWeb,
  }) : _meta = meta,
       _biometrics = biometrics,
       _plugin = plugin ?? DeviceInfoPlugin(),
       _isWeb = isWeb;

  final ClientMeta Function() _meta;
  final BiometricUnlock Function() _biometrics;
  final DeviceInfoPlugin _plugin;

  /// Сборка для браузера (тесты подставляют `true`).
  final bool _isWeb;

  @override
  Future<AuthDeviceInfoDto> read() async {
    final ClientMeta meta = _meta();
    final ClientPlatform platform = _isWeb
        ? browserDevicePlatform(meta.platform)
        : meta.platform ?? ClientPlatform.android;
    String name = platform.name;
    String? os;
    try {
      // В браузере `androidInfo`/`windowsInfo` падают приведением типа (TypeError) — вход по OTP не проходил бы.
      final ({String name, String? os}) device = _isWeb ? await readBrowserDevice(_plugin) : await _native(platform);
      name = device.name;
      os = device.os;
    } on PlatformException {
      // Имя устройства не критично для входа: остаётся имя платформы.
    } on MissingPluginException {
      // То же (тесты, неподдержанная платформа).
    }
    return AuthDeviceInfoDto(
      name: name,
      platform: platform.name,
      osVersion: os,
      appVersion: meta.appVersion,
      // iOS: в `AuthDeviceInfo.biometricClass` нет значения для Face ID/Touch ID — поле не передаётся (RB-04).
      biometricClass: platform == ClientPlatform.ios ? null : await _biometricClass(),
    );
  }

  Future<({String name, String? os})> _native(ClientPlatform platform) async {
    switch (platform) {
      case ClientPlatform.android:
        final AndroidDeviceInfo a = await _plugin.androidInfo;
        return (name: '${a.manufacturer} ${a.model}'.trim(), os: a.version.release);
      case ClientPlatform.ios:
        final IosDeviceInfo i = await _plugin.iosInfo;
        return (name: i.modelName.isEmpty ? i.model : i.modelName, os: i.systemVersion);
      case ClientPlatform.windows:
        final WindowsDeviceInfo w = await _plugin.windowsInfo;
        return (
          name: w.computerName,
          os: w.displayVersion.isEmpty ? '${w.majorVersion}.${w.buildNumber}' : w.displayVersion,
        );
    }
  }

  Future<String> _biometricClass() async {
    final BiometricUnlockKind kind = await _biometrics().capability();
    return switch (kind) {
      BiometricUnlockKind.cryptoBound => 'class3',
      BiometricUnlockKind.windowsHelloGate => 'windows_hello',
      BiometricUnlockKind.none => 'none',
    };
  }
}
