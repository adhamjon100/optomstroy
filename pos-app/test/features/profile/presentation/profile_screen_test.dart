// Widget-тесты SCR-41 (RM-G-008; 02 AC-UI-41-001/002/003/005/007/008): шапка (ФИО, телефон `+996 XXX XXX XXX`,
// роли, «Вход: устройство · время»), правка профиля с `409` (поля сервера + `profile_conflict`), год рождения вне
// диапазона блокирует «Сохранить», смена номера — тот же номер блокируется до запроса, занятый номер —
// `profile_phone_error_taken`; «Выйти» — подтверждение и `SessionController.logout()`; офлайн — «Выйти на всех
// устройствах» недоступно; у `owner`/`admin` нет кассовых пунктов.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/session/session_local_data.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/profile/domain/entities/user_profile.dart';
import 'package:optomstroy/features/profile/domain/repositories/profile_repository.dart';
import 'package:optomstroy/features/profile/presentation/screens/profile_screen.dart';
import 'package:optomstroy/features/profile/presentation/widgets/phone_change_flow.dart';
import 'package:optomstroy/features/profile/presentation/widgets/profile_edit_form.dart';
import 'package:optomstroy/features/profile/profile_providers.dart';

final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));
final DateTime p0 = DateTime.utc(2026, 10, 22, 3, 12);

UserProfile seedMe({List<RoleCode> roles = const <RoleCode>[RoleCode.owner]}) => UserProfile(
  id: 'u-1',
  kind: UserKind.staff,
  status: UserStatus.active,
  roles: roles,
  permissions: const <String>{'transactions.read.all', 'reports.sales.read'},
  permissionsVersion: 1,
  profile: const ProfileData(fullName: 'Нурлан Руководитель', phoneE164: '+996700000003', rowVersion: 4),
  session: ProfileSession(deviceName: 'Касса-1', createdAt: p0),
);

final class FakeProfileRepository implements ProfileRepository {
  FakeProfileRepository({UserProfile? profile}) : profile = profile ?? seedMe();

  UserProfile profile;
  Failure? updateFailure;
  Failure? requestFailure;
  final List<ProfilePatch> patches = <ProfilePatch>[];
  final List<String> requested = <String>[];

  @override
  Future<Result<UserProfile>> me() async => Success<UserProfile>(profile);

  @override
  Future<Result<ProfileData>> update(ProfilePatch patch, {String? idempotencyKey}) async {
    patches.add(patch);
    if (updateFailure != null) {
      final Failure f = updateFailure!;
      updateFailure = null;
      return FailureResult<ProfileData>(f);
    }
    return Success<ProfileData>(ProfileData(fullName: patch.fullName, rowVersion: patch.rowVersion + 1));
  }

  @override
  Future<Result<PhoneChangeChallenge>> requestPhoneChange(String newPhoneE164, {String? stepUpToken}) async {
    requested.add(newPhoneE164);
    if (requestFailure != null) return FailureResult<PhoneChangeChallenge>(requestFailure!);
    return const Success<PhoneChangeChallenge>(
      PhoneChangeChallenge(challengeId: 'ch-1', resendAfterSec: 60, otpTtlSec: 300),
    );
  }

  @override
  Future<Result<PhoneChangeResult>> confirmPhoneChange({required String challengeId, required String code}) async =>
      const Success<PhoneChangeResult>(PhoneChangeResult(phoneE164: '+996700000009', sessionsRevoked: true));
}

final class TestSession extends SessionController {
  // ignore: riverpod_lint/avoid_public_notifier_properties — счётчик вызовов тестового двойника
  int logouts = 0;

  @override
  SessionState build() => SessionState.initial;

  @override
  Future<PendingLocalChanges> pendingLocalChanges() async => PendingLocalChanges.none;

  @override
  Future<void> logout() async => logouts++;
}

Future<void> pumpProfile(
  WidgetTester tester,
  FakeProfileRepository repo, {
  TestSession? session,
  OnlineStatus online = OnlineStatus.online,
  Size size = const Size(1280, 900),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        profileRepositoryProvider.overrideWithValue(repo),
        clockProvider.overrideWithValue(FixedClock(DateTime.utc(2026, 10, 22, 9))),
        onlineStatusProvider.overrideWith((Ref ref) => Stream<OnlineStatus>.value(online)),
        if (session != null) sessionControllerProvider.overrideWith(() => session),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        debugShowCheckedModeBanner: false,
        builder: (context, app) =>
            MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: app!),
        home: const ProfileScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('шапка: ФИО, телефон +996 XXX XXX XXX, роль, «Вход: Касса-1 · 09:12»; нет кассовых пунктов', (
    tester,
  ) async {
    await pumpProfile(tester, FakeProfileRepository(), session: TestSession());
    expect(find.text('Нурлан Руководитель'), findsOneWidget);
    expect(find.text('+996 700 000 003'), findsOneWidget);
    expect(find.text(l10n.role_owner), findsOneWidget);
    expect(find.text(l10n.profile_login_device('Касса-1', '09:12')), findsOneWidget);
    expect(find.byKey(ProfileScreen.transactionsKey), findsOneWidget);
    expect(find.byKey(ProfileScreen.syncKey), findsOneWidget);
    expect(find.text(l10n.profile_value_not_set), findsNWidgets(2));
    expect(find.textContaining('Принять оплату'), findsNothing);
  });

  testWidgets('правка: 409 — поля сервера и profile_conflict; год вне диапазона блокирует «Сохранить»', (tester) async {
    final FakeProfileRepository repo = FakeProfileRepository()
      ..updateFailure = const ConflictFailure(
        ConflictKind.versionConflict,
        details: <String, Object?>{
          'current': <String, Object?>{'fullName': 'Нурлан Сервер', 'rowVersion': 5},
        },
      );
    await pumpProfile(tester, repo, session: TestSession());
    await tester.tap(find.byKey(ProfileScreen.editKey));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(of: find.byKey(ProfileEditForm.yearKey), matching: find.byType(TextField)),
      '1900',
    );
    await tester.pump();
    expect(find.text(l10n.profile_birthyear_error_range('2012')), findsOneWidget);
    expect(tester.widget<AppButton>(find.byKey(ProfileEditForm.saveKey)).onPressed, isNull);

    await tester.enterText(
      find.descendant(of: find.byKey(ProfileEditForm.yearKey), matching: find.byType(TextField)),
      '',
    );
    await tester.enterText(
      find.descendant(of: find.byKey(ProfileEditForm.nameKey), matching: find.byType(TextField)),
      'Нурлан Новый',
    );
    await tester.pump();
    await tester.tap(find.byKey(ProfileEditForm.saveKey));
    await tester.pumpAndSettle();
    expect(repo.patches.single.rowVersion, 4);
    expect(find.byKey(ProfileEditForm.conflictKey), findsOneWidget);
    final TextField name = tester.widget<TextField>(
      find.descendant(of: find.byKey(ProfileEditForm.nameKey), matching: find.byType(TextField)),
    );
    expect(name.controller!.text, 'Нурлан Сервер');
  });

  testWidgets('смена номера: тот же номер — до запроса; занятый — profile_phone_error_taken', (tester) async {
    final FakeProfileRepository repo = FakeProfileRepository()
      ..requestFailure = const ConflictFailure(ConflictKind.phoneAlreadyRegistered);
    await pumpProfile(tester, repo, session: TestSession());
    await tester.tap(find.byKey(ProfileScreen.phoneChangeKey));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(ConfirmDialog), matching: find.text(l10n.profile_phone_get_code)).last,
    );
    await tester.pumpAndSettle();
    final Finder phone = find.descendant(of: find.byKey(PhoneChangeFlow.phoneKey), matching: find.byType(TextField));
    await tester.enterText(phone, '700000003');
    await tester.tap(find.byKey(PhoneChangeFlow.requestKey));
    await tester.pumpAndSettle();
    expect(find.text(l10n.profile_phone_error_same), findsOneWidget);
    expect(repo.requested, isEmpty);
    await tester.enterText(phone, '700000009');
    await tester.tap(find.byKey(PhoneChangeFlow.requestKey));
    await tester.pumpAndSettle();
    expect(repo.requested.single, '+996700000009');
    expect(find.text(l10n.profile_phone_error_taken), findsOneWidget);
  });

  testWidgets('«Выйти» — подтверждение и SessionController.logout()', (tester) async {
    final TestSession session = TestSession();
    await pumpProfile(tester, FakeProfileRepository(), session: session);
    await tester.tap(find.byKey(ProfileScreen.logoutKey));
    await tester.pumpAndSettle();
    expect(find.text(l10n.profile_logout_confirm), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(ConfirmDialog), matching: find.text(l10n.profile_logout)).last);
    await tester.pumpAndSettle();
    expect(session.logouts, 1);
  });

  testWidgets('офлайн: «Выйти на всех устройствах» и «Сменить номер» недоступны, «Выйти» доступен', (tester) async {
    await pumpProfile(tester, FakeProfileRepository(), session: TestSession(), online: OnlineStatus.offline);
    expect(find.text(l10n.profile_offline_action_disabled), findsNWidgets(2));
    expect(find.byKey(ProfileScreen.logoutKey), findsOneWidget);
  });
}
