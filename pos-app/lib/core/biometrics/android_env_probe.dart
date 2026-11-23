// Окружение Android для уровня W входа по биометрии (15 ADR-116 п. 2; 09 BIO-026, BIO-030; 11 SEC-090; 06 §6.2):
// версия API (уровень W — только API ≥ 30), физическое устройство или эмулятор и вид сборки (release или debug/profile).
// В `ENV=prod` уровень W не предлагается на эмуляторе и вне release-сборки (обязательный минимум R1 SEC-090,
// проверка на Dart); root не определяется (RR-7, Q-037). Уровень S этой проверкой пока не ограничивается
// (11 SEC-090: для уровня S минимум R1 не реализован — отдельное решение).
//
// Порт нужен для тестов (12 T-BIO-019): реализация — `device_info_plus` (уже в зависимостях), признак сборки —
// `kReleaseMode`. Данных пользователя нет: только версия API и признаки устройства и сборки.
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kReleaseMode;

/// Снимок окружения Android (не меняется за время жизни процесса).
final class AndroidEnv {
  const AndroidEnv({required this.sdkInt, required this.isPhysicalDevice, required this.isReleaseBuild});

  /// `Build.VERSION.SDK_INT`.
  final int sdkInt;

  /// `false` — эмулятор (`device_info_plus` `isPhysicalDevice`).
  final bool isPhysicalDevice;

  /// `true` — release-сборка (`kReleaseMode`); debug и profile — `false`.
  final bool isReleaseBuild;

  @override
  String toString() => 'AndroidEnv(api $sdkInt, physical: $isPhysicalDevice, release: $isReleaseBuild)';
}

/// Порт окружения Android (в тестах — подмена).
abstract interface class AndroidEnvProbe {
  /// Снимок окружения; ошибки платформы (`PlatformException`, `MissingPluginException`) пробрасываются —
  /// вызывающий считает уровень W недоступным.
  Future<AndroidEnv> read();
}

/// Реализация на `device_info_plus`; результат запоминается на время жизни объекта (в том числе ошибка).
final class DeviceInfoAndroidEnvProbe implements AndroidEnvProbe {
  DeviceInfoAndroidEnvProbe([DeviceInfoPlugin? plugin]) : _plugin = plugin ?? DeviceInfoPlugin();

  final DeviceInfoPlugin _plugin;
  Future<AndroidEnv>? _env;

  @override
  Future<AndroidEnv> read() => _env ??= _load();

  Future<AndroidEnv> _load() async {
    final AndroidDeviceInfo info = await _plugin.androidInfo;
    return AndroidEnv(
      sdkInt: info.version.sdkInt,
      isPhysicalDevice: info.isPhysicalDevice,
      isReleaseBuild: kReleaseMode,
    );
  }
}
