// `device` для `POST /registration/complete` (08 `AuthDeviceInfo`: name, platform, osVersion, appVersion,
// biometricClass; `model` не передаётся — additionalProperties:false, 02 AC-UI-04-019).
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:optomstroy/core/network/client_meta.dart';

/// Источник сведений об устройстве (подменяется в тестах).
abstract interface class DeviceDescriptorSource {
  Future<Map<String, Object?>> describe({String? biometricClass});
}

final class PluginDeviceDescriptorSource implements DeviceDescriptorSource {
  PluginDeviceDescriptorSource(this._meta, [DeviceInfoPlugin? plugin]) : _plugin = plugin ?? DeviceInfoPlugin();

  final ClientMeta Function() _meta;
  final DeviceInfoPlugin _plugin;

  @override
  Future<Map<String, Object?>> describe({String? biometricClass}) async {
    final meta = _meta();
    var name = 'POS';
    String? os;
    try {
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          final a = await _plugin.androidInfo;
          name = '${a.manufacturer} ${a.model}';
          os = a.version.release;
        case TargetPlatform.iOS:
          final i = await _plugin.iosInfo;
          name = i.model;
          os = i.systemVersion;
        case TargetPlatform.windows:
          final w = await _plugin.windowsInfo;
          name = w.computerName;
          os = '${w.majorVersion}.${w.minorVersion}.${w.buildNumber}';
        default:
          break;
      }
    } on Object {
      // Сведения необязательны: имя по умолчанию, osVersion не передаётся.
    }
    return deviceInfoJson(
      name: name,
      platform: meta.platform?.name ?? 'windows',
      appVersion: meta.appVersion,
      osVersion: os,
      biometricClass: biometricClass,
    );
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
