// Устройство для `AuthDeviceInfo` в сборке для браузера (веб-демо ADR-113; Web вне R1 — ADR-039): сервер знает только
// платформы `android | ios | windows` (`device_platform`, 07 §6.1), значения `web` нет. Используется источниками
// сведений об устройстве входа (auth) и регистрации (registration); на native не вызывается.
import 'package:device_info_plus/device_info_plus.dart';
import 'package:optomstroy/core/network/client_meta.dart';

/// Платформа `AuthDeviceInfo.platform` в браузере: на Windows — `windows` (как Windows-POS: блокировка по простою,
/// без биометрии), иначе (macOS, Linux, ChromeOS, iPad, телефоны) — `android`. [browserOs] — ОС браузера
/// (`ClientMeta.platform`, по `defaultTargetPlatform`).
ClientPlatform browserDevicePlatform(ClientPlatform? browserOs) =>
    browserOs == ClientPlatform.windows ? ClientPlatform.windows : ClientPlatform.android;

/// Имя устройства в браузере — название браузера (не ПДн, как модель устройства на Android).
String browserDeviceName(BrowserName browser) => switch (browser) {
  BrowserName.chrome => 'Chrome',
  BrowserName.edge => 'Edge',
  BrowserName.firefox => 'Firefox',
  BrowserName.safari => 'Safari',
  BrowserName.opera => 'Opera',
  BrowserName.samsungInternet => 'Samsung Internet',
  BrowserName.msie => 'Internet Explorer',
  BrowserName.unknown => 'Браузер',
};

/// Сведения о браузере: имя ([browserDeviceName]) и ОС (`navigator.platform`, например `Win32`).
Future<({String name, String? os})> readBrowserDevice(DeviceInfoPlugin plugin) async {
  final WebBrowserInfo info = await plugin.webBrowserInfo;
  return (name: browserDeviceName(info.browserName), os: info.platform);
}
