// Фейки портов SCR-42 для unit- и widget-тестов (без ПДн реальных пользователей).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/settings/domain/entities/settings_entities.dart';
import 'package:optomstroy/features/settings/domain/repositories/settings_repositories.dart';
import 'package:optomstroy/features/settings/settings_providers.dart';

final DateTime t0 = DateTime.utc(2026, 10, 22, 9);

DeviceSession session(String id, {bool current = false, String name = 'Касса-1', DevicePlatform? platform}) =>
    DeviceSession(
      id: id,
      deviceId: 'dev-$id',
      isCurrent: current,
      deviceName: name,
      platform: platform ?? DevicePlatform.windows,
      appVersion: '1.0.0+1',
      kind: SessionKind.standard,
      lastUsedAt: t0.subtract(const Duration(minutes: 5)),
      ipMasked: '212.***.***.12',
    );

/// Фейк «Устройства и сессии».
final class FakeSessionsRepository implements DeviceSessionsRepository {
  FakeSessionsRepository(this.items);

  List<DeviceSession> items;
  Failure? listFailure;
  Failure? revokeFailure;
  Failure? logoutAllFailure;
  final List<String> calls = <String>[];

  @override
  Future<Result<List<DeviceSession>>> list() async {
    calls.add('list');
    final Failure? f = listFailure;
    return f == null
        ? Success<List<DeviceSession>>(List<DeviceSession>.of(items))
        : FailureResult<List<DeviceSession>>(f);
  }

  @override
  Future<Result<void>> revoke(String sessionId) async {
    calls.add('revoke:$sessionId');
    final Failure? f = revokeFailure;
    if (f != null) return FailureResult<void>(f);
    items = <DeviceSession>[
      for (final DeviceSession s in items)
        if (s.id != sessionId) s,
    ];
    return const Success<void>(null);
  }

  @override
  Future<Result<DeviceSession>> rename(String sessionId, String deviceName) async {
    calls.add('rename:$sessionId:$deviceName');
    final DeviceSession s = items.firstWhere((DeviceSession e) => e.id == sessionId).copyWith(deviceName: deviceName);
    return Success<DeviceSession>(s);
  }

  @override
  Future<void> logoutCurrent() async => calls.add('logoutCurrent');

  @override
  Future<Result<void>> logoutAll() async {
    calls.add('logoutAll');
    final Failure? f = logoutAllFailure;
    return f == null ? const Success<void>(null) : FailureResult<void>(f);
  }
}

/// Фейк «Защита входа».
final class FakeProtectionRepository implements LoginProtectionRepository {
  FakeProtectionRepository(this.state);

  LoginProtectionState state;
  Failure? loadFailure;
  bool stepUpGranted = true;
  Failure? changePinFailure;
  BiometricToggleOutcome enableOutcome = BiometricToggleOutcome.enabled;
  Failure? idleFailure;
  final List<String> calls = <String>[];

  /// Последний отправленный PIN (только тест; в продуктиве PIN не сохраняется).
  String? lastPin;

  @override
  Future<Result<LoginProtectionState>> load() async {
    calls.add('load');
    final Failure? f = loadFailure;
    return f == null ? Success<LoginProtectionState>(state) : FailureResult<LoginProtectionState>(f);
  }

  @override
  Future<Result<void>> changePin(String newPin) async {
    calls.add('changePin');
    lastPin = newPin;
    final Failure? f = changePinFailure;
    return f == null ? const Success<void>(null) : FailureResult<void>(f);
  }

  @override
  Future<Result<void>> removePin() async {
    calls.add('removePin');
    return const Success<void>(null);
  }

  @override
  Future<bool> stepUpForPin({required bool otpOnly}) async {
    calls.add('stepUp:${otpOnly ? 'otp' : 'pin|otp'}');
    return stepUpGranted;
  }

  @override
  Future<BiometricToggleOutcome> enableBiometrics(BiometricPromptCopy prompt) async {
    calls.add('enableBio');
    return enableOutcome;
  }

  @override
  Future<BiometricToggleOutcome> disableBiometrics() async {
    calls.add('disableBio');
    return BiometricToggleOutcome.disabled;
  }

  @override
  Future<Result<int>> setIdleLockMinutes(int minutes) async {
    calls.add('idle:$minutes');
    final Failure? f = idleFailure;
    return f == null ? Success<int>(minutes) : FailureResult<int>(f);
  }

  @override
  Future<Result<Map<String, Object?>>> patchSettings(Map<String, Object?> patch) async {
    calls.add('patch');
    return Success<Map<String, Object?>>(patch);
  }
}

const LoginProtectionState staffProtection = LoginProtectionState(
  userKind: UserKind.staff,
  pinSet: true,
  biometricsEnabled: false,
  support: BiometricSupport.windowsHelloGate,
  platformLabel: BiometricPlatformLabel.windows,
  idleLockMinutes: 30,
  birthYear: 1990,
);

const LoginProtectionState customerProtection = LoginProtectionState(
  userKind: UserKind.customer,
  pinSet: true,
  biometricsEnabled: false,
  support: BiometricSupport.cryptoLogin,
  platformLabel: BiometricPlatformLabel.android,
);

/// Фейк порта биометрии core/biometrics.
final class FakeBiometricAuthenticator implements BiometricAuthenticator {
  FakeBiometricAuthenticator(this.cap, {this.storeResult = const BiometricResult<void>.success(null)});

  BiometricCapability cap;
  BiometricResult<void> storeResult;
  String? stored;
  int clears = 0;
  int presence = 0;

  @override
  Future<BiometricCapability> capability() async => cap;

  @override
  Future<BiometricResult<void>> store(String secret, BiometricPromptText prompt) async {
    if (storeResult.isSuccess) stored = secret;
    return storeResult;
  }

  @override
  Future<BiometricResult<String>> read(BiometricPromptText prompt) async =>
      const BiometricResult<String>.failure(BiometricError.noCredential);

  @override
  Future<bool> hasStoredSecret() async => stored != null;

  @override
  Future<void> clear() async {
    clears++;
    stored = null;
  }

  @override
  Future<BiometricResult<void>> confirmPresence(BiometricPromptText prompt) async {
    presence++;
    return const BiometricResult<void>.success(null);
  }
}

const BiometricCapability androidClass3 = BiometricCapability(
  kind: BiometricKind.androidClass3,
  availability: BiometricAvailability.available,
  cryptoBinding: true,
);

const BiometricCapability windowsHello = BiometricCapability(
  kind: BiometricKind.windowsHello,
  availability: BiometricAvailability.available,
  cryptoBinding: false,
);

/// Переопределения для SCR-42.
List<Override> settingsOverrides({
  required FakeSessionsRepository sessions,
  required FakeProtectionRepository protection,
  SettingsViewer viewer = const SettingsViewer(kind: UserKind.staff, primaryRole: RoleCode.seller),
  bool online = true,
  List<Override> extra = const <Override>[],
}) => <Override>[
  deviceSessionsRepositoryProvider.overrideWithValue(sessions),
  loginProtectionRepositoryProvider.overrideWithValue(protection),
  displayPreferencesRepositoryProvider.overrideWithValue(MemoryDisplayPreferencesRepository()),
  settingsViewerProvider.overrideWithValue(viewer),
  settingsOnlineProvider.overrideWithValue(online),
  onlineStatusProvider.overrideWith((Ref ref) => Stream<OnlineStatus>.value(OnlineStatus.online)),
  clockProvider.overrideWithValue(FixedClock(t0)),
  appAboutSourceProvider.overrideWithValue(
    const _FixedAbout(
      AppAboutInfo(
        appVersion: '1.0.0+1',
        platform: DevicePlatform.windows,
        deviceIdSuffix: '6f6e7d01',
        minVersion: '1.0.0',
        recommendedVersion: '1.1.0',
      ),
    ),
  ),
  ...extra,
];

final class _FixedAbout implements AppAboutSource {
  const _FixedAbout(this.info);

  final AppAboutInfo info;

  @override
  AppAboutInfo current() => info;
}

/// Приложение для widget-тестов (тема B, ru).
Widget settingsApp(Widget child, List<Override> overrides, {Size? size}) => ProviderScope(
  overrides: overrides,
  child: MaterialApp(
    theme: AppTheme.light(),
    locale: const Locale('ru'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    debugShowCheckedModeBanner: false,
    builder: (BuildContext context, Widget? app) =>
        MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: app!),
    home: child,
  ),
);

Future<void> pumpSettings(
  WidgetTester tester,
  Widget child,
  List<Override> overrides, {
  Size size = const Size(1280, 900),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(settingsApp(child, overrides));
  await tester.pumpAndSettle();
}

/// Ожидание микрозадач контроллеров.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pumpAndSettle();
}

/// Завершение незавершённых таймеров (снекбары).
Future<void> drain(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 10));
  unawaited(Future<void>.value());
}
