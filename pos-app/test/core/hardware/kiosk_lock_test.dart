// Порт закрепления планшета магазина `KioskLock` (13 TAB-2-09; P-002 §8.10; 16 §10.10 «Ограничения на планшете»;
// ADR-115 п. 26, п. 29; 10 KIOSK-024): набор ограничений — одна константа Dart, которую канал применяет как есть
// (в том числе `no_autofill` и функции `lock task` без уведомлений); протокол канала `kg.optomstroy/kiosk_lock` на
// моке; состояние «Закрепление включено» (`X-Kiosk-Lock: on`) — только при полном закреплении; Windows и веб — без
// действия; статическая проверка нативной части (Kotlin, манифест, `device_admin.xml`): приложение «Домой» выключено
// по умолчанию, лаунчер и канал биометрии сотрудников не тронуты (паритет функций).
// Проверка на устройстве (Device Owner, «Домой», «Недавние», шторка, `dumpsys device_policy`) — ручная: эмулятор
// в TAB-2-09 недоступен (ADR-115 п. 30), модель заказчика — пилот TAB-4-01, шаг 1.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/hardware/kiosk_lock.dart';
import 'package:optomstroy/features/kiosk/kiosk_providers.dart' as kiosk;

String _read(String path) => File(path).readAsStringSync();

const String _manifest = 'android/app/src/main/AndroidManifest.xml';
const String _kotlinDir = 'android/app/src/main/kotlin/com/example/optomstroy';

/// Значения констант `UserManager.DISALLOW_*` Android (developer.android.com) → имя константы в Kotlin.
const Map<String, String> _androidRestrictionConstants = <String, String>{
  'no_safe_boot': 'DISALLOW_SAFE_BOOT',
  'no_factory_reset': 'DISALLOW_FACTORY_RESET',
  'no_debugging_features': 'DISALLOW_DEBUGGING_FEATURES',
  'no_install_apps': 'DISALLOW_INSTALL_APPS',
  'no_autofill': 'DISALLOW_AUTOFILL',
};

/// Снимок канала «всё включено» по [kioskLockPolicy] (Android 9+).
Map<String, Object?> _lockedSnapshot() => <String, Object?>{
  'supported': true,
  'deviceOwner': true,
  'lockTaskActive': true,
  'homeApp': true,
  'activeRestrictions': List<String>.of(kioskLockPolicy.userRestrictions),
  'unsupportedRestrictions': <String>[],
  'rejectedRestrictions': <String>[],
  'lockTaskFeatures': <String>[],
  'error': null,
};

/// Блок XML-элемента `<tag … android:name="name" …>…</tag>` манифеста.
String _element(String xml, String tag, String name) {
  final RegExpMatch? m = RegExp('<$tag\\s[^>]*android:name="${RegExp.escape(name)}"[\\s\\S]*?</$tag>').firstMatch(xml);
  expect(m, isNotNull, reason: '<$tag android:name="$name">');
  return m!.group(0)!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TAB-2-09 политика закрепления (16 §10.10; ADR-115 п. 29)', () {
    test('ограничения: безопасный режим, сброс из настроек, отладка по USB, установка приложений, автозаполнение', () {
      expect(kioskLockPolicy.userRestrictions.toSet(), <String>{
        'no_safe_boot',
        'no_factory_reset',
        'no_debugging_features',
        'no_install_apps',
        'no_autofill',
      });
      expect(kioskLockPolicy.userRestrictions, hasLength(5), reason: 'без повторов');
      expect(kioskLockPolicy.userRestrictions, contains('no_autofill'), reason: 'DISALLOW_AUTOFILL, ADR-115 п. 29');
    });

    test(
      'lock task без уведомлений, системной строки, «Домой», «Недавних» и меню питания; шторка и экран блокировки',
      () {
        expect(kioskLockPolicy.lockTaskFeatures, isEmpty, reason: 'LOCK_TASK_FEATURE_NONE');
        for (final String feature in <String>['notifications', 'system_info', 'home', 'overview', 'global_actions']) {
          expect(kioskLockPolicy.lockTaskFeatures, isNot(contains(feature)), reason: feature);
        }
        expect(kioskLockPolicy.statusBarDisabled, isTrue);
        expect(kioskLockPolicy.keyguardDisabled, isTrue);
      },
    );

    test('аргументы enable — ровно политика', () {
      expect(kioskLockPolicy.toChannelArguments(), <String, Object?>{
        'userRestrictions': <String>[
          'no_safe_boot',
          'no_factory_reset',
          'no_debugging_features',
          'no_install_apps',
          'no_autofill',
        ],
        'lockTaskFeatures': <String>[],
        'statusBarDisabled': true,
        'keyguardDisabled': true,
      });
    });
  });

  group('ChannelKioskLock (протокол канала kg.optomstroy/kiosk_lock)', () {
    const MethodChannel channel = MethodChannel(ChannelKioskLock.channelName);
    final List<MethodCall> calls = <MethodCall>[];
    final TestDefaultBinaryMessenger messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    void handle(Object? Function(MethodCall call) reply) {
      calls.clear();
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        return reply(call);
      });
    }

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    ChannelKioskLock android() => ChannelKioskLock(platform: TargetPlatform.android, isWeb: false);

    test('enable передаёт политику и возвращает снимок; disable и status — без аргументов', () async {
      handle((_) => _lockedSnapshot());
      final KioskLockStatus enabled = await android().enable();
      expect(calls.single.method, 'enable');
      expect(calls.single.arguments, kioskLockPolicy.toChannelArguments());
      expect(enabled.isLocked, isTrue);

      await android().disable();
      expect(calls.last.method, 'disable');
      expect(calls.last.arguments, isNull);

      await android().status();
      expect(calls.last.method, 'status');
      expect(calls.last.arguments, isNull);
    });

    test('T-KIOSK-068 (порт): X-Kiosk-Lock on — Device Owner, lock task, «Домой» и весь набор ограничений', () async {
      handle((_) => _lockedSnapshot());
      final KioskLockStatus status = await android().status();
      expect(status.supported, isTrue);
      expect(status.deviceOwner, isTrue);
      expect(status.lockTaskActive, isTrue);
      expect(status.homeApp, isTrue);
      expect(status.missingRestrictions(), isEmpty);
      expect(status.lockTaskFeaturesMatch(), isTrue);
      expect(status.error, isNull);
      expect(status.headerValue, 'on');
    });

    test('T-KIOSK-068 (порт): неполное закрепление → off (SCR-54 «Закрепление не включено» без adb)', () async {
      final Map<String, Map<String, Object?>> cases = <String, Map<String, Object?>>{
        'нет Device Owner': <String, Object?>{..._lockedSnapshot(), 'deviceOwner': false},
        'lock task не включён': <String, Object?>{..._lockedSnapshot(), 'lockTaskActive': false},
        '«Домой» не назначено': <String, Object?>{..._lockedSnapshot(), 'homeApp': false},
        'служба автозаполнения не запрещена': <String, Object?>{
          ..._lockedSnapshot(),
          'activeRestrictions': kioskLockPolicy.userRestrictions.where((String k) => k != 'no_autofill').toList(),
        },
        'отладка по USB не запрещена': <String, Object?>{
          ..._lockedSnapshot(),
          'activeRestrictions': kioskLockPolicy.userRestrictions
              .where((String k) => k != 'no_debugging_features')
              .toList(),
        },
        'уведомления в lock task разрешены': <String, Object?>{
          ..._lockedSnapshot(),
          'lockTaskFeatures': <String>['notifications'],
        },
        '«Недавние» в lock task разрешены': <String, Object?>{
          ..._lockedSnapshot(),
          'lockTaskFeatures': <String>['overview'],
        },
        'не платформа закрепления': <String, Object?>{..._lockedSnapshot(), 'supported': false},
      };
      for (final MapEntry<String, Map<String, Object?>> c in cases.entries) {
        handle((_) => c.value);
        final KioskLockStatus status = await android().status();
        expect(status.isLocked, isFalse, reason: c.key);
        expect(status.headerValue, 'off', reason: c.key);
      }
      handle(
        (_) => <String, Object?>{
          ..._lockedSnapshot(),
          'activeRestrictions': <String>['no_safe_boot'],
        },
      );
      expect((await android().status()).missingRestrictions(), <String>{
        'no_factory_reset',
        'no_debugging_features',
        'no_install_apps',
        'no_autofill',
      });
    });

    test('Android 7–7.1: no_autofill в системе нет, функций lock task нет — закрепление считается полным', () async {
      handle(
        (_) => <String, Object?>{
          ..._lockedSnapshot(),
          'activeRestrictions': kioskLockPolicy.userRestrictions.where((String k) => k != 'no_autofill').toList(),
          'unsupportedRestrictions': <String>['no_autofill'],
          'lockTaskFeatures': null,
        },
      );
      final KioskLockStatus status = await android().status();
      expect(status.lockTaskFeatures, isNull);
      expect(status.isLocked, isTrue);
    });

    test('ключ политики, неизвестный каналу, не считается включённым', () async {
      const KioskLockPolicy extra = KioskLockPolicy(
        userRestrictions: <String>['no_safe_boot', 'no_unknown_key'],
        lockTaskFeatures: <String>[],
        statusBarDisabled: true,
        keyguardDisabled: true,
      );
      handle(
        (_) => <String, Object?>{
          ..._lockedSnapshot(),
          'rejectedRestrictions': <String>['no_unknown_key'],
        },
      );
      final KioskLockStatus status = await ChannelKioskLock(
        platform: TargetPlatform.android,
        isWeb: false,
        policy: extra,
      ).enable();
      expect(calls.single.arguments, extra.toChannelArguments());
      expect(status.rejectedRestrictions, <String>{'no_unknown_key'});
      expect(status.isLockedBy(extra), isFalse);
    });

    test('enable без Device Owner → not_device_owner, off; сбой шага → failed', () async {
      handle(
        (_) => <String, Object?>{
          ..._lockedSnapshot(),
          'deviceOwner': false,
          'lockTaskActive': false,
          'homeApp': false,
          'activeRestrictions': <String>[],
          'lockTaskFeatures': null,
          'error': 'not_device_owner',
        },
      );
      final KioskLockStatus notOwner = await android().enable();
      expect(notOwner.error, KioskLockError.notDeviceOwner);
      expect(notOwner.headerValue, 'off');

      handle((_) => <String, Object?>{..._lockedSnapshot(), 'error': 'failed'});
      expect((await android().disable()).error, KioskLockError.failed);
    });

    test('PlatformException и пустой ответ → failed, off; канал не зарегистрирован → без закрепления', () async {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async => throw PlatformException(code: 'boom'));
      final KioskLockStatus failed = await android().enable();
      expect(failed.error, KioskLockError.failed);
      expect(failed.headerValue, 'off');

      handle((_) => null);
      expect((await android().status()).error, KioskLockError.failed);

      messenger.setMockMethodCallHandler(channel, null);
      final KioskLockStatus missing = await android().disable();
      expect(missing, KioskLockStatus.unsupported);
      expect(missing.headerValue, 'off');
    });

    test('T-KIOSK-068 (порт): Windows, iOS и веб — канал не вызывается, off', () async {
      handle((_) => _lockedSnapshot());
      for (final ChannelKioskLock lock in <ChannelKioskLock>[
        ChannelKioskLock(platform: TargetPlatform.windows, isWeb: false),
        ChannelKioskLock(platform: TargetPlatform.iOS, isWeb: false),
        ChannelKioskLock(platform: TargetPlatform.android, isWeb: true),
      ]) {
        expect(await lock.enable(), KioskLockStatus.unsupported);
        expect(await lock.status(), KioskLockStatus.unsupported);
        expect(await lock.disable(), KioskLockStatus.unsupported);
      }
      expect(calls, isEmpty);
    });
  });

  group('NoKioskLock и привязка', () {
    test('T-KIOSK-068 (порт): NoKioskLock — без действия, X-Kiosk-Lock off', () async {
      const NoKioskLock lock = NoKioskLock();
      for (final KioskLockStatus s in <KioskLockStatus>[
        await lock.enable(),
        await lock.status(),
        await lock.disable(),
      ]) {
        expect(s, KioskLockStatus.unsupported);
        expect(s.isLocked, isFalse);
        expect(s.headerValue, 'off');
      }
    });

    test('kioskLockFor: Android — канал; Windows, iOS, Linux, macOS и веб — NoKioskLock', () {
      expect(kioskLockFor(TargetPlatform.android, isWeb: false), isA<ChannelKioskLock>());
      expect(kioskLockFor(TargetPlatform.android, isWeb: true), isA<NoKioskLock>());
      for (final TargetPlatform p in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.iOS,
        TargetPlatform.linux,
        TargetPlatform.macOS,
      ]) {
        expect(kioskLockFor(p, isWeb: false), isA<NoKioskLock>(), reason: p.name);
      }
    });

    test('провайдер по умолчанию — NoKioskLock; фича kiosk получает тот же провайдер (FL-02)', () {
      final ProviderContainer container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(kioskLockProvider), isA<NoKioskLock>());
      expect(identical(kiosk.kioskLockProvider, kioskLockProvider), isTrue);
      expect(identical(kiosk.kioskLockPolicy, kioskLockPolicy), isTrue);
    });

    test('toString снимка без перечня ключей', () {
      final String text = KioskLockStatus.fromChannel(_lockedSnapshot()).toString();
      expect(text, contains('deviceOwner: true'));
      expect(text, isNot(contains('no_autofill')));
    });
  });

  group('нативная часть Android (статическая проверка; паритет функций)', () {
    test('KioskLockChannel.kt: канал, известные ключи политики, включение и снятие', () {
      final String kt = _read('$_kotlinDir/KioskLockChannel.kt');
      expect(kt, contains('"${ChannelKioskLock.channelName}"'));
      for (final String key in kioskLockPolicy.userRestrictions) {
        final String? constant = _androidRestrictionConstants[key];
        expect(constant, isNotNull, reason: 'значение константы Android для $key');
        expect(kt, contains('UserManager.$constant to'), reason: key);
      }
      for (final String feature in <String>[
        'system_info',
        'notifications',
        'home',
        'overview',
        'global_actions',
        'keyguard',
      ]) {
        expect(kt, contains('"$feature" to DevicePolicyManager.LOCK_TASK_FEATURE_'), reason: feature);
      }
      for (final String call in <String>[
        'dpm.setLockTaskPackages(admin, arrayOf(activity.packageName))',
        'dpm.setLockTaskPackages(admin, emptyArray())',
        'dpm.setLockTaskFeatures(admin, featureMask(features))',
        'dpm.setLockTaskFeatures(admin, DEFAULT_LOCK_TASK_FEATURES)',
        'dpm.addUserRestriction(admin, key)',
        'dpm.clearUserRestriction(admin, key)',
        'dpm.setStatusBarDisabled(admin, statusBarDisabled)',
        'dpm.setStatusBarDisabled(admin, false)',
        'dpm.setKeyguardDisabled(admin, keyguardDisabled)',
        'dpm.setKeyguardDisabled(admin, false)',
        'dpm.addPersistentPreferredActivity(admin, home, homeAlias)',
        'dpm.clearPackagePersistentPreferredActivities(admin, activity.packageName)',
        'activity.startLockTask()',
        'activity.stopLockTask()',
        'dpm.isDeviceOwnerApp(activity.packageName)',
        '"not_device_owner"',
        'Intent.CATEGORY_HOME',
      ]) {
        expect(kt, contains(call), reason: call);
      }
      // Снятие Device Owner сломало бы обновление и подключение заново (16 §10.10): его в канале нет.
      expect(kt, isNot(contains('clearDeviceOwnerApp')));
      expect(kt, isNot(contains('wipeData')));
      expect(kt, contains('"com.example.optomstroy.KioskHomeAlias"'));
    });

    test('KioskDeviceAdminReceiver и device_admin.xml: приёмник без своих действий, список политик пуст', () {
      expect(
        _read('$_kotlinDir/KioskDeviceAdminReceiver.kt'),
        contains('class KioskDeviceAdminReceiver : DeviceAdminReceiver()'),
      );
      final String policies = _read('android/app/src/main/res/xml/device_admin.xml');
      expect(policies, contains('<device-admin'));
      expect(policies, contains('<uses-policies />'));
      for (final String p in <String>[
        'wipe-data',
        'reset-password',
        'force-lock',
        'limit-password',
        'disable-camera',
      ]) {
        expect(policies, isNot(contains('<$p')), reason: p);
      }
    });

    test('манифест: приёмник под BIND_DEVICE_ADMIN, lock task if_whitelisted, «Домой» выключено по умолчанию', () {
      final String m = _read(_manifest);
      final String receiver = _element(m, 'receiver', '.KioskDeviceAdminReceiver');
      expect(receiver, contains('android:permission="android.permission.BIND_DEVICE_ADMIN"'));
      expect(receiver, contains('android:name="android.app.device_admin"'));
      expect(receiver, contains('android:resource="@xml/device_admin"'));
      expect(receiver, contains('android.app.action.DEVICE_ADMIN_ENABLED'));

      final String activity = _element(m, 'activity', '.MainActivity');
      expect(activity, contains('android:lockTaskMode="if_whitelisted"'));
      // Паритет: лаунчер сотрудников и покупателей — прежний, «Домой» у самой активности нет.
      expect(activity, contains('android.intent.category.LAUNCHER'));
      expect(activity, isNot(contains('android.intent.category.HOME')));

      final String alias = _element(m, 'activity-alias', '.KioskHomeAlias');
      expect(alias, contains('android:targetActivity=".MainActivity"'));
      expect(alias, contains('android:enabled="false"'));
      expect(alias, contains('android.intent.category.HOME'));
      expect(alias, contains('android.intent.category.DEFAULT'));
      expect(alias, isNot(contains('android.intent.category.LAUNCHER')));
      expect(RegExp('category.HOME').allMatches(m), hasLength(1), reason: 'HOME — только у выключенного alias');

      // Новых разрешений нет: прежнее единственное — биометрия (T-BIO-018).
      expect(RegExp('<uses-permission ').allMatches(m), hasLength(1));
      for (final String tag in <String>['activity', 'activity-alias', 'receiver', 'intent-filter', 'application']) {
        expect(RegExp('<$tag[\\s>]').allMatches(m).length, RegExp('</$tag>').allMatches(m).length, reason: tag);
      }
    });

    test('MainActivity регистрирует канал закрепления рядом с каналом биометрии', () {
      final String activity = _read('$_kotlinDir/MainActivity.kt');
      expect(activity, contains('BiometricCryptoChannel(this, flutterEngine.dartExecutor.binaryMessenger)'));
      expect(activity, contains('KioskLockChannel(this, flutterEngine.dartExecutor.binaryMessenger)'));
      expect(activity, contains('kioskLock?.dispose()'));
      expect(activity, contains(': FlutterFragmentActivity()'));
    });
  });
}
