// `OtpVerifyRequest.device` (08 §4.1.2) от `PlatformDeviceInfoSource`: в браузере (веб-демо) — название браузера и
// `navigator.platform`, платформа `windows` только в браузере на Windows, иначе `android` (значения `web` сервер не
// знает); `androidInfo`/`windowsInfo` в браузере не вызываются (там они падают TypeError, и вход по OTP не проходил).
// Регистрация (`PluginDeviceDescriptorSource`, 08 `AuthDeviceInfo`) — по тем же правилам.
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/network/browser_device.dart';
import 'package:optomstroy/core/network/client_meta.dart';
import 'package:optomstroy/features/auth/data/device_info_source.dart';
import 'package:optomstroy/features/auth/domain/ports/biometric_unlock.dart';
import 'package:optomstroy/features/registration/data/device_descriptor.dart';

const String _chromeWindows =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';
const String _edgeWindows = '$_chromeWindows Edg/130.0.0.0';
const String _safariIpad =
    'Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
    'Mobile/15E148 Safari/604.1';

WebBrowserInfo _browser({required String? userAgent, required String? platform}) => WebBrowserInfo(
  appCodeName: 'Mozilla',
  appName: 'Netscape',
  appVersion: '5.0',
  deviceMemory: null,
  language: 'ru-RU',
  languages: const <String>['ru-RU', 'ru'],
  platform: platform,
  product: 'Gecko',
  productSub: '20030107',
  userAgent: userAgent,
  vendor: 'Google Inc.',
  vendorSub: '',
  maxTouchPoints: 0,
  hardwareConcurrency: 8,
);

WindowsDeviceInfo _windows(String displayVersion) => WindowsDeviceInfo(
  computerName: 'KASSA-2',
  numberOfCores: 8,
  systemMemoryInMegabytes: 16384,
  userName: 'kassa',
  majorVersion: 10,
  minorVersion: 0,
  buildNumber: 26200,
  platformId: 2,
  csdVersion: '',
  servicePackMajor: 0,
  servicePackMinor: 0,
  suitMask: 0,
  productType: 1,
  reserved: 0,
  buildLab: '',
  buildLabEx: '',
  digitalProductId: Uint8List(0),
  displayVersion: displayVersion,
  editionId: 'Professional',
  installDate: DateTime.utc(2026),
  productId: '',
  productName: 'Windows 11 Pro',
  registeredOwner: '',
  releaseId: '',
  deviceId: 'test-device',
);

ClientMeta _meta(ClientPlatform? platform) =>
    ClientMeta(appVersion: '0.1.0+1', platform: platform, deviceId: '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f55');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('browserDevicePlatform / browserDeviceName', () {
    test('браузер на Windows → windows; macOS/Linux (null), iPad (ios), телефон (android) → android', () {
      expect(browserDevicePlatform(ClientPlatform.windows), ClientPlatform.windows);
      expect(browserDevicePlatform(null), ClientPlatform.android);
      expect(browserDevicePlatform(ClientPlatform.ios), ClientPlatform.android);
      expect(browserDevicePlatform(ClientPlatform.android), ClientPlatform.android);
    });

    test('имя устройства — название браузера; неизвестный — «Браузер»', () {
      final Map<BrowserName, String> names = <BrowserName, String>{
        for (final BrowserName b in BrowserName.values) b: browserDeviceName(b),
      };
      expect(names, <BrowserName, String>{
        BrowserName.firefox: 'Firefox',
        BrowserName.samsungInternet: 'Samsung Internet',
        BrowserName.opera: 'Opera',
        BrowserName.msie: 'Internet Explorer',
        BrowserName.edge: 'Edge',
        BrowserName.chrome: 'Chrome',
        BrowserName.safari: 'Safari',
        BrowserName.unknown: 'Браузер',
      });
    });
  });

  group('PlatformDeviceInfoSource в браузере', () {
    PlatformDeviceInfoSource source(ClientPlatform? os, WebBrowserInfo info) => PlatformDeviceInfoSource(
      meta: () => _meta(os),
      biometrics: () => const NoBiometricUnlock(),
      plugin: DeviceInfoPlugin.setMockInitialValues(webBrowserInfo: info),
      isWeb: true,
    );

    test('Chrome на Windows: name «Chrome», osVersion = navigator.platform, platform windows, биометрии нет', () async {
      final Map<String, dynamic> json = (await source(
        ClientPlatform.windows,
        _browser(userAgent: _chromeWindows, platform: 'Win32'),
      ).read()).toJson();
      expect(json, <String, dynamic>{
        'name': 'Chrome',
        'platform': 'windows',
        'osVersion': 'Win32',
        'appVersion': '0.1.0+1',
        'biometricClass': 'none',
      });
    });

    test(
      'Edge на Windows — «Edge»; Safari на iPad (ClientMeta ios) — платформа android и biometricClass есть',
      () async {
        final Map<String, dynamic> edge = (await source(
          ClientPlatform.windows,
          _browser(userAgent: _edgeWindows, platform: 'Win32'),
        ).read()).toJson();
        expect(edge['name'], 'Edge');

        final Map<String, dynamic> ipad = (await source(
          ClientPlatform.ios,
          _browser(userAgent: _safariIpad, platform: 'MacIntel'),
        ).read()).toJson();
        expect(ipad['name'], 'Safari');
        expect(ipad['platform'], 'android');
        expect(ipad['osVersion'], 'MacIntel');
        expect(ipad['biometricClass'], 'none', reason: 'не ios — поле передаётся (RB-04 только для ios)');
      },
    );

    test(
      'macOS/Linux (X-Platform нет): платформа android; без userAgent и platform — «Браузер» без osVersion',
      () async {
        final Map<String, dynamic> json = (await source(
          null,
          _browser(userAgent: null, platform: null),
        ).read()).toJson();
        expect(json['platform'], 'android');
        expect(json['name'], 'Браузер');
        expect(json.containsKey('osVersion'), isFalse);
      },
    );
  });

  group('PlatformDeviceInfoSource вне браузера (Windows-POS)', () {
    PlatformDeviceInfoSource source(String displayVersion) => PlatformDeviceInfoSource(
      meta: () => _meta(ClientPlatform.windows),
      biometrics: () => const NoBiometricUnlock(),
      plugin: DeviceInfoPlugin.setMockInitialValues(windowsDeviceInfo: _windows(displayVersion)),
      isWeb: false,
    );

    test('имя компьютера и displayVersion; без displayVersion — major.build', () async {
      final Map<String, dynamic> json = (await source('24H2').read()).toJson();
      expect(json['name'], 'KASSA-2');
      expect(json['platform'], 'windows');
      expect(json['osVersion'], '24H2');
      expect((await source('').read()).toJson()['osVersion'], '10.26200');
    });
  });

  group('PluginDeviceDescriptorSource (регистрация) в браузере', () {
    test('Chrome на Windows — name «Chrome», platform windows, osVersion Win32', () async {
      final PluginDeviceDescriptorSource source = PluginDeviceDescriptorSource(
        () => _meta(ClientPlatform.windows),
        DeviceInfoPlugin.setMockInitialValues(
          webBrowserInfo: _browser(userAgent: _chromeWindows, platform: 'Win32'),
        ),
        true,
      );
      expect(await source.describe(biometricClass: 'none'), <String, Object?>{
        'name': 'Chrome',
        'platform': 'windows',
        'osVersion': 'Win32',
        'appVersion': '0.1.0+1',
        'biometricClass': 'none',
      });
    });

    test('macOS (ClientMeta.platform null) — android, как у входа по OTP (раньше было windows)', () async {
      final PluginDeviceDescriptorSource source = PluginDeviceDescriptorSource(
        () => _meta(null),
        DeviceInfoPlugin.setMockInitialValues(
          webBrowserInfo: _browser(userAgent: _safariIpad, platform: 'MacIntel'),
        ),
        true,
      );
      final Map<String, Object?> json = await source.describe();
      expect(json['platform'], 'android');
      expect(json['name'], 'Safari');
    });

    test('вне браузера: платформа вне R1 — windows, плагин недоступен — имя «POS»', () async {
      final Map<String, Object?> json = await PluginDeviceDescriptorSource(
        () => _meta(null),
        DeviceInfoPlugin(),
        false,
      ).describe();
      expect(json['platform'], 'windows');
      expect(json['name'], 'POS');
    });
  });
}
