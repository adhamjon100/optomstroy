// Фейки и обвязка тестов фичи registration (RM-D-008). Порт биометрии — мок (без platform channel).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/registration/domain/entities/registration_entities.dart';
import 'package:optomstroy/features/registration/domain/repositories/registration_repositories.dart';
import 'package:optomstroy/features/registration/registration_providers.dart';

final DateTime testNow = DateTime.utc(2026, 10, 22, 9);

RegistrationTicket testTicket({Duration ttl = const Duration(minutes: 15)}) => RegistrationTicket(
  registrationToken: 'reg-token', // check-secrets: allow — тестовое значение
  expiresAt: testNow.add(ttl),
  phoneE164: '+996555123456',
  phoneMasked: '+996 5** *** *56',
);

const RegistrationOutcome customerOutcome = RegistrationOutcome(
  accountStatus: RegistrationAccountStatus.authenticated,
  userKind: 'customer',
  roles: <String>['customer'],
  customerMatch: CustomerMatch(status: CustomerLinkStatus.none, nextStep: CustomerMatchNextStep.none),
);

final class FakeRegistrationRepository implements RegistrationRepository {
  final List<({RegistrationRequest request, String key})> completeCalls = [];
  final List<Result<RegistrationOutcome>> completeResults = [];
  Completer<void>? completeGate;

  final List<String?> enableCalls = [];
  final List<Result<String?>> enableResults = [];
  int disableCalls = 0;

  final List<({String pin, String operation})> stepUpCalls = [];
  final List<Result<String>> stepUpResults = [];

  final List<String> setPinCalls = [];
  Result<void> setPinResult = const Success<void>(null);
  int consentCalls = 0;

  Result<CustomerMatch> matchResult = const Success<CustomerMatch>(CustomerMatch.none);
  final List<({String linkId, bool confirm})> resolveCalls = [];
  Result<CustomerMatch>? resolveResult;

  final List<Result<AccountSnapshot>> accountResults = [];
  int accountCalls = 0;
  int logoutCalls = 0;

  @override
  Future<Result<RegistrationOutcome>> complete(RegistrationRequest request, {required String idempotencyKey}) async {
    completeCalls.add((request: request, key: idempotencyKey));
    await completeGate?.future;
    return completeResults.isEmpty ? const Success<RegistrationOutcome>(customerOutcome) : completeResults.removeAt(0);
  }

  @override
  Future<Result<CustomerMatch>> customerMatch() async => matchResult;

  @override
  Future<Result<CustomerMatch>> confirmCustomerMatch(String linkId) async {
    resolveCalls.add((linkId: linkId, confirm: true));
    return resolveResult ??
        const Success<CustomerMatch>(
          CustomerMatch(status: CustomerLinkStatus.confirmed, nextStep: CustomerMatchNextStep.confirmed),
        );
  }

  @override
  Future<Result<CustomerMatch>> rejectCustomerMatch(String linkId) async {
    resolveCalls.add((linkId: linkId, confirm: false));
    return resolveResult ??
        const Success<CustomerMatch>(
          CustomerMatch(status: CustomerLinkStatus.rejected, nextStep: CustomerMatchNextStep.none),
        );
  }

  @override
  Future<Result<String?>> enableBiometrics({required String? biometricClass, String? stepUpToken}) async {
    enableCalls.add(stepUpToken);
    return enableResults.isEmpty ? const Success<String?>('bio-refresh') : enableResults.removeAt(0);
  }

  @override
  Future<Result<void>> disableBiometrics({String? stepUpToken}) async {
    disableCalls++;
    return const Success<void>(null);
  }

  @override
  Future<Result<String>> stepUpWithPin({required String pin, required String operation}) async {
    stepUpCalls.add((pin: pin, operation: operation));
    return stepUpResults.isEmpty ? const Success<String>('step-up-token') : stepUpResults.removeAt(0);
  }

  @override
  Future<Result<void>> setPin(String newPin, {String? stepUpToken}) async {
    setPinCalls.add(newPin);
    return setPinResult;
  }

  @override
  Future<Result<void>> acknowledgePersonalData() async {
    consentCalls++;
    return const Success<void>(null);
  }

  @override
  Future<Result<AccountSnapshot>> fetchAccount() async {
    accountCalls++;
    return accountResults.isEmpty
        ? const Success<AccountSnapshot>(AccountSnapshot(status: 'pending_activation', roles: <String>[]))
        : accountResults.removeAt(0);
  }

  @override
  Future<void> logout() async => logoutCalls++;
}

final class FakeDraftRepository implements RegistrationDraftRepository {
  FakeDraftRepository([this.stored]);

  RegistrationDraft? stored;
  int clears = 0;

  @override
  Duration get ttl => const Duration(minutes: 15);

  @override
  Future<RegistrationDraft?> load() async => stored;

  @override
  Future<void> save(RegistrationDraft draft) async => stored = draft;

  @override
  Future<void> clear() async {
    clears++;
    stored = null;
  }
}

final class FakeDeviceBiometrics implements DeviceBiometrics {
  FakeDeviceBiometrics({
    this.availableOption = BiometricOption.cryptoLogin,
    this.bindResult = BiometricEnrollmentResult.enabled,
  });

  BiometricOption availableOption;
  BiometricEnrollmentResult bindResult;
  final List<String> bound = [];
  int discards = 0;
  int presenceCalls = 0;

  @override
  Future<BiometricOption> option() async => availableOption;

  @override
  Future<String?> apiClass() async => availableOption == BiometricOption.windowsHelloGate ? 'windows_hello' : 'class3';

  @override
  Future<BiometricEnrollmentResult> bind(String biometricRefreshToken, BiometricPromptCopy copy) async {
    bound.add(biometricRefreshToken);
    return bindResult;
  }

  @override
  Future<BiometricEnrollmentResult> confirmPresence(BiometricPromptCopy copy) async {
    presenceCalls++;
    return bindResult;
  }

  @override
  Future<void> discard() async => discards++;
}

final class RecordingNavigator implements RegistrationNavigator {
  final List<String> events = [];

  @override
  void backToForm(BuildContext context) => events.add('form');

  @override
  void toCustomerLink(BuildContext context) => events.add('customerLink');

  @override
  void toHome(BuildContext context) => events.add('home');

  @override
  void toPendingActivation(BuildContext context) => events.add('pending');

  @override
  void toPhone(BuildContext context, RegistrationExitReason reason) => events.add('phone:${reason.code}');

  @override
  void toSecurity(BuildContext context) => events.add('security');
}

/// Ожидаемая ошибка сервера в тестах.
FailureResult<T> failed<T>(Failure f) => FailureResult<T>(f);

final class RegistrationHarness {
  RegistrationHarness({
    FakeRegistrationRepository? repo,
    FakeDraftRepository? drafts,
    FakeDeviceBiometrics? biometrics,
    this.selfService = true,
    this.online = true,
    this.withTicket = true,
    RegistrationTicket? ticket,
  }) : repo = repo ?? FakeRegistrationRepository(),
       drafts = drafts ?? FakeDraftRepository(),
       biometrics = biometrics ?? FakeDeviceBiometrics(availableOption: BiometricOption.unsupported),
       ticket = ticket ?? testTicket();

  final FakeRegistrationRepository repo;
  final FakeDraftRepository drafts;
  final FakeDeviceBiometrics biometrics;
  final RecordingNavigator navigator = RecordingNavigator();
  final FixedClock clock = FixedClock(testNow);
  final bool selfService;
  final bool online;

  /// `false` — открыть экран без `registration_token` (guard G-2).
  final bool withTicket;
  final RegistrationTicket? ticket;
  int _key = 0;

  late ProviderContainer container;

  List<Override> get overrides => <Override>[
    registrationRepositoryProvider.overrideWithValue(repo),
    registrationDraftRepositoryProvider.overrideWithValue(drafts),
    deviceBiometricsProvider.overrideWithValue(biometrics),
    registrationNavigatorProvider.overrideWithValue(navigator),
    registrationKeyGeneratorProvider.overrideWithValue(() => 'key-${++_key}'),
    clockProvider.overrideWithValue(clock),
    onlineStatusProvider.overrideWith(
      (ref) => Stream<OnlineStatus>.value(online ? OnlineStatus.online : OnlineStatus.offline),
    ),
    appConfigProvider.overrideWithValue(
      AppConfig(
        apiBaseUrl: Uri.parse('http://localhost:3000/api/v1'),
        environment: AppEnvironment.dev,
        logLevel: LogLevel.info,
        features: <String, bool>{FeatureFlag.customerSelfService: selfService},
      ),
    ),
  ];

  /// Окно: compact 400×900 по умолчанию.
  Future<void> pump(WidgetTester tester, Widget screen, {Size size = const Size(400, 1400)}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    container = ProviderContainer(overrides: overrides);
    addTearDown(container.dispose);
    if (withTicket && ticket != null) container.read(registrationTicketProvider.notifier).start(ticket!);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('ru'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) =>
              MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
          home: screen,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }
}

/// Ввод PIN на экранном нампаде `PinField` (цифры не показываются; клавиши — текст цифры).
Future<void> enterPin(WidgetTester tester, String pin, {Finder? within}) async {
  for (final d in pin.split('')) {
    final key = find.descendant(of: within ?? find.byType(Scaffold).last, matching: find.text(d));
    await tester.tap(key.last);
    await tester.pump();
  }
  await tester.pump();
}
