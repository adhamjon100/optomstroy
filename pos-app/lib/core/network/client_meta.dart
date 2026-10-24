// Метаданные клиента для заголовков `X-App-Version`, `X-Platform`, `X-Device-Id`,
// `Accept-Language` (08 §2.3; D-46, RM-C-015).
import 'package:flutter/foundation.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Платформа для `X-Platform`: `android | windows | ios` (иное значение сервер отклоняет).
enum ClientPlatform {
  android,
  windows,
  ios;

  /// Платформа текущей сборки; `null` — платформа вне R1 (заголовок не отправляется).
  static ClientPlatform? of(TargetPlatform platform) => switch (platform) {
    TargetPlatform.android => ClientPlatform.android,
    TargetPlatform.windows => ClientPlatform.windows,
    TargetPlatform.iOS => ClientPlatform.ios,
    _ => null,
  };
}

final class ClientMeta {
  const ClientMeta({
    required this.appVersion,
    required this.platform,
    required this.deviceId,
    this.languageCode = 'ru',
  });

  /// Собрать при запуске: версия из `package_info_plus` (`version+buildNumber`),
  /// `deviceId` — из secure storage (создаётся при первом запуске).
  static Future<ClientMeta> load(SecureStorage storage, {String languageCode = 'ru'}) async {
    final info = await PackageInfo.fromPlatform();
    final build = info.buildNumber.isEmpty ? '' : '+${info.buildNumber}';
    return ClientMeta(
      appVersion: '${info.version}$build',
      platform: ClientPlatform.of(defaultTargetPlatform),
      deviceId: await storage.readOrCreateDeviceId(),
      languageCode: languageCode,
    );
  }

  /// `1.4.2+87`.
  final String appVersion;
  final ClientPlatform? platform;
  final String deviceId;

  /// `Accept-Language`: `ru` (по умолчанию), `ky`, `en` (D-38).
  final String languageCode;

  ClientMeta copyWith({String? languageCode}) => ClientMeta(
    appVersion: appVersion,
    platform: platform,
    deviceId: deviceId,
    languageCode: languageCode ?? this.languageCode,
  );
}
