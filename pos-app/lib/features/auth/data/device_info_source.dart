// Сведения об устройстве для `OtpVerifyRequest.device` (08 §4.1.2; `AuthDeviceInfo`).
// Имя — модель устройства (Android/iOS) или имя компьютера (Windows-POS, «Касса-2»);
// пользовательское имя iPhone («iPhone Ивана») не берётся — это ПДн.
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
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
  }) : _meta = meta,
       _biometrics = biometrics,
       _plugin = plugin ?? DeviceInfoPlugin();

  final ClientMeta Function() _meta;
  final BiometricUnlock Function() _biometrics;
  final DeviceInfoPlugin _plugin;

  @override
  Future<AuthDeviceInfoDto> read() async {
    final ClientMeta meta = _meta();
    final ClientPlatform platform = meta.platform ?? ClientPlatform.android;
    String name = platform.name;
    String? os;
    try {
      switch (platform) {
        case ClientPlatform.android:
          final AndroidDeviceInfo a = await _plugin.androidInfo;
          name = '${a.manufacturer} ${a.model}'.trim();
          os = a.version.release;
        case ClientPlatform.ios:
          final IosDeviceInfo i = await _plugin.iosInfo;
          name = i.modelName.isEmpty ? i.model : i.modelName;
          os = i.systemVersion;
        case ClientPlatform.windows:
          final WindowsDeviceInfo w = await _plugin.windowsInfo;
          name = w.computerName;
          os = w.displayVersion.isEmpty ? '${w.majorVersion}.${w.buildNumber}' : w.displayVersion;
      }
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

  Future<String> _biometricClass() async {
    final BiometricUnlockKind kind = await _biometrics().capability();
    return switch (kind) {
      BiometricUnlockKind.cryptoBound => 'class3',
      BiometricUnlockKind.windowsHelloGate => 'windows_hello',
      BiometricUnlockKind.none => 'none',
    };
  }
}
