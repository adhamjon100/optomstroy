// `OtpVerifyRequest.device` (08 §4.1.2) от `PlatformDeviceInfoSource`: в браузере (веб-демо) — название браузера и
// `navigator.platform`, платформа `windows` только в браузере на Windows, иначе `android` (значения `web` сервер не
// знает); `androidInfo`/`windowsInfo` в браузере не вызываются (там они падают TypeError, и вход по OTP не проходил).
// Регистрация (`PluginDeviceDescriptorSource`, 08 `AuthDeviceInfo`) — по тем же правилам.
// `AuthDeviceInfo.biometricClass` — по возможности устройства (`BiometricUnlock.capability()`): `class3`, `class2`
// (Android только с уровнем W, 15 ADR-116, 09 BIO-030), `windows_hello`, `none`; на iOS поле не передаётся (RB-04).
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/network/browser_device.dart';
import 'package:optomstroy/core/network/client_meta.dart';
import 'package:optomstroy/features/auth/data/biometric_unlock_adapter.dart';
import 'package:optomstroy/features/auth/data/device_info_source.dart';
import 'package:optomstroy/features/auth/domain/ports/biometric_unlock.dart';
import 'package:optomstroy/features/registration/data/device_descriptor.dart';

import '../../../core/storage/in_memory_secure_storage.dart';

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

AndroidDeviceInfo _android() => AndroidDeviceInfo.setMockInitialValues(
  version: AndroidBuildVersion.setMockInitialValues(
    codename: 'REL',
    incremental: '1',
    previewSdkInt: 0,
    release: '14',
    sdkInt: 34,
  ),
  board: 'board',
  bootloader: 'bootloader',
  brand: 'samsung',
  device: 'a52q',
  display: 'display',
  fingerprint: 'fingerprint',
  hardware: 'qcom',
  host: 'host',
  id: 'id',
  manufacturer: 'Samsung',
  model: 'SM-A525F',
  product: 'a52qnsxx',
  name: 'Galaxy A52',
  supported32BitAbis: const <String>[],
  supported64BitAbis: const <String>['arm64-v8a'],
  supportedAbis: const <String>['arm64-v8a'],
  tags: 'release-keys',
  time: 0,
  type: 'user',
  isPhysicalDevice: true,
  freeDiskSize: 0,
  totalDiskSize: 0,
  systemFeatures: const <String>[],
  isLowRamDevice: false,
  physicalRamSize: 0,
  availableRamSize: 0,
);

ClientMeta _meta(ClientPlatform? platform) =>
    ClientMeta(appVersion: '0.1.0+1', platform: platform, deviceId: '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f55');

/// Порт SCR-08 с заданной возможностью устройства (`capability()`); остальное — как «биометрии нет».
final class _CapabilityUnlock implements BiometricUnlock {
  _CapabilityUnlock(this.value);

  final BiometricUnlockKind value;
  int capabilityCalls = 0;

  @override
  Future<BiometricUnlockKind> capability() async {
    capabilityCalls++;
    return value;
  }

  @override
  Future<BiometricUnlockKind> kind() async => BiometricUnlockKind.none;

  @override
  Future<BiometricSecretResult> readSecret() async => const BiometricSecretUnavailable();

  @override
  Future<bool> storeSecret(String secret) async => false;

  @override
  Future<void> clear() async {}

  @override
  Future<bool> confirmPresence() async => false;
}

/// Порт core/biometrics с заданной возможностью; системный диалог не нужен — вызовы с диалогом считаются.
final class _CapabilityAuthenticator implements BiometricAuthenticator {
  _CapabilityAuthenticator(this.value);

  final BiometricCapability value;
  int dialogCalls = 0;

  @override
  Future<BiometricCapability> capability() async => value;

  @override
  Future<BiometricResult<void>> store(String secret, BiometricPromptText prompt) async {
    dialogCalls++;
    return const BiometricResult.failure(BiometricError.notAvailable);
  }

  @override
  Future<BiometricResult<String>> read(BiometricPromptText prompt) async {
    dialogCalls++;
    return const BiometricResult.failure(BiometricError.notAvailable);
  }

  @override
  Future<bool> hasStoredSecret() async => false;

  @override
  Future<void> clear() async {}

  @override
  Future<BiometricResult<void>> confirmPresence(BiometricPromptText prompt) async {
    dialogCalls++;
    return const BiometricResult.failure(BiometricError.notAvailable);
  }
}

BiometricCapability _androidCapability({
  BiometricKind kind = BiometricKind.androidClass3,
  required BiometricAvailability strong,
  required BiometricAvailability weak,
  String? weakReason,
}) => BiometricCapability(
  kind: kind,
  availability: strong,
  cryptoBinding: strong != BiometricAvailability.unsupported,
  weakAvailability: weak,
  weakReason: weakReason,
);

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

  group('PlatformDeviceInfoSource: biometricClass по возможности устройства', () {
    PlatformDeviceInfoSource source(ClientPlatform platform, BiometricUnlock unlock) => PlatformDeviceInfoSource(
      meta: () => _meta(platform),
      biometrics: () => unlock,
      plugin: DeviceInfoPlugin.setMockInitialValues(androidDeviceInfo: _android()),
      isWeb: false,
    );

    test('Android: имя «производитель модель», osVersion — release; каждый вид порта → свой класс', () async {
      final Map<BiometricUnlockKind, String> expected = <BiometricUnlockKind, String>{
        BiometricUnlockKind.cryptoBound: 'class3',
        BiometricUnlockKind.weakBound: 'class2',
        BiometricUnlockKind.windowsHelloGate: 'windows_hello',
        // Ключ Windows Hello (W2, 15 ADR-116 п. 3): класс устройства тот же, что у гейта.
        BiometricUnlockKind.windowsHelloKey: 'windows_hello',
        BiometricUnlockKind.none: 'none',
      };
      expect(expected.keys, unorderedEquals(BiometricUnlockKind.values), reason: 'новый вид порта — новая строка');
      for (final MapEntry<BiometricUnlockKind, String> e in expected.entries) {
        final Map<String, dynamic> json = (await source(
          ClientPlatform.android,
          _CapabilityUnlock(e.key),
        ).read()).toJson();
        expect(json, <String, dynamic>{
          'name': 'Samsung SM-A525F',
          'platform': 'android',
          'osVersion': '14',
          'appVersion': '0.1.0+1',
          'biometricClass': e.value,
        }, reason: e.key.name);
      }
    });

    test('Android только с уровнем W (ADR-116): class2 — значение из перечня контракта AuthDeviceInfo', () async {
      final Map<String, dynamic> json = (await source(
        ClientPlatform.android,
        _CapabilityUnlock(BiometricUnlockKind.weakBound),
      ).read()).toJson();
      expect(json['biometricClass'], 'class2');
      expect(<String>['class3', 'class2', 'none', 'windows_hello'], contains(json['biometricClass']));
    });

    test('iOS: biometricClass не передаётся и порт не опрашивается (RB-04), даже при уровне W у порта', () async {
      final _CapabilityUnlock unlock = _CapabilityUnlock(BiometricUnlockKind.weakBound);
      final Map<String, dynamic> json = (await PlatformDeviceInfoSource(
        meta: () => _meta(ClientPlatform.ios),
        biometrics: () => unlock,
        plugin: DeviceInfoPlugin(),
        isWeb: false,
      ).read()).toJson();
      expect(json.containsKey('biometricClass'), isFalse);
      expect(json['platform'], 'ios');
      expect(json['name'], 'ios', reason: 'плагин недоступен в тесте — остаётся имя платформы');
      expect(unlock.capabilityCalls, 0);
    });
  });

  group('biometricClass: порт core/biometrics → адаптер SCR-08 → AuthDeviceInfo (ADR-116, BIO-030)', () {
    Future<String?> classOf(BiometricCapability capability, {ClientPlatform platform = ClientPlatform.android}) async {
      final _CapabilityAuthenticator auth = _CapabilityAuthenticator(capability);
      final BiometricUnlockAdapter adapter = BiometricUnlockAdapter(
        authenticator: auth,
        storage: InMemorySecureStorage(),
      );
      final Map<String, dynamic> json = (await PlatformDeviceInfoSource(
        meta: () => _meta(platform),
        biometrics: () => adapter,
        plugin: DeviceInfoPlugin.setMockInitialValues(
          androidDeviceInfo: _android(),
          windowsDeviceInfo: _windows('24H2'),
        ),
        isWeb: false,
      ).read()).toJson();
      expect(auth.dialogCalls, 0, reason: 'возможность — без системного диалога');
      return json['biometricClass'] as String?;
    }

    test('Class 3 и уровень W — class3: уровень S надёжнее (Q-354); только W — class2', () async {
      expect(
        await classOf(
          _androidCapability(strong: BiometricAvailability.available, weak: BiometricAvailability.available),
        ),
        'class3',
      );
      expect(
        await classOf(
          _androidCapability(
            kind: BiometricKind.androidClass2,
            strong: BiometricAvailability.unsupported,
            weak: BiometricAvailability.available,
          ),
        ),
        'class2',
      );
      expect(
        await classOf(
          _androidCapability(strong: BiometricAvailability.notEnrolled, weak: BiometricAvailability.available),
        ),
        'class2',
        reason: 'отпечаток Class 3 не настроен, лицо Class 2 есть — входить можно только уровнем W',
      );
    });

    test('уровень W недоступен (не настроен, эмулятор или debug в prod, API < 30) — none, как прежде', () async {
      for (final BiometricAvailability weak in <BiometricAvailability>[
        BiometricAvailability.notEnrolled,
        BiometricAvailability.lockedOut,
        BiometricAvailability.unsupported,
      ]) {
        expect(
          await classOf(
            _androidCapability(
              kind: BiometricKind.androidClass2,
              strong: BiometricAvailability.unsupported,
              weak: weak,
              weakReason: weak == BiometricAvailability.unsupported ? 'emulator' : null,
            ),
          ),
          'none',
          reason: weak.name,
        );
      }
      expect(await classOf(BiometricCapability.none), 'none');
    });

    test('Windows Hello и реализации без уровня W (поля по умолчанию) — прежние значения', () async {
      expect(
        await classOf(
          const BiometricCapability(
            kind: BiometricKind.windowsHello,
            availability: BiometricAvailability.available,
            cryptoBinding: false,
          ),
          platform: ClientPlatform.windows,
        ),
        'windows_hello',
      );
      expect(
        await classOf(
          const BiometricCapability(
            kind: BiometricKind.androidClass3,
            availability: BiometricAvailability.available,
            cryptoBinding: true,
          ),
        ),
        'class3',
      );
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
