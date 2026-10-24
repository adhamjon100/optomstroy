// Фейки и обвязка тестов фичи auth (RM-D-007): без сети, без платформенных каналов.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' show RoleCode, UserKind;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/auth/auth_providers.dart';
import 'package:optomstroy/features/auth/domain/entities/otp_challenge.dart';
import 'package:optomstroy/features/auth/domain/entities/session_profile.dart';
import 'package:optomstroy/features/auth/domain/entities/unlock.dart';
import 'package:optomstroy/features/auth/domain/entities/verify_outcome.dart';
import 'package:optomstroy/features/auth/domain/ports/biometric_unlock.dart';
import 'package:optomstroy/features/auth/domain/repositories/auth_repository.dart';
import 'package:optomstroy/features/auth/presentation/navigation/auth_paths.dart';
import 'package:optomstroy/features/auth/presentation/screens/no_session_screen.dart';
import 'package:optomstroy/features/auth/presentation/screens/otp_screen.dart';
import 'package:optomstroy/features/auth/presentation/screens/unlock_screen.dart';

import '../../../support/fake_backend_health.dart';

/// Тестовый мобильный номер КР (национальные цифры) и его E.164.
const String kPhoneDigits = '700123456';
const String kPhoneE164 = '+996700123456';
const String kChallengeId = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f55';
const String kChallengeId2 = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f66';

/// Сценарный репозиторий: результаты задаются заранее, вызовы записываются.
final class FakeAuthRepository implements AuthRepository {
  final List<String> requestedPhones = <String>[];
  final List<String> verifiedCodes = <String>[];
  final List<String> statusPolls = <String>[];
  final List<({String pin, bool invalidated})> pinUnlocks = <({String pin, bool invalidated})>[];
  final List<String> bioUnlocks = <String>[];
  int cleared = 0;

  /// Очередь ответов `requestOtp` (по умолчанию — 202 с [kChallengeId]).
  final List<Result<OtpIssue>> requestResults = <Result<OtpIssue>>[];
  Completer<Result<OtpIssue>>? requestGate;
  Result<VerifyOutcome> verifyResult = const Success<VerifyOutcome>(VerifyAuthenticated(profile: staffSeller));
  Completer<Result<VerifyOutcome>>? verifyGate;
  Result<OtpChallengeStatus>? statusResult;
  Result<UnlockSuccess> unlockResult = const Success<UnlockSuccess>(UnlockSuccess(profile: staffSeller));
  Completer<Result<UnlockSuccess>>? unlockGate;
  Result<BiometricUnlockSuccess> bioResult = const Success<BiometricUnlockSuccess>(
    BiometricUnlockSuccess(
      result: UnlockSuccess(profile: staffSeller),
      nextSecret: 'next-bio', // check-secrets: allow (имя поля DTO / тестовое значение)
    ),
  );
  bool storedSession = true;
  SessionProfile profile = SessionProfile.unknown;

  static OtpIssue issue([String id = kChallengeId]) =>
      OtpIssue(challengeId: id, resendAfterSec: 60, otpTtlSec: 300, codeLength: 6);

  @override
  Future<Result<OtpIssue>> requestOtp({required String phoneE164}) async {
    requestedPhones.add(phoneE164);
    if (requestGate != null) {
      return requestGate!.future;
    }
    if (requestResults.isNotEmpty) {
      return requestResults.removeAt(0);
    }
    return Success<OtpIssue>(issue());
  }

  @override
  Future<Result<OtpChallengeStatus>> challengeStatus(String challengeId) async {
    statusPolls.add(challengeId);
    return statusResult ?? const FailureResult<OtpChallengeStatus>(UnknownFailure());
  }

  @override
  Future<Result<VerifyOutcome>> verifyOtp({required String challengeId, required String code}) async {
    verifiedCodes.add(code);
    if (verifyGate != null) {
      return verifyGate!.future;
    }
    return verifyResult;
  }

  @override
  Future<Result<UnlockSuccess>> unlockWithPin({required String pin, bool biometricInvalidated = false}) async {
    pinUnlocks.add((pin: pin, invalidated: biometricInvalidated));
    if (unlockGate != null) {
      return unlockGate!.future;
    }
    return unlockResult;
  }

  @override
  Future<Result<BiometricUnlockSuccess>> unlockWithBiometric({required String biometricRefresh}) async {
    bioUnlocks.add(biometricRefresh);
    return bioResult;
  }

  @override
  Future<bool> hasStoredSession() async => storedSession;

  @override
  Future<SessionProfile> cachedProfile() async => profile;

  @override
  Future<void> clearLocalSession() async {
    cleared++;
    storedSession = false;
  }
}

/// Профили для сценариев (без ПДн, кроме тестового ФИО).
const SessionProfile staffSeller = SessionProfile(
  kind: UserKind.staff,
  roles: <RoleCode>[RoleCode.seller],
  pinSet: true,
  displayName: 'Абдулла Каримов',
);

/// Биометрия-фейк.
final class FakeBiometricUnlock implements BiometricUnlock {
  FakeBiometricUnlock({this.kindValue = BiometricUnlockKind.cryptoBound, this.secret = const BiometricSecretOk('bio')});

  BiometricUnlockKind kindValue;
  BiometricSecretResult secret;
  bool presence = true;
  int prompts = 0;
  int clears = 0;
  final List<String> stored = <String>[];

  @override
  Future<BiometricUnlockKind> capability() async => kindValue;

  @override
  Future<BiometricUnlockKind> kind() async => kindValue;

  @override
  Future<BiometricSecretResult> readSecret() async {
    prompts++;
    return secret;
  }

  @override
  Future<bool> storeSecret(String secret) async {
    stored.add(secret);
    return true;
  }

  @override
  Future<void> clear() async => clears++;

  @override
  Future<bool> confirmPresence() async => presence;
}

/// Ключ заглушки маршрута-назначения.
Key destinationKey(String path) => Key('dest:$path');

/// Окна трёх брейкпоинтов (03 §7.2).
const Size kCompact = Size(360, 760);
const Size kMedium = Size(800, 900);
const Size kExpanded = Size(1280, 800);

/// Приложение с GoRouter: экраны входа и заглушки назначений.
final class AuthHarness {
  AuthHarness({
    FakeAuthRepository? repository,
    FakeBiometricUnlock? biometrics,
    FixedClock? clock,
    this.offline = false,
    this.extraOverrides = const <Override>[],
  }) : repository = repository ?? FakeAuthRepository(),
       biometrics = biometrics ?? FakeBiometricUnlock(kindValue: BiometricUnlockKind.none),
       clock = clock ?? FixedClock(DateTime.utc(2026, 10, 22, 9));

  final FakeAuthRepository repository;
  final FakeBiometricUnlock biometrics;
  final FixedClock clock;
  final bool offline;

  /// Дополнительные переопределения теста (например, предупреждение SCR-01).
  final List<Override> extraOverrides;
  late GoRouter router;
  late ProviderContainer container;

  static const List<String> destinations = <String>[
    AuthPaths.register,
    AuthPaths.registerSecurity,
    AuthPaths.pendingActivation,
    AuthPaths.catalog,
    AuthPaths.cashier,
    AuthPaths.reports,
    AuthPaths.customerHome,
  ];

  List<Override> get overrides => <Override>[
    authRepositoryProvider.overrideWithValue(repository),
    biometricUnlockProvider.overrideWithValue(biometrics),
    clockProvider.overrideWithValue(clock),
    authOfflineSignalProvider.overrideWithValue(offline),
    backendHealthProbeProvider.overrideWithValue(FakeBackendHealthProbe()),
    ...extraOverrides,
  ];

  String get location => router.state.uri.toString();

  Future<void> pump(
    WidgetTester tester, {
    String initial = AuthPaths.phone,
    Size size = kMedium,
    bool reduceMotion = true,
    TargetPlatform? platform,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    router = GoRouter(
      initialLocation: initial,
      routes: <RouteBase>[
        GoRoute(path: AuthPaths.phone, builder: (BuildContext c, GoRouterState s) => const NoSessionScreen()),
        GoRoute(path: AuthPaths.otp, builder: (BuildContext c, GoRouterState s) => const OtpScreen()),
        GoRoute(path: AuthPaths.unlock, builder: (BuildContext c, GoRouterState s) => UnlockScreen.fromRoute(c)),
        for (final String p in destinations)
          GoRoute(
            path: p,
            builder: (BuildContext c, GoRouterState s) => Scaffold(body: Text(p, key: destinationKey(p))),
          ),
      ],
    );
    addTearDown(router.dispose);
    container = ProviderContainer(overrides: overrides);
    addTearDown(container.dispose);
    final ThemeData theme = AppTheme.light();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: platform == null ? theme : theme.copyWith(platform: platform),
          locale: const Locale('ru'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          debugShowCheckedModeBanner: false,
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pump();
  }
}

/// Локализация ru без виджетов (для сверки канонических строк ARB).
Future<AppLocalizations> ru() => AppLocalizations.delegate.load(const Locale('ru'));

/// Ошибки домена для сценариев.
const Failure otpInvalid3 = AuthFailure(AuthReason.otpInvalid, attemptsLeft: 3);
const Failure otpExpiredFailure = AuthFailure(AuthReason.otpExpired);
const Failure otpLockedFailure = AuthFailure(AuthReason.otpLocked, retryAfter: Duration(seconds: 900));
const Failure otpRateLimited842 = AuthFailure(AuthReason.otpRateLimited, retryAfter: Duration(seconds: 842));
const Failure offlineFailure = NetworkFailure(NetworkFailureKind.offline);
const Failure smsProviderFailure = ServerFailure(code: 'SMS_PROVIDER_ERROR', status: 503);
const Failure deviceMismatchFailure = AuthFailure(AuthReason.deviceMismatch);
