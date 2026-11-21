// 12 T-DEMO-016 — `WebPasskeyAuthenticator` веб-демо (15 ADR-116 п. 1, п. 4; 09 §9.2 «Веб-демо», BIO-035, BIO-041,
// AC-AUTH-094, AC-AUTH-100; 06 §6.10). VM, фейковый шлюз `__posPasskey` (fake_demo_passkey.dart — протокол 1
// demo-passkey.js: привязка, гейт и ключ входа браузера на Windows, пакет LF-3-06). Шаги:
// (1) режим по `browserDevicePlatform`: не Windows — привязка; Windows — ключ (PRF и `windowsHelloKeyAllowed`) или гейт;
// (2) доступность, виды `android_class3` и `windows_hello`, разбор ошибок (в т. ч. ключа входа);
// (3) адаптеры SCR-08, SCR-42 и SCR-04 поверх порта; регистрация «только биометрия» со сбоем PRF → PIN (AC-AUTH-089);
//     браузер на Windows с PRF — ключ входа (`helloKey.source = webauthn_prf`, подпись challenge — один диалог), без PRF
//     — гейт и снекбар `settings_hello_key_no_prf`;
// (5) продукт web — `NoBiometricAuthenticator`, `lib/main.dart` демо-код не импортирует.
// Шаг (4) — корень DI (четыре переопределения) — test/app/demo/demo_root_wiring_test.dart. Синтетические данные.
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/app/demo/demo_passkey.dart';
import 'package:optomstroy/app/demo/demo_passkey_gateway.dart';
import 'package:optomstroy/app/demo/demo_passkey_stub.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/biometrics/biometric_providers.dart';
import 'package:optomstroy/core/biometrics/hello_gate_users.dart';
import 'package:optomstroy/core/biometrics/hello_key_users.dart';
import 'package:optomstroy/core/biometrics/windows_hello_key.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/network/browser_device.dart';
import 'package:optomstroy/core/network/client_meta.dart';
import 'package:optomstroy/core/session/profile_cache.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/design_system/components/app_switch.dart';
import 'package:optomstroy/design_system/components/pin_field.dart';
import 'package:optomstroy/features/auth/data/biometric_unlock_adapter.dart';
import 'package:optomstroy/features/auth/domain/ports/biometric_unlock.dart';
import 'package:optomstroy/features/registration/data/repositories/device_biometrics_impl.dart';
import 'package:optomstroy/features/registration/domain/entities/registration_entities.dart' as reg;
import 'package:optomstroy/features/registration/presentation/controllers/registration_flow_controller.dart';
import 'package:optomstroy/features/registration/presentation/screens/registration_security_screen.dart';
import 'package:optomstroy/features/settings/data/datasources/settings_api.dart';
import 'package:optomstroy/features/settings/data/repositories/login_protection_repository_impl.dart';
import 'package:optomstroy/features/settings/domain/entities/settings_entities.dart';
import 'package:optomstroy/features/settings/presentation/screens/settings_screen.dart';
import 'package:optomstroy/features/settings/presentation/widgets/security_section.dart';

import '../../core/network/fake_adapter.dart';
import '../../core/storage/in_memory_secure_storage.dart';
import '../../features/registration/support/registration_fakes.dart';
import '../../features/settings/support/settings_fakes.dart';
import 'fake_demo_passkey.dart';

const String _userA = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4fa1';
const String _userB = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4fb2';
const BiometricPromptText _prompt = BiometricPromptText(title: 'Войти по биометрии', cancel: 'Отмена');

/// Синтетический `biometric_refresh` (не токен).
const String _refreshOne = 'demo-bio-refresh-1'; // check-secrets: allow — тестовая метка, не секрет
const String _refreshTwo = 'demo-bio-refresh-2'; // check-secrets: allow — тестовая метка, не секрет

/// Порт веб-демо, как его собирает корень (`demoBiometricAuthenticator`): владелец — `userId` кэша профиля.
WebPasskeyAuthenticator _web(
  FakeDemoPasskeyGateway gateway,
  DemoPasskeyMode mode,
  SecureStorage storage, {
  Duration quickTimeout = const Duration(seconds: 3),
}) => WebPasskeyAuthenticator(
  gateway: gateway,
  mode: mode,
  owner: () async => (await ProfileCacheStore(storage).read())?.userId,
  quickTimeout: quickTimeout,
);

/// Вход пользователя [userId] (SessionController пишет `userId` в кэш профиля при каждом входе и разблокировке).
Future<void> _signIn(SecureStorage storage, String userId) =>
    ProfileCacheStore(storage).rememberUser(userId, unlock: false);

Dio _dio(FakeAdapter adapter) => Dio(BaseOptions(baseUrl: 'https://api.test/api/v1'))..httpClientAdapter = adapter;

Map<String, Object?> _me({String kind = 'customer', bool keyAllowed = false}) => <String, Object?>{
  'id': _userA,
  'kind': kind,
  'status': 'active',
  'roles': <String>[if (kind == 'customer') 'customer' else 'seller'],
  'permissions': <String>[],
  'permissionsVersion': 1,
  'profile': <String, Object?>{'birthYear': 1990},
  'security': <String, Object?>{
    'pinSet': true,
    'biometricsEnabled': false,
    'biometricWeakAllowed': false,
    // В демо `AUTH_WINDOWS_HELLO_KEY=all` (demo/web/backend/demo-config.mjs): сервер разрешает ключ браузеру на Windows.
    'windowsHelloKeyAllowed': keyAllowed,
  },
  'settings': <String, Object?>{'locale': 'ru'},
};

/// Сервер SCR-42: `GET /me`, `GET /me/consents`, `POST /me/biometrics` (выдаёт `biometric_refresh` при включении; с
/// `helloKey` — ключ входа, ответ [helloKeyReply], по умолчанию `{enabled: true}`).
FakeAdapter _settingsServer(
  List<Object?> biometricsBodies, {
  String kind = 'customer',
  bool keyAllowed = false,
  Map<String, Object?> helloKeyReply = const <String, Object?>{'enabled': true},
}) => FakeAdapter((RequestOptions o) async {
  if (o.path.endsWith('/me/consents')) {
    return json(200, <String, Object?>{
      'items': <Object?>[],
      'required': <Object?>[
        <String, Object?>{'kind': 'biometrics_device', 'currentVersion': '2026-11-08'},
      ],
    });
  }
  if (o.path.endsWith('/me/biometrics')) {
    biometricsBodies.add(o.data);
    final Map<String, Object?> body = o.data! as Map<String, Object?>;
    if (body['enabled'] == true && body['helloKey'] != null) return json(200, helloKeyReply);
    return body['enabled'] == true
        ? json(200, <String, Object?>{'enabled': true, 'biometricRefreshToken': _refreshOne})
        : json(200, <String, Object?>{'enabled': false});
  }
  return json(200, _me(kind: kind, keyAllowed: keyAllowed));
});

LoginProtectionRepositoryImpl _settingsRepo(FakeAdapter adapter, BiometricAuthenticator bio, SecureStorage storage) =>
    LoginProtectionRepositoryImpl(
      api: SettingsApi(_dio(adapter), newKey: () => 'idem-1'),
      biometrics: bio,
      storage: storage,
      obtainStepUp: (_) async => 'step-up-token',
      clock: FixedClock(DateTime.utc(2026, 11, 18, 9)),
      fallbackLabel: BiometricPlatformLabel.android,
      currentUserId: () async => _userA,
    );

void main() {
  late InMemorySecureStorage storage;

  setUp(() async {
    storage = InMemorySecureStorage();
    await _signIn(storage, _userA);
  });

  group('T-DEMO-016 (1) режим по browserDevicePlatform', () {
    test('браузер на Windows — гейт; иначе (Android, iOS, ОС вне R1 — null) — привязка; правило платформы сервера', () {
      expect(demoPasskeyModeFor(ClientPlatform.windows), DemoPasskeyMode.gate);
      for (final ClientPlatform? os in <ClientPlatform?>[ClientPlatform.android, ClientPlatform.ios, null]) {
        expect(demoPasskeyModeFor(os), DemoPasskeyMode.bound, reason: '$os');
      }
      // Гейт ровно там, где сервер видит платформу `windows` (`AuthDeviceInfo.platform`, ADR-116 вариант З отклонён).
      for (final ClientPlatform? os in <ClientPlatform?>[...ClientPlatform.values, null]) {
        expect(
          demoPasskeyModeFor(os) == DemoPasskeyMode.gate,
          browserDevicePlatform(os) == ClientPlatform.windows,
          reason: '$os',
        );
      }
      expect(DemoPasskeyMode.values.map((DemoPasskeyMode m) => m.wire), <String>['bound', 'gate']);
    });

    test('режим уходит странице в capability и clear; страница платформу сама не определяет', () async {
      for (final DemoPasskeyMode mode in DemoPasskeyMode.values) {
        final FakeDemoPasskeyGateway page = FakeDemoPasskeyGateway();
        final WebPasskeyAuthenticator web = _web(page, mode, storage);
        await web.capability();
        await web.clear();
        expect(page.calls, hasLength(2));
        for (final FakePasskeyCall call in page.calls) {
          expect(call.args, <String, Object?>{'mode': mode.wire}, reason: call.method);
        }
        expect(page.methods, <String>[DemoPasskeyMethod.capability, DemoPasskeyMethod.clear]);
        expect(web.mode, mode);
        expect('$web', 'WebPasskeyAuthenticator(${mode.name})');
      }
    });

    test(
      'Windows — ключ: SCR-42 предлагает ключ входа при windowsHelloKeyAllowed и PRF страницы, иначе гейт',
      () async {
        Future<BiometricSupport> support(
          FakeDemoPasskeyGateway page, {
          required bool keyAllowed,
          DemoPasskeyMode mode = DemoPasskeyMode.gate,
        }) async {
          final LoginProtectionRepositoryImpl repo = _settingsRepo(
            _settingsServer(<Object?>[], kind: 'staff', keyAllowed: keyAllowed),
            _web(page, mode, storage),
            storage,
          );
          return (await repo.load()).valueOrNull!.support;
        }

        expect(await support(FakeDemoPasskeyGateway(), keyAllowed: true), BiometricSupport.windowsHelloKey);
        expect(
          await support(FakeDemoPasskeyGateway(clientPrf: 'unknown'), keyAllowed: true),
          BiometricSupport.windowsHelloKey,
          reason: 'PRF клиента неизвестен — правду скажет создание passkey',
        );
        expect(await support(FakeDemoPasskeyGateway(), keyAllowed: false), BiometricSupport.windowsHelloGate);
        expect(
          await support(FakeDemoPasskeyGateway(clientPrf: 'no'), keyAllowed: true),
          BiometricSupport.windowsHelloGate,
        );
        expect(
          await support(FakeDemoPasskeyGateway()..noPrf = true, keyAllowed: true),
          BiometricSupport.windowsHelloGate,
          reason: 'признак страницы «PRF нет» — до «Сбросить демо»',
        );
        expect(
          await support(FakeDemoPasskeyGateway(platformAuthenticator: false), keyAllowed: true),
          BiometricSupport.unavailable,
        );
        expect(
          await support(FakeDemoPasskeyGateway(), keyAllowed: true, mode: DemoPasskeyMode.bound),
          BiometricSupport.cryptoLogin,
          reason: 'не Windows — привязка, ключа входа нет',
        );
      },
    );
  });

  group('T-DEMO-016 (2) доступность, виды, ошибки', () {
    test('привязка: android_class3 с криптопривязкой — как Android Class 3; уровня W и уровня секрета нет', () async {
      final BiometricCapability c = await _web(FakeDemoPasskeyGateway(), DemoPasskeyMode.bound, storage).capability();
      expect(c.kind, BiometricKind.androidClass3);
      expect(c.kind.apiClass, 'class3');
      expect(c.availability, BiometricAvailability.available);
      expect(c.cryptoBinding, isTrue);
      expect(c.supportsCryptoLogin, isTrue);
      expect(c.supportsWeakLogin, isFalse);
      expect(c.storedTier, isNull);
      // PRF клиента неизвестен (нет getClientCapabilities) — вариант не скрывается: правду скажет create().
      final FakeDemoPasskeyGateway unknown = FakeDemoPasskeyGateway(clientPrf: 'unknown');
      expect((await _web(unknown, DemoPasskeyMode.bound, storage).capability()).supportsCryptoLogin, isTrue);
    });

    test('гейт: windows_hello без криптопривязки (что бы ни ответила страница); PRF гейту не нужен', () async {
      for (final String prf in <String>['yes', 'no', 'unknown']) {
        final FakeDemoPasskeyGateway page = FakeDemoPasskeyGateway(clientPrf: prf);
        page.respond = (String method, Map<String, Object?> args) {
          if (method != DemoPasskeyMethod.capability) return null;
          return <String, Object?>{
            'kind': 'windows_hello',
            'availability': 'available',
            'cryptoBinding': true, // гейт ничего не открывает — приложение это не принимает
            'reason': 'no_crypto_binding_on_platform',
            'keysSupported': prf != 'no',
            'prf': prf,
          };
        };
        final BiometricCapability c = await _web(page, DemoPasskeyMode.gate, storage).capability();
        expect(c.kind, BiometricKind.windowsHello, reason: prf);
        expect(c.kind.apiClass, 'windows_hello');
        expect(c.isAvailable, isTrue);
        expect(c.cryptoBinding, isFalse);
        expect(c.supportsCryptoLogin, isFalse);
        expect(c.reason, 'no_crypto_binding_on_platform');
      }
    });

    test('вариант скрыт: нет платформенного аутентификатора; привязка без PRF (клиент или маркер страницы)', () async {
      Future<BiometricCapability> cap(FakeDemoPasskeyGateway page, DemoPasskeyMode mode) =>
          _web(page, mode, storage).capability();

      final FakeDemoPasskeyGateway noPlatform = FakeDemoPasskeyGateway(platformAuthenticator: false);
      for (final DemoPasskeyMode mode in DemoPasskeyMode.values) {
        final BiometricCapability c = await cap(noPlatform, mode);
        expect(c.kind, BiometricKind.none, reason: mode.name);
        expect(c.availability, BiometricAvailability.unsupported);
        expect(c.reason, 'no_platform_authenticator');
      }
      final BiometricCapability noPrfClient = await cap(FakeDemoPasskeyGateway(clientPrf: 'no'), DemoPasskeyMode.bound);
      expect(noPrfClient.kind, BiometricKind.none);
      expect(noPrfClient.reason, 'no_prf');
      final FakeDemoPasskeyGateway marked = FakeDemoPasskeyGateway()..noPrf = true;
      expect((await cap(marked, DemoPasskeyMode.bound)).reason, 'no_prf');
      expect((await cap(marked, DemoPasskeyMode.gate)).kind, BiometricKind.windowsHello, reason: 'гейту PRF не нужен');
    });

    test('шлюза нет, другой протокол, заглушка VM — биометрии нет, страница не вызывается', () async {
      final List<(FakeDemoPasskeyGateway, String)> cases = <(FakeDemoPasskeyGateway, String)>[
        (FakeDemoPasskeyGateway(isAvailable: false), 'no_gateway'),
        (FakeDemoPasskeyGateway(protocol: 2), 'protocol'),
        (FakeDemoPasskeyGateway(protocol: null), 'protocol'),
      ];
      for (final (FakeDemoPasskeyGateway page, String reason) in cases) {
        for (final DemoPasskeyMode mode in DemoPasskeyMode.values) {
          final WebPasskeyAuthenticator web = _web(page, mode, storage);
          final BiometricCapability c = await web.capability();
          expect(c.kind, BiometricKind.none);
          expect(c.reason, reason);
          expect((await web.store(_refreshOne, _prompt)).error, BiometricError.notAvailable);
          expect((await web.read(_prompt)).error, BiometricError.notAvailable);
          expect((await web.replace(_refreshOne, _prompt)).error, BiometricError.notAvailable);
          expect((await web.confirmPresence(_prompt)).error, BiometricError.notAvailable);
          expect(await web.hasStoredSecret(), isFalse);
          await web.clear();
        }
        expect(page.calls, isEmpty, reason: reason);
      }
      // VM-заглушка (условный импорт без dart:js_interop): страницы нет.
      const DemoPasskeyGateway stub = UnavailableDemoPasskeyGateway();
      expect(createDemoPasskeyGateway(), isA<UnavailableDemoPasskeyGateway>());
      expect(stub.isAvailable, isFalse);
      expect(stub.protocol, isNull);
      expect(await stub.invoke(DemoPasskeyMethod.capability), demoPasskeyNotAvailable);
      final WebPasskeyAuthenticator onVm = WebPasskeyAuthenticator(
        gateway: stub,
        mode: DemoPasskeyMode.bound,
        owner: () async => _userA,
      );
      expect((await onVm.capability()).kind, BiometricKind.none);
    });

    test('метка протокола для check-site (T-DEMO-020): номер протокола в строке, которая попадает в main.dart.js', () {
      expect(demoPasskeyProtocol, 1);
      expect(demoPasskeyProtocolTag, '__posPasskey.protocol=1');
      expect(demoPasskeyProtocolMismatch(2), contains(demoPasskeyProtocolTag));
      expect(DemoPasskeyMethod.all, hasLength(11));
    });

    test('ответ не того режима, не объект или без вида — вида нет', () async {
      final List<Map<String, Object?>> answers = <Map<String, Object?>>[
        <String, Object?>{'kind': 'windows_hello', 'availability': 'available', 'cryptoBinding': false},
        demoPasskeyFailed,
        <String, Object?>{},
      ];
      for (final Map<String, Object?> answer in answers) {
        final FakeDemoPasskeyGateway page = FakeDemoPasskeyGateway()..respond = (_, _) => answer;
        expect((await _web(page, DemoPasskeyMode.bound, storage).capability()).kind, BiometricKind.none);
      }
      final FakeDemoPasskeyGateway page = FakeDemoPasskeyGateway()
        ..respond = (_, _) => <String, Object?>{'kind': 'android_class3', 'availability': 'available'};
      expect((await _web(page, DemoPasskeyMode.gate, storage).capability()).kind, BiometricKind.none);
    });

    test('ошибки страницы → BiometricError (коды канала криптопривязки); неизвестный код — failed', () async {
      const Map<String, BiometricError> codes = <String, BiometricError>{
        'cancelled': BiometricError.cancelled,
        'invalidated': BiometricError.invalidated,
        'not_available': BiometricError.notAvailable,
        'no_credential': BiometricError.noCredential,
        'failed': BiometricError.failed,
        'lockout': BiometricError.lockout,
        'something_else': BiometricError.failed,
      };
      for (final MapEntry<String, BiometricError> e in codes.entries) {
        final FakeDemoPasskeyGateway page = FakeDemoPasskeyGateway()
          ..respond = (String method, _) =>
              method == DemoPasskeyMethod.capability ? null : <String, Object?>{'ok': false, 'error': e.key};
        final WebPasskeyAuthenticator bound = _web(page, DemoPasskeyMode.bound, storage);
        final WebPasskeyAuthenticator gate = _web(page, DemoPasskeyMode.gate, storage);
        expect((await bound.store(_refreshOne, _prompt)).error, e.value, reason: 'store ${e.key}');
        expect((await bound.read(_prompt)).error, e.value, reason: 'read ${e.key}');
        expect((await bound.replace(_refreshOne, _prompt)).error, e.value, reason: 'replace ${e.key}');
        expect((await gate.confirmPresence(_prompt)).error, e.value, reason: 'confirmPresence ${e.key}');
      }
      // `ok: true` без значения у read — не секрет.
      final FakeDemoPasskeyGateway empty = FakeDemoPasskeyGateway()..respond = (_, _) => <String, Object?>{'ok': true};
      expect((await _web(empty, DemoPasskeyMode.bound, storage).read(_prompt)).error, BiometricError.failed);
    });

    test('пользователь неизвестен (кэш профиля без userId) — привязка без вызова страницы', () async {
      final InMemorySecureStorage anonymous = InMemorySecureStorage();
      final FakeDemoPasskeyGateway page = FakeDemoPasskeyGateway()..bound = (owner: _userA, secret: _refreshOne);
      final WebPasskeyAuthenticator web = _web(page, DemoPasskeyMode.bound, anonymous);
      expect((await web.store(_refreshTwo, _prompt)).error, BiometricError.failed);
      expect((await web.read(_prompt)).error, BiometricError.noCredential);
      expect((await web.replace(_refreshTwo, _prompt)).error, BiometricError.noCredential);
      expect(await web.hasStoredSecret(), isFalse);
      expect(page.calls, isEmpty);
      expect(page.bound?.secret, _refreshOne);
    });

    test('гейт не хранит секретов; привязка не подтверждает присутствие — без вызова страницы', () async {
      final FakeDemoPasskeyGateway page = FakeDemoPasskeyGateway()..bound = (owner: _userA, secret: _refreshOne);
      final WebPasskeyAuthenticator gate = _web(page, DemoPasskeyMode.gate, storage);
      expect((await gate.store(_refreshTwo, _prompt)).error, BiometricError.notAvailable);
      expect((await gate.read(_prompt)).error, BiometricError.notAvailable);
      expect((await gate.replace(_refreshTwo, _prompt)).error, BiometricError.notAvailable);
      expect(await gate.hasStoredSecret(), isFalse);
      final WebPasskeyAuthenticator bound = _web(page, DemoPasskeyMode.bound, storage);
      expect((await bound.confirmPresence(_prompt)).error, BiometricError.notAvailable);
      expect(page.calls, isEmpty);
      expect(page.dialogs, isEmpty);
    });

    test('зависшая страница: capability, has и clear ждут не дольше quickTimeout', () async {
      final FakeDemoPasskeyGateway page = FakeDemoPasskeyGateway()..hold = Completer<void>();
      final WebPasskeyAuthenticator web = _web(
        page,
        DemoPasskeyMode.bound,
        storage,
        quickTimeout: const Duration(milliseconds: 20),
      );
      final Stopwatch watch = Stopwatch()..start();
      expect((await web.capability()).kind, BiometricKind.none);
      expect(await web.hasStoredSecret(), isFalse);
      await web.clear();
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      page.hold!.complete();
    });

    test(
      'секрет — только в значении результата: не в toString результата и порта, не в аргументах чужих методов',
      () async {
        final FakeDemoPasskeyGateway page = FakeDemoPasskeyGateway();
        final WebPasskeyAuthenticator web = _web(page, DemoPasskeyMode.bound, storage);
        expect((await web.store(_refreshOne, _prompt)).isSuccess, isTrue);
        final BiometricResult<String> read = await web.read(_prompt);
        expect(read.value, _refreshOne);
        expect('$read', isNot(contains(_refreshOne)));
        expect('$web', isNot(contains(_refreshOne)));
        for (final FakePasskeyCall call in page.calls) {
          final bool carries = call.method == DemoPasskeyMethod.store || call.method == DemoPasskeyMethod.replace;
          expect(call.args.values.contains(_refreshOne), carries, reason: call.method);
          // Тексты диалога странице не передаются: у WebAuthn нет своего заголовка.
          expect(call.args.keys, isNot(contains('title')));
        }
      },
    );

    test(
      'ключ входа: helloStatus — capability({mode: gate}) без диалога; привязка и шлюза нет — unknown без вызова',
      () async {
        Future<WindowsHelloStatus> status(FakeDemoPasskeyGateway page, [DemoPasskeyMode mode = DemoPasskeyMode.gate]) =>
            _web(page, mode, storage).helloStatus();

        final FakeDemoPasskeyGateway page = FakeDemoPasskeyGateway();
        expect(
          await status(page),
          const WindowsHelloStatus(availability: WindowsHelloAvailability.available, keysSupported: true),
        );
        expect(page.calls.single.args, <String, Object?>{'mode': 'gate'});
        expect(page.dialogs, isEmpty);
        expect((await status(FakeDemoPasskeyGateway(clientPrf: 'no'))).supportsKey, isFalse);
        expect((await status(FakeDemoPasskeyGateway(clientPrf: 'unknown'))).supportsKey, isTrue);
        expect((await status(FakeDemoPasskeyGateway()..noPrf = true)).supportsKey, isFalse);
        expect(await status(FakeDemoPasskeyGateway(platformAuthenticator: false)), WindowsHelloStatus.unknown);
        final FakeDemoPasskeyGateway hung = FakeDemoPasskeyGateway()..hold = Completer<void>();
        expect(
          await _web(hung, DemoPasskeyMode.gate, storage, quickTimeout: const Duration(milliseconds: 20)).helloStatus(),
          WindowsHelloStatus.unknown,
        );
        hung.hold!.complete();

        for (final FakeDemoPasskeyGateway quiet in <FakeDemoPasskeyGateway>[
          FakeDemoPasskeyGateway(isAvailable: false),
          FakeDemoPasskeyGateway(protocol: 2),
        ]) {
          expect(await status(quiet), WindowsHelloStatus.unknown);
          expect(quiet.calls, isEmpty);
        }
        final FakeDemoPasskeyGateway bound = FakeDemoPasskeyGateway();
        final WebPasskeyAuthenticator web = _web(bound, DemoPasskeyMode.bound, storage);
        expect(await web.helloStatus(), WindowsHelloStatus.unknown);
        expect((await web.createHelloKey(_userA)).error, BiometricError.notAvailable);
        expect((await web.signHelloChallenge(_userA, '${helloChallengePrefix}abc')).error, BiometricError.notAvailable);
        expect(await web.deleteHelloKey(_userA), isFalse);
        expect(bound.calls, isEmpty, reason: 'в режиме привязки ключа входа нет');
        expect(web.helloKeySource, HelloKeySource.webauthnPrf);
        expect(helloKeySourceOf(web), HelloKeySource.webauthnPrf);
      },
    );

    test(
      'ключ входа: create/sign/delete — owner = userId, ответы страницы → результат; ошибки → BiometricError',
      () async {
        final FakeDemoPasskeyGateway page = FakeDemoPasskeyGateway();
        final WebPasskeyAuthenticator web = _web(page, DemoPasskeyMode.gate, storage);
        final BiometricResult<String> created = await web.createHelloKey(' $_userB ');
        expect(created.value, FakeDemoPasskeyGateway.publicKeyOf(1));
        expect(page.calls.single.args, <String, Object?>{'owner': _userB}, reason: 'userId фичи, не кэш профиля');
        expect(page.dialogs, <String>['create']);
        const String challenge = '${helloChallengePrefix}c2lnbi1tZQ';
        final BiometricResult<String> signed = await web.signHelloChallenge(_userB, challenge);
        expect(signed.value, FakeDemoPasskeyGateway.signatureOf(1, challenge));
        expect(page.dialogs, <String>['create', 'get']);
        expect(page.calls.last.args, <String, Object?>{'owner': _userB, 'challenge': challenge});
        expect('$signed', isNot(contains(signed.value!)));
        expect(await web.deleteHelloKey(_userB), isTrue);
        expect(await web.deleteHelloKey(_userB), isFalse);
        expect((await web.signHelloChallenge(_userB, challenge)).error, BiometricError.noCredential);
        expect(page.dialogs, hasLength(2), reason: 'ключа нет — без диалога');

        // Без вызова страницы: пользователь неизвестен, строка не challenge входа.
        final int before = page.calls.length;
        expect((await web.createHelloKey('  ')).error, BiometricError.failed);
        expect((await web.signHelloChallenge('', challenge)).error, BiometricError.failed);
        expect((await web.signHelloChallenge(_userB, 'not-an-unlock-challenge')).error, BiometricError.failed);
        expect(await web.deleteHelloKey(''), isFalse);
        expect(page.calls, hasLength(before));

        // Ответ без RS256 или без значения — не ключ.
        for (final Map<String, Object?> answer in <Map<String, Object?>>[
          <String, Object?>{'ok': true, 'value': 'spki-test-9', 'algorithm': 'ES256'},
          <String, Object?>{'ok': true, 'algorithm': 'RS256'},
        ]) {
          final FakeDemoPasskeyGateway odd = FakeDemoPasskeyGateway()..respond = (_, _) => answer;
          expect((await _web(odd, DemoPasskeyMode.gate, storage).createHelloKey(_userA)).error, BiometricError.failed);
        }
        const Map<String, BiometricError> codes = <String, BiometricError>{
          'cancelled': BiometricError.cancelled,
          'no_credential': BiometricError.noCredential,
          'not_available': BiometricError.notAvailable,
          'failed': BiometricError.failed,
          'something_else': BiometricError.failed,
        };
        for (final MapEntry<String, BiometricError> e in codes.entries) {
          final FakeDemoPasskeyGateway failing = FakeDemoPasskeyGateway()
            ..respond = (_, _) => <String, Object?>{'ok': false, 'error': e.key};
          final WebPasskeyAuthenticator w = _web(failing, DemoPasskeyMode.gate, storage);
          final BrowserHelloKeyCreation c = await w.createBrowserHelloKey(_userA);
          expect(c.key.error, e.value, reason: 'createKey ${e.key}');
          expect(c.noPrf, isFalse);
          expect((await w.signHelloChallenge(_userA, challenge)).error, e.value, reason: 'sign ${e.key}');
        }
      },
    );

    test('ключ входа без PRF: noPrf и gate страницы; повторно — без диалога; гейт тем же passkey', () async {
      final FakeDemoPasskeyGateway page = FakeDemoPasskeyGateway(prfAtCreate: false);
      final WebPasskeyAuthenticator web = _web(page, DemoPasskeyMode.gate, storage);
      BrowserHelloKeyCreation c = await web.createBrowserHelloKey(_userA);
      expect(c.noPrf, isTrue);
      expect(c.gate, isTrue, reason: 'passkey создан и остался ключом гейта');
      expect(c.key.error, BiometricError.notAvailable);
      expect(page.dialogs, <String>['create']);
      expect(page.helloKeys, isEmpty);
      expect((await web.helloStatus()).supportsKey, isFalse);
      c = await web.createBrowserHelloKey(_userA);
      expect((c.noPrf, c.gate), (true, true));
      expect(page.dialogs, hasLength(1), reason: 'признак «PRF нет» — без диалога');
      expect((await web.confirmPresence(_prompt)).isSuccess, isTrue);
      expect(page.dialogs, <String>['create', 'get'], reason: 'гейт — тот же passkey');
      // Passkey есть, но get() не дал выхода PRF.
      final FakeDemoPasskeyGateway noOutput = FakeDemoPasskeyGateway(prfAtGet: false)..gate = true;
      c = await _web(noOutput, DemoPasskeyMode.gate, storage).createBrowserHelloKey(_userA);
      expect((c.noPrf, c.gate), (true, true));
      expect(noOutput.dialogs, <String>['get']);
    });
  });

  group('T-DEMO-016 (3) адаптеры поверх порта', () {
    test(
      'SCR-08, привязка: включение → кнопка; один диалог на вход; новый токен — тем же ключом без диалога',
      () async {
        final FakeDemoPasskeyGateway page = FakeDemoPasskeyGateway();
        final WebPasskeyAuthenticator web = _web(page, DemoPasskeyMode.bound, storage);
        final BiometricUnlockAdapter adapter = BiometricUnlockAdapter(authenticator: web, storage: storage);
        expect(await adapter.kind(), BiometricUnlockKind.none, reason: 'до включения записи нет');

        expect((await web.store(_refreshOne, _prompt)).isSuccess, isTrue); // SCR-42 / SCR-04
        expect(page.dialogs, <String>['create']);
        expect(page.bound?.owner, _userA);

        expect(await adapter.capability(), BiometricUnlockKind.cryptoBound);
        expect(await adapter.kind(), BiometricUnlockKind.cryptoBound);
        final BiometricSecretResult r = await adapter.readSecret();
        expect(r, isA<BiometricSecretOk>().having((BiometricSecretOk s) => s.secret, 'secret', _refreshOne));
        expect(await adapter.storeSecret(_refreshTwo), isTrue);
        expect(page.dialogs, <String>[
          'create',
          'get',
        ], reason: 'перешифровка без второго диалога (ключ в памяти ≤ 60 с)');
        expect(
          page.methods.where((String m) => m == DemoPasskeyMethod.store),
          hasLength(1),
          reason: 'replace, не store',
        );
        expect(page.bound?.secret, _refreshTwo);

        // Через 60 с ключа в памяти нет — тот же ключ passkey, но с get().
        page.expireKey();
        expect(await adapter.storeSecret(_refreshOne), isTrue);
        expect(page.dialogs.last, 'get');

        // Отмена и инвалидация — исходы SCR-08 (PIN доступен; без PRF запись удалена).
        page.dialogErrors.add('cancelled');
        expect(await adapter.readSecret(), isA<BiometricSecretCancelled>());
        page.prfAtGet = false;
        expect(await adapter.readSecret(), isA<BiometricSecretInvalidated>());
        expect(page.bound, isNull);
        expect(await adapter.kind(), BiometricUnlockKind.none);
      },
    );

    test('SCR-08, привязка: запись другого пользователя не предлагается и не открывается (T-DEMO-022)', () async {
      final FakeDemoPasskeyGateway page = FakeDemoPasskeyGateway()..bound = (owner: _userA, secret: _refreshOne);
      await _signIn(storage, _userB);
      final WebPasskeyAuthenticator web = _web(page, DemoPasskeyMode.bound, storage);
      final BiometricUnlockAdapter adapter = BiometricUnlockAdapter(authenticator: web, storage: storage);
      expect(await adapter.kind(), BiometricUnlockKind.none);
      expect(await adapter.readSecret(), isA<BiometricSecretInvalidated>());
      expect(page.dialogs, isEmpty);
      expect(page.bound?.owner, _userA, reason: 'чужую запись страница не удаляет');
    });

    test('SCR-08, гейт: кнопка только у включившего; подтверждение — диалог WebAuthn, PIN обязателен', () async {
      final FakeDemoPasskeyGateway page = FakeDemoPasskeyGateway();
      final WebPasskeyAuthenticator web = _web(page, DemoPasskeyMode.gate, storage);
      final BiometricUnlockAdapter adapter = BiometricUnlockAdapter(authenticator: web, storage: storage);
      expect(await adapter.capability(), BiometricUnlockKind.windowsHelloGate, reason: 'AuthDeviceInfo: windows_hello');
      expect(await adapter.kind(), BiometricUnlockKind.none, reason: 'гейт не включён этим пользователем');

      expect(await HelloGateUsers(storage).add(_userA), isTrue);
      expect(await adapter.kind(), BiometricUnlockKind.windowsHelloGate);
      expect(await adapter.confirmPresence(), isTrue);
      expect(await adapter.confirmPresence(), isTrue);
      expect(page.dialogs, <String>['create', 'get'], reason: 'passkey браузера создаётся один раз');
      page.dialogErrors.add('cancelled');
      expect(await adapter.confirmPresence(), isFalse);
      expect(await adapter.readSecret(), isA<BiometricSecretUnavailable>(), reason: 'гейт секрета не открывает');

      // Выход: очистка сессии запись гейта не трогает.
      await adapter.clear();
      expect(page.gate, isTrue);
      expect(page.calls.last.args, <String, Object?>{'mode': 'gate'});

      await _signIn(storage, _userB);
      expect(await adapter.kind(), BiometricUnlockKind.none, reason: 'у другого пользователя кнопки нет');
    });

    test('SCR-08 планшета: порт не вызывается ни в каком режиме (BIO-037)', () async {
      for (final DemoPasskeyMode mode in DemoPasskeyMode.values) {
        final FakeDemoPasskeyGateway page = FakeDemoPasskeyGateway()..bound = (owner: _userA, secret: _refreshOne);
        await HelloGateUsers(storage).add(_userA);
        final BiometricUnlockAdapter adapter = BiometricUnlockAdapter(
          authenticator: _web(page, mode, storage),
          storage: storage,
          kioskMode: () => true,
        );
        expect(await adapter.capability(), BiometricUnlockKind.none);
        expect(await adapter.kind(), BiometricUnlockKind.none);
        expect(await adapter.readSecret(), isA<BiometricSecretUnavailable>());
        expect(await adapter.confirmPresence(), isFalse);
        expect(page.calls, isEmpty, reason: mode.name);
      }
    });

    test(
      'SCR-42, привязка: «Вход по биометрии» → POST class3 → запись под ключом из PRF; сбой PRF — отзыв, вариант скрыт',
      () async {
        final List<Object?> bodies = <Object?>[];
        final FakeDemoPasskeyGateway page = FakeDemoPasskeyGateway();
        final WebPasskeyAuthenticator web = _web(page, DemoPasskeyMode.bound, storage);
        final LoginProtectionRepositoryImpl repo = _settingsRepo(_settingsServer(bodies), web, storage);
        const BiometricPromptCopy copy = BiometricPromptCopy(title: 'Вход по биометрии', cancel: 'Отмена');

        LoginProtectionState s = (await repo.load()).valueOrNull!;
        expect(s.support, BiometricSupport.cryptoLogin);
        expect(s.platformLabel, BiometricPlatformLabel.android);
        expect(s.biometricsEnabled, isFalse);

        expect(await repo.enableBiometrics(copy), BiometricToggleOutcome.enabled);
        expect(bodies.single, containsPair('biometricClass', 'class3'));
        expect(page.bound, (owner: _userA, secret: _refreshOne));
        expect(await storage.read(SecureKey.biometricsEnabled), 'true');
        s = (await repo.load()).valueOrNull!;
        expect(s.biometricsEnabled, isTrue);

        // Другой браузер: passkey создан без PRF → семья отзывается, вариант больше не предлагается.
        bodies.clear();
        final InMemorySecureStorage other = InMemorySecureStorage();
        await _signIn(other, _userA);
        final FakeDemoPasskeyGateway noPrf = FakeDemoPasskeyGateway(clientPrf: 'unknown', prfAtCreate: false);
        final LoginProtectionRepositoryImpl repo2 = _settingsRepo(
          _settingsServer(bodies),
          _web(noPrf, DemoPasskeyMode.bound, other),
          other,
        );
        expect((await repo2.load()).valueOrNull!.support, BiometricSupport.cryptoLogin);
        expect(await repo2.enableBiometrics(copy), BiometricToggleOutcome.failed);
        expect(bodies, hasLength(2));
        expect((bodies.last! as Map<String, Object?>)['enabled'], isFalse, reason: 'выданная семья отозвана');
        expect(noPrf.bound, isNull);
        expect(await other.read(SecureKey.biometricsEnabled), isNull);
        expect((await repo2.load()).valueOrNull!.support, BiometricSupport.unavailable);
      },
    );

    test('SCR-42, гейт: «Windows Hello перед вводом PIN» — диалог WebAuthn и признак по userId, без сервера', () async {
      final List<Object?> bodies = <Object?>[];
      final FakeDemoPasskeyGateway page = FakeDemoPasskeyGateway();
      final LoginProtectionRepositoryImpl repo = _settingsRepo(
        _settingsServer(bodies, kind: 'staff'),
        _web(page, DemoPasskeyMode.gate, storage),
        storage,
      );
      LoginProtectionState s = (await repo.load()).valueOrNull!;
      expect(s.support, BiometricSupport.windowsHelloGate, reason: 'сервер ключ входа не разрешает — режим гейта');
      expect(s.platformLabel, BiometricPlatformLabel.windows);
      expect(
        await repo.enableBiometrics(const BiometricPromptCopy(title: 'Windows Hello', cancel: 'Отмена')),
        BiometricToggleOutcome.enabled,
      );
      expect(page.dialogs, <String>['create']);
      expect(await HelloGateUsers(storage).contains(_userA), isTrue);
      expect(bodies, isEmpty);
      s = (await repo.load()).valueOrNull!;
      expect(s.biometricsEnabled, isTrue);
    });

    test(
      'SCR-42 и SCR-08, браузер на Windows с PRF: «Вход через Windows Hello» → POST helloKey webauthn_prf; вход — один диалог',
      () async {
        final List<Object?> bodies = <Object?>[];
        final FakeDemoPasskeyGateway page = FakeDemoPasskeyGateway();
        final WebPasskeyAuthenticator web = _web(page, DemoPasskeyMode.gate, storage);
        final LoginProtectionRepositoryImpl repo = _settingsRepo(
          _settingsServer(bodies, kind: 'staff', keyAllowed: true),
          web,
          storage,
        );
        LoginProtectionState s = (await repo.load()).valueOrNull!;
        expect(s.support, BiometricSupport.windowsHelloKey);
        expect(s.platformLabel, BiometricPlatformLabel.windows);
        expect(s.biometricsEnabled, isFalse);

        expect(
          await repo.enableBiometrics(const BiometricPromptCopy(title: 'Вход через Windows Hello', cancel: 'Отмена')),
          BiometricToggleOutcome.enabled,
        );
        final Map<String, Object?> body = bodies.single! as Map<String, Object?>;
        expect(body['enabled'], isTrue);
        expect(body['biometricClass'], 'windows_hello');
        expect(body['helloKey'], <String, Object?>{
          'publicKey': FakeDemoPasskeyGateway.publicKeyOf(1),
          'algorithm': 'RS256',
          'source': 'webauthn_prf',
        });
        expect(body['consent'], containsPair('granted', true));
        expect(page.dialogs, <String>['create'], reason: 'один диалог при включении');
        expect(page.helloKeys.keys, <String>[_userA]);
        expect(page.bound, isNull, reason: 'секретов страницы нет — только ключ под PRF');
        expect(await HelloKeyUsers(storage).contains(_userA), isTrue);
        expect(await HelloGateUsers(storage).contains(_userA), isFalse);
        s = (await repo.load()).valueOrNull!;
        expect(s.biometricsEnabled, isTrue);

        // SCR-08 холодного старта: кнопка «Войти через Windows Hello» → один get() → подпись challenge сервера.
        final BiometricUnlockAdapter adapter = BiometricUnlockAdapter(authenticator: web, storage: storage);
        expect(
          await adapter.capability(),
          BiometricUnlockKind.windowsHelloGate,
          reason: 'AuthDeviceInfo: windows_hello',
        );
        expect(await adapter.kind(), BiometricUnlockKind.windowsHelloKey);
        const String challenge = '${helloChallengePrefix}b25lLXRpbWU';
        expect(
          await adapter.signHelloChallenge(challenge),
          isA<HelloKeySigned>().having(
            (HelloKeySigned r) => r.signature,
            'signature',
            FakeDemoPasskeyGateway.signatureOf(1, challenge),
          ),
        );
        expect(page.dialogs, <String>['create', 'get']);

        // «Выйти»: очистка сессии ключ входа не трогает (BIO-040) — после входа по SMS кнопка та же.
        await adapter.clear();
        expect(page.helloKeys.keys, <String>[_userA]);
        expect(await adapter.kind(), BiometricUnlockKind.windowsHelloKey);
        // Другой пользователь этого браузера ключа не видит.
        await _signIn(storage, _userB);
        expect(await adapter.kind(), BiometricUnlockKind.none);
        await _signIn(storage, _userA);

        // Отмена диалога — PIN; ключ пропал (нет выхода PRF) — запись удалена, PIN с helloKeyInvalidated.
        page.dialogErrors.add('cancelled');
        expect(await adapter.signHelloChallenge(challenge), isA<HelloKeySignCancelled>());
        page.prfAtGet = false;
        expect(await adapter.signHelloChallenge(challenge), isA<HelloKeyLost>());
        expect(page.helloKeys, isEmpty);
        await adapter.forgetHelloKey();
        expect(await HelloKeyUsers(storage).contains(_userA), isFalse);
        expect(await adapter.kind(), BiometricUnlockKind.none);
      },
    );

    test(
      'SCR-42, ключ входа: выключение — POST enabled:false, ключ страницы удалён; отказ сервера — ключ удалён',
      () async {
        final List<Object?> bodies = <Object?>[];
        final FakeDemoPasskeyGateway page = FakeDemoPasskeyGateway();
        final WebPasskeyAuthenticator web = _web(page, DemoPasskeyMode.gate, storage);
        const BiometricPromptCopy copy = BiometricPromptCopy(title: 'Вход через Windows Hello', cancel: 'Отмена');
        final LoginProtectionRepositoryImpl repo = _settingsRepo(
          _settingsServer(bodies, kind: 'staff', keyAllowed: true),
          web,
          storage,
        );
        await repo.load();
        expect(await repo.enableBiometrics(copy), BiometricToggleOutcome.enabled);
        expect(await repo.disableBiometrics(), BiometricToggleOutcome.disabled);
        expect((bodies.last! as Map<String, Object?>)['enabled'], isFalse);
        expect(page.helloKeys, isEmpty);
        expect(await HelloKeyUsers(storage).contains(_userA), isFalse);
        expect(await HelloGateUsers(storage).contains(_userA), isFalse, reason: 'гейт не включается');

        for (final (String reason, BiometricToggleOutcome outcome) in <(String, BiometricToggleOutcome)>[
          ('hello_key_disabled', BiometricToggleOutcome.helloKeyDisabled),
          ('hello_key_shared_device', BiometricToggleOutcome.helloKeySharedDevice),
        ]) {
          final FakeDemoPasskeyGateway refused = FakeDemoPasskeyGateway();
          final LoginProtectionRepositoryImpl r = _settingsRepo(
            _settingsServer(
              <Object?>[],
              kind: 'staff',
              keyAllowed: true,
              helloKeyReply: <String, Object?>{'enabled': false, 'reason': reason},
            ),
            _web(refused, DemoPasskeyMode.gate, storage),
            storage,
          );
          await r.load();
          expect(await r.enableBiometrics(copy), outcome);
          expect(refused.helloKeys, isEmpty, reason: '$reason: созданный ключ удалён');
          expect(refused.methods, contains(DemoPasskeyMethod.deleteKey));
          expect(await HelloKeyUsers(storage).contains(_userA), isFalse);
        }
      },
    );

    test(
      'SCR-42, браузер на Windows без PRF: ключ не создан — гейт перед PIN тем же passkey, исход helloKeyNoPrf, без сервера',
      () async {
        final List<Object?> bodies = <Object?>[];
        // Клиент сообщает PRF (`extension:prf`), а passkey создаётся без него — как виртуальный аутентификатор без PRF.
        final FakeDemoPasskeyGateway page = FakeDemoPasskeyGateway(prfAtCreate: false);
        final WebPasskeyAuthenticator web = _web(page, DemoPasskeyMode.gate, storage);
        final LoginProtectionRepositoryImpl repo = _settingsRepo(
          _settingsServer(bodies, kind: 'staff', keyAllowed: true),
          web,
          storage,
        );
        expect((await repo.load()).valueOrNull!.support, BiometricSupport.windowsHelloKey);
        expect(
          await repo.enableBiometrics(const BiometricPromptCopy(title: 'Вход через Windows Hello', cancel: 'Отмена')),
          BiometricToggleOutcome.helloKeyNoPrf,
        );
        expect(bodies, isEmpty, reason: 'ключа нет — серверу нечего отправлять');
        expect(page.dialogs, <String>['create'], reason: 'один диалог: присутствие подтверждено созданием passkey');
        expect(page.gate, isTrue);
        expect(page.noPrf, isTrue);
        expect(page.helloKeys, isEmpty);
        expect(await HelloGateUsers(storage).contains(_userA), isTrue);
        expect(await HelloKeyUsers(storage).contains(_userA), isFalse);

        final LoginProtectionState s = (await repo.load()).valueOrNull!;
        expect(s.support, BiometricSupport.windowsHelloGate, reason: 'перечитывание — режим гейта');
        expect(s.biometricsEnabled, isTrue);
        final BiometricUnlockAdapter adapter = BiometricUnlockAdapter(authenticator: web, storage: storage);
        expect(await adapter.kind(), BiometricUnlockKind.windowsHelloGate);
        expect(await adapter.confirmPresence(), isTrue);
        expect(page.dialogs, <String>['create', 'get'], reason: 'гейт — тот же passkey');

        // Страница ответила no_prf без записи гейта (passkey нет) — гейт включается обычным диалогом.
        final InMemorySecureStorage other = InMemorySecureStorage();
        await _signIn(other, _userA);
        final FakeDemoPasskeyGateway bare = FakeDemoPasskeyGateway();
        bare.respond = (String method, _) => method == DemoPasskeyMethod.createKey
            ? <String, Object?>{'ok': false, 'error': 'not_available', 'reason': 'no_prf', 'gate': false}
            : null;
        final LoginProtectionRepositoryImpl repo2 = _settingsRepo(
          _settingsServer(<Object?>[], kind: 'staff', keyAllowed: true),
          _web(bare, DemoPasskeyMode.gate, other),
          other,
        );
        await repo2.load();
        expect(
          await repo2.enableBiometrics(const BiometricPromptCopy(title: 'Вход через Windows Hello', cancel: 'Отмена')),
          BiometricToggleOutcome.helloKeyNoPrf,
        );
        expect(bare.methods.where((String m) => m == DemoPasskeyMethod.confirmPresence), hasLength(1));
        expect(await HelloGateUsers(other).contains(_userA), isTrue);
      },
    );

    testWidgets(
      'SCR-42, браузер на Windows без PRF: снекбар settings_hello_key_no_prf, секция перечитана — режим гейта',
      (WidgetTester tester) async {
        final FakeProtectionRepository protection = FakeProtectionRepository(
          const LoginProtectionState(
            userKind: UserKind.staff,
            pinSet: true,
            biometricsEnabled: false,
            support: BiometricSupport.windowsHelloKey,
            platformLabel: BiometricPlatformLabel.windows,
            idleLockMinutes: 30,
          ),
        )..enableOutcome = BiometricToggleOutcome.helloKeyNoPrf;
        await pumpSettings(
          tester,
          const SettingsScreen(section: 'security'),
          settingsOverrides(
            sessions: FakeSessionsRepository(<DeviceSession>[session('cur', current: true)]),
            protection: protection,
            viewer: const SettingsViewer(kind: UserKind.staff),
          ),
        );
        final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));
        Future<void> tap(Key key) async {
          await tester.ensureVisible(find.byKey(key));
          await tester.pump();
          await tester.tap(find.byKey(key));
          await settle(tester);
        }

        await tap(SecuritySectionKeys.biometrics);
        await tap(SecuritySectionKeys.consentCheck);
        protection.state = const LoginProtectionState(
          userKind: UserKind.staff,
          pinSet: true,
          biometricsEnabled: true,
          support: BiometricSupport.windowsHelloGate,
          platformLabel: BiometricPlatformLabel.windows,
          idleLockMinutes: 30,
        );
        await tap(SecuritySectionKeys.consentEnable);
        expect(find.text(l10n.settings_hello_key_no_prf), findsOneWidget);
        expect(protection.calls.where((String c) => c == 'load'), hasLength(2));
        final AppSwitch bio = tester.widget<AppSwitch>(find.byKey(SecuritySectionKeys.biometrics));
        expect(bio.value, isTrue);
        expect(bio.label, l10n.settings_bio_windows, reason: 'после перечитывания — «Windows Hello перед вводом PIN»');
        await drain(tester);
      },
    );

    test('SCR-04: плитка и класс устройства по режиму; без PRF — плитки нет', () async {
      Future<(reg.BiometricOption, String?)> scr04(FakeDemoPasskeyGateway page, DemoPasskeyMode mode) async {
        final DeviceBiometricsImpl d = DeviceBiometricsImpl(_web(page, mode, storage), storage);
        return (await d.option(), await d.deviceClass());
      }

      expect(await scr04(FakeDemoPasskeyGateway(), DemoPasskeyMode.bound), (reg.BiometricOption.cryptoLogin, 'class3'));
      expect(await scr04(FakeDemoPasskeyGateway(), DemoPasskeyMode.gate), (
        reg.BiometricOption.windowsHelloGate,
        'windows_hello',
      ));
      expect(await scr04(FakeDemoPasskeyGateway(clientPrf: 'no'), DemoPasskeyMode.bound), (
        reg.BiometricOption.unsupported,
        'none',
      ));
      expect(await scr04(FakeDemoPasskeyGateway(platformAuthenticator: false), DemoPasskeyMode.gate), (
        reg.BiometricOption.unsupported,
        'none',
      ));
    });

    testWidgets('SCR-04: «только биометрия», passkey без PRF → биометрия не включилась, обязательный PIN (AC-AUTH-089)', (
      WidgetTester tester,
    ) async {
      // Клиент PRF не сообщает заранее (`unknown`), passkey создаётся без PRF: вариант был виден, включение не удалось.
      final FakeDemoPasskeyGateway page = FakeDemoPasskeyGateway(clientPrf: 'unknown', prfAtCreate: false);
      final DeviceBiometricsImpl device = DeviceBiometricsImpl(
        _web(page, DemoPasskeyMode.bound, storage),
        storage,
        currentUserId: () => _userA,
      );
      final RegistrationHarness h = RegistrationHarness(device: device);
      await h.pump(tester, const RegistrationSecurityScreen());
      h.container.read(registrationFlowProvider.notifier)
        ..setFullName('Иванов Иван')
        ..setBirthYear('1990')
        ..setPersonalDataAck(true);
      await tester.pump();

      // Только биометрия: биометрия с согласием, PIN выключен.
      await tester.tap(find.byKey(RegistrationSecurityScreen.bioSwitchKey));
      await tester.pump();
      await tester.tap(find.byKey(RegistrationSecurityScreen.bioConsentKey));
      await tester.pump();
      await tester.tap(find.byKey(RegistrationSecurityScreen.pinSwitchKey));
      await tester.pump();
      expect(find.byType(PinField), findsNothing);
      await tester.tap(find.byKey(RegistrationSecurityScreen.completeKey));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(h.repo.completeCalls.single.request.pin, isNull);
      expect(h.repo.enableCalls, hasLength(1));
      expect(page.dialogs, <String>['create']);
      expect(page.bound, isNull);
      expect(h.repo.disableCalls, 1, reason: 'неиспользованная семья отозвана');
      expect(find.text('Биометрия не включена. Задайте PIN-код, чтобы входить в приложение'), findsOneWidget);
      expect(find.byKey(RegistrationSecurityScreen.doneKey), findsNothing);
      expect(await storage.read(SecureKey.biometricsEnabled), isNull);

      await enterPin(tester, '4839', within: find.byType(PinField).first);
      await enterPin(tester, '4839', within: find.byType(PinField).first);
      await tester.tap(find.byKey(RegistrationSecurityScreen.completeKey));
      await tester.pump();
      await tester.pump();
      expect(h.repo.setPinCalls, <String>['4839']);
      expect(find.byKey(RegistrationSecurityScreen.doneKey), findsOneWidget);

      // Вариант привязки в этом браузере больше не предлагается (маркер страницы «без PRF»).
      expect(await device.option(), reg.BiometricOption.unsupported);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });
  });

  group('T-DEMO-016 (5) продукт web и DM-01', () {
    test('продукт web — без биометрии на любой ОС браузера (ADR-113, DM-01)', () {
      for (final TargetPlatform platform in TargetPlatform.values) {
        expect(
          biometricAuthenticatorFor(platform, storage: storage, isProd: false, isWeb: true),
          isA<NoBiometricAuthenticator>(),
          reason: platform.name,
        );
      }
    });

    test('lib/main.dart и провайдер биометрии core демо-код не импортируют', () {
      for (final String path in <String>['lib/main.dart', 'lib/core/biometrics/biometric_providers.dart']) {
        final String source = File(path).readAsStringSync();
        expect(source, isNot(contains('app/demo/')), reason: path);
        expect(source, isNot(contains('WebPasskeyAuthenticator')), reason: path);
      }
    });
  });
}
