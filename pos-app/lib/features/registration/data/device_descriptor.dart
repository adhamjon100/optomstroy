// `device` для `POST /registration/complete` (08 `AuthDeviceInfo`: name, platform, osVersion, appVersion,
// biometricClass; `model` не передаётся — additionalProperties:false, 02 AC-UI-04-019).
// В браузере (веб-демо) — название браузера, `navigator.platform` и платформа как у входа по OTP
// (core/network/browser_device.dart): `windows` в браузере на Windows, иначе `android`.
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:optomstroy/core/network/browser_device.dart';
import 'package:optomstroy/core/network/client_meta.dart';

/// Источник сведений об устройстве (подменяется в тестах).
abstract interface class DeviceDescriptorSource {
  Future<Map<String, Object?>> describe({String? biometricClass});
}

final class PluginDeviceDescriptorSource implements DeviceDescriptorSource {
  /// [isWeb] — сборка для браузера (тесты подставляют `true`).
  PluginDeviceDescriptorSource(this._meta, [DeviceInfoPlugin? plugin, bool isWeb = kIsWeb])
    : _plugin = plugin ?? DeviceInfoPlugin(),
      _isWeb = isWeb;

  final ClientMeta Function() _meta;
  final DeviceInfoPlugin _plugin;
  final bool _isWeb;

  @override
  Future<Map<String, Object?>> describe({String? biometricClass}) async {
    final meta = _meta();
    final String platform = _isWeb ? browserDevicePlatform(meta.platform).name : meta.platform?.name ?? 'windows';
    var name = 'POS';
    String? os;
    try {
      final ({String name, String? os})? device = _isWeb ? await readBrowserDevice(_plugin) : await _native();
      if (device != null) {
        name = device.name;
        os = device.os;
      }
    } on Object {
      // Сведения необязательны: имя по умолчанию, osVersion не передаётся.
    }
    return deviceInfoJson(
      name: name,
      platform: platform,
      appVersion: meta.appVersion,
      osVersion: os,
      biometricClass: biometricClass,
    );
  }

  Future<({String name, String? os})?> _native() async {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        final a = await _plugin.androidInfo;
        return (name: '${a.manufacturer} ${a.model}', os: a.version.release);
      case TargetPlatform.iOS:
        final i = await _plugin.iosInfo;
        return (name: i.model, os: i.systemVersion);
      case TargetPlatform.windows:
        final w = await _plugin.windowsInfo;
        return (name: w.computerName, os: '${w.majorVersion}.${w.minorVersion}.${w.buildNumber}');
      default:
        return null;
    }
  }

  /// Сборка JSON с ограничениями схемы (name 1…100, osVersion ≤ 32, appVersion ≤ 32).
  static Map<String, Object?> deviceInfoJson({
    required String name,
    required String platform,
    required String appVersion,
    String? osVersion,
    String? biometricClass,
  }) {
    final trimmed = name.trim().isEmpty ? 'POS' : name.trim();
    return <String, Object?>{
      'name': trimmed.length > 100 ? trimmed.substring(0, 100) : trimmed,
      'platform': platform,
      if (osVersion != null && osVersion.isNotEmpty)
        'osVersion': osVersion.length > 32 ? osVersion.substring(0, 32) : osVersion,
      'appVersion': appVersion.length > 32 ? appVersion.substring(0, 32) : appVersion,
      'biometricClass': ?biometricClass,
    };
  }
}
