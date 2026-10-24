// Widget-тесты диалогов SCR-45: аварийный код входа (RM-D-016, UI-45-023/024, AC-UI-45-018/019),
// приглашения (UI-45-009…011, AC-UI-45-003/010/020), привязки клиентов (UI-45-017/018, AC-UI-45-017),
// резервный StepUpDialog (PIN_INVALID/PIN_LOCKED → OTP, без биометрии).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/session_controller.dart' show stepUpCoordinatorProvider;
import 'package:optomstroy/core/session/step_up_coordinator.dart' as session;
import 'package:optomstroy/core/session/step_up_token_cache.dart' as session_cache;
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/features/admin/admin_providers.dart';
import 'package:optomstroy/features/admin/domain/users/customer_link_case.dart';
import 'package:optomstroy/features/admin/domain/users/invitation.dart';
import 'package:optomstroy/features/admin/domain/users/step_up.dart';
import 'package:optomstroy/features/admin/presentation/users/admin_users_screen.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/admin_step_up_dialog.dart';

import '../support/fake_admin_repository.dart';

final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));

FakeAdminUsersRepository seed({List<CustomerLinkCase> links = const []}) => FakeAdminUsersRepository(
  users: [
    staff(adminId, role: RoleCode.admin, name: 'Гульнара Админова'),
    staff(cashierId, name: 'Иван Петров'),
  ],
  invitations: [
    Invitation(
      id: 'inv-1',
      phoneMasked: '+996 7** *** *05',
      roles: const ['cashier'],
      status: 'pending',
      createdAt: t0,
      expiresAt: t0.add(const Duration(days: 10)),
    ),
    Invitation(id: 'inv-2', phoneMasked: '+996 7** *** *06', roles: const ['seller'], status: 'expired', createdAt: t0),
  ],
  links: links,
);

Finder inDialog(Finder f) => find.descendant(of: find.byType(ConfirmDialog), matching: f);

Future<void> tapKey(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey<String>(key));
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await settle(tester);
}

Future<void> openEmergency(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('admin-user-row-$cashierId')));
  await settle(tester);
  await tapKey(tester, 'admin-user-emergency-code');
}

final class FakeGateway implements StepUpGateway {
  final List<String> calls = [];
  final List<Result<StepUpGrant>> pinResults = [];

  @override
  Future<Result<StepUpGrant>> withPin(String operation, String pin) async {
    calls.add('pin:$operation');
    return pinResults.isEmpty ? const FailureResult(UnknownFailure()) : pinResults.removeAt(0);
  }

  @override
  Future<Result<StepUpOtpChallenge>> requestOtp(String operation) async {
    calls.add('otp-request:$operation');
    return const Success(StepUpOtpChallenge(challengeId: 'ch-1'));
  }

  @override
  Future<Result<StepUpGrant>> withOtp(String operation, {required String challengeId, required String code}) async {
    calls.add('otp:$operation:$challengeId');
    return Success(StepUpGrant(token: 'otp-token', expiresAt: DateTime.utc(2030))); // check-secrets: allow (тест)
  }
}

void main() {
  group('аварийный код входа (RM-D-016)', () {
    testWidgets('причина → StepUpDialog ДО запроса (только PIN) → код показан один раз; после закрытия не '
        'восстанавливается', (tester) async {
      final repo = seed();
      final prompter = FakeStepUpPrompter();
      await pumpAdmin(tester, const AdminUsersScreen(), overrides: adminTestOverrides(repo, prompter: prompter));
      await settle(tester);
      await openEmergency(tester);

      expect(find.text(l10n.admin_users_emergency_title('Иван Петров')), findsOneWidget);
      expect(find.text(l10n.admin_users_emergency_hint), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('emergency-reason-sms_unavailable')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('emergency-issue')));
      await settle(tester);

      // Step-up заранее, только PIN, operation users.emergency_code.issue; запрос — один, уже с токеном.
      expect(prompter.challenges.single.operation, AdminStepUpOperations.emergencyCode);
      expect(prompter.challenges.single.allowedMethods, [StepUpMethod.pin]);
      final calls = repo.callsOf('issueEmergencyCode').toList();
      expect(calls, hasLength(1));
      expect(calls.single.stepUpToken, 'step-up-token');
      expect(calls.single.idempotencyKey, isNull);
      expect(calls.single.args['reason'], 'sms_unavailable');

      expect(find.byKey(const ValueKey<String>('emergency-code-value')), findsOneWidget);
      expect(find.text('482911'), findsOneWidget);
      expect(find.textContaining('+996 7** *** *01'), findsOneWidget);
      // Кнопки копирования нет (UI-45-024).
      expect(find.byIcon(Icons.content_copy_rounded), findsNothing);
      expect(find.byIcon(Icons.content_copy), findsNothing);

      // Закрытие — только с подтверждением.
      await tester.tap(find.byKey(const ValueKey<String>('emergency-close')));
      await settle(tester);
      expect(find.text(l10n.admin_users_emergency_close_confirm), findsOneWidget);
      await tester.tap(inDialog(find.text(l10n.ds_button_close)).last);
      await settle(tester);
      expect(find.text('482911'), findsNothing);

      // Повторное открытие — снова шаг причины, прежний код не показывается.
      await tapKey(tester, 'admin-user-emergency-code');
      expect(find.byKey(const ValueKey<String>('emergency-code-value')), findsNothing);
      expect(find.text('482911'), findsNothing);
      expect(find.byKey(const ValueKey<String>('emergency-issue')), findsOneWidget);
    });

    testWidgets('«Иное» требует комментарий 5…200 символов', (tester) async {
      final repo = seed();
      await pumpAdmin(
        tester,
        const AdminUsersScreen(),
        overrides: adminTestOverrides(repo, prompter: FakeStepUpPrompter()),
      );
      await settle(tester);
      await openEmergency(tester);
      await tester.tap(find.byKey(const ValueKey<String>('emergency-reason-other')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('emergency-issue')));
      await settle(tester);
      expect(repo.callsOf('issueEmergencyCode'), isEmpty);
      await tester.enterText(
        find.descendant(of: find.byKey(const ValueKey<String>('emergency-comment')), matching: find.byType(TextField)),
        'потерял телефон',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('emergency-issue')));
      await settle(tester);
      expect(repo.callsOf('issueEmergencyCode').single.args['comment'], 'потерял телефон');
    });

    testWidgets('отмена StepUpDialog — запрос не отправляется, остаётся шаг причины', (tester) async {
      final repo = seed();
      await pumpAdmin(
        tester,
        const AdminUsersScreen(),
        overrides: adminTestOverrides(repo, prompter: FakeStepUpPrompter(cancel: true)),
      );
      await settle(tester);
      await openEmergency(tester);
      await tester.tap(find.byKey(const ValueKey<String>('emergency-reason-sim_lost')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('emergency-issue')));
      await settle(tester);
      expect(repo.callsOf('issueEmergencyCode'), isEmpty);
      expect(find.byKey(const ValueKey<String>('emergency-issue')), findsOneWidget);
    });

    for (final (name, failure, text) in [
      (
        '429 RATE_LIMITED',
        const ServerFailure(code: 'RATE_LIMITED', status: 429),
        l10n.admin_users_emergency_rate_limited,
      ),
      ('422 VALIDATION_FAILED', const ValidationFailure(), l10n.admin_users_emergency_not_allowed),
      ('403 FORBIDDEN', const PermissionFailure(serverReason: 'privileged_target'), l10n.error_forbidden),
    ]) {
      testWidgets('$name → «$text», код не показан, повтор только явным нажатием', (tester) async {
        final repo = seed()..nextFailure = failure;
        await pumpAdmin(
          tester,
          const AdminUsersScreen(),
          overrides: adminTestOverrides(repo, prompter: FakeStepUpPrompter()),
        );
        await settle(tester);
        await openEmergency(tester);
        await tester.tap(find.byKey(const ValueKey<String>('emergency-reason-sms_unavailable')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey<String>('emergency-issue')));
        await settle(tester);
        expect(find.byKey(const ValueKey<String>('emergency-error')), findsOneWidget);
        expect(find.text(text), findsOneWidget);
        expect(find.byKey(const ValueKey<String>('emergency-code-value')), findsNothing);
        expect(repo.callsOf('issueEmergencyCode'), hasLength(1));
      });
    }

    testWidgets('сворачивание приложения скрывает код и закрывает диалог', (tester) async {
      final repo = seed();
      await pumpAdmin(
        tester,
        const AdminUsersScreen(),
        overrides: adminTestOverrides(repo, prompter: FakeStepUpPrompter()),
      );
      await settle(tester);
      await openEmergency(tester);
      await tester.tap(find.byKey(const ValueKey<String>('emergency-reason-sms_unavailable')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('emergency-issue')));
      await settle(tester);
      expect(find.text('482911'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await settle(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);
      expect(find.text('482911'), findsNothing);
      expect(find.byKey(const ValueKey<String>('emergency-shown')), findsNothing);
    });
  });

  group('приглашения', () {
    testWidgets('форма: подзаголовок, роли без owner/admin; создание со step-up → строка вверху вкладки', (
      tester,
    ) async {
      final repo = seed();
      final prompter = FakeStepUpPrompter();
      await pumpAdmin(tester, const AdminUsersScreen(), overrides: adminTestOverrides(repo, prompter: prompter));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey<String>('admin-invite-button')));
      await settle(tester);

      expect(find.text(l10n.admin_invites_staff_only_hint), findsOneWidget);
      expect(find.text(l10n.admin_invites_no_sms_hint), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('admin-invite-role-seller')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('admin-invite-role-owner')), findsNothing);
      expect(find.byKey(const ValueKey<String>('admin-invite-role-admin')), findsNothing);

      // Пустая форма — ошибки телефона и роли, запроса нет.
      await tapKey(tester, 'admin-invite-submit');
      expect(find.text(l10n.admin_invites_error_phone), findsOneWidget);
      expect(find.text(l10n.admin_invites_error_role), findsOneWidget);
      expect(repo.callsOf('createInvitation'), isEmpty);

      await tester.enterText(
        find.descendant(of: find.byKey(const ValueKey<String>('admin-invite-phone')), matching: find.byType(TextField)),
        '700000007',
      );
      await tester.enterText(
        find.descendant(of: find.byKey(const ValueKey<String>('admin-invite-name')), matching: find.byType(TextField)),
        'Асан Усенов',
      );
      await tapKey(tester, 'admin-invite-role-seller');
      await tapKey(tester, 'admin-invite-submit');

      final calls = repo.callsOf('createInvitation').toList();
      expect(calls, hasLength(2));
      expect(calls[0].stepUpToken, isNull);
      expect(calls[1].stepUpToken, 'step-up-token');
      expect(calls[0].idempotencyKey, calls[1].idempotencyKey);
      expect(calls[1].args['role'], 'seller');
      expect(calls[1].args['fullName'], 'Асан Усенов');
      expect(calls[1].args['expiresAt'], DateTime(2026, 11, 21));
      expect(prompter.challenges.single.operation, AdminStepUpOperations.invitationsManage);
      expect(find.byKey(const ValueKey<String>('admin-invite-form')), findsNothing);
      expect(find.text(l10n.admin_invites_created('+996 7** *** *07')), findsOneWidget);

      // Вкладка «Приглашения»: новая строка первой, статус «Ожидает».
      final rows = tester
          .widgetList<Padding>(find.byWidgetPredicate((w) => w is Padding && '${w.key}'.contains('admin-invitation-')))
          .map((w) => '${w.key}')
          .toList();
      expect(rows.first, contains('inv-${calls[1].idempotencyKey}'));
    });

    testWidgets('двойное нажатие «Отправить» — один ключ идемпотентности (AC-UI-45-010)', (tester) async {
      final repo = seed()..requireStepUp = false;
      await pumpAdmin(tester, const AdminUsersScreen(), overrides: adminTestOverrides(repo));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey<String>('admin-invite-button')));
      await settle(tester);
      await tester.enterText(
        find.descendant(of: find.byKey(const ValueKey<String>('admin-invite-phone')), matching: find.byType(TextField)),
        '700000008',
      );
      await tapKey(tester, 'admin-invite-role-cashier');
      final submit = find.byKey(const ValueKey<String>('admin-invite-submit'));
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.tap(submit, warnIfMissed: false);
      await settle(tester);
      expect(repo.callsOf('createInvitation').map((c) => c.idempotencyKey).toSet(), hasLength(1));
      expect(repo.invitations.where((i) => i.roles.contains('cashier') && i.id != 'inv-1'), hasLength(1));
    });

    testWidgets('409 PHONE_ALREADY_REGISTERED → ошибка под полем телефона, форма открыта', (tester) async {
      final repo = seed()
        ..requireStepUp = false
        ..nextFailure = const ConflictFailure(ConflictKind.phoneAlreadyRegistered);
      await pumpAdmin(tester, const AdminUsersScreen(), overrides: adminTestOverrides(repo));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey<String>('admin-invite-button')));
      await settle(tester);
      await tester.enterText(
        find.descendant(of: find.byKey(const ValueKey<String>('admin-invite-phone')), matching: find.byType(TextField)),
        '700000001',
      );
      await tapKey(tester, 'admin-invite-role-cashier');
      await tapKey(tester, 'admin-invite-submit');
      expect(find.text(l10n.admin_invites_error_registered), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('admin-invite-form')), findsOneWidget);
    });

    testWidgets('«Отозвать» — ConfirmDialog → step-up → статус «Отозвано»; «Пригласить снова» у истёкшего', (
      tester,
    ) async {
      final repo = seed();
      final prompter = FakeStepUpPrompter();
      await pumpAdmin(tester, const AdminUsersScreen(), overrides: adminTestOverrides(repo, prompter: prompter));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey<String>('admin-tab-invitations')));
      await settle(tester);
      expect(find.byKey(const ValueKey<String>('admin-invitation-renew-inv-2')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('admin-invitation-revoke-inv-2')), findsNothing);
      await tester.tap(find.byKey(const ValueKey<String>('admin-invitation-revoke-inv-1')));
      await settle(tester);
      await tester.tap(inDialog(find.text(l10n.admin_invites_revoke)).last);
      await settle(tester);
      expect(repo.callsOf('revokeInvitation').map((c) => c.stepUpToken), [null, 'step-up-token']);
      expect(prompter.challenges.single.operation, AdminStepUpOperations.invitationsManage);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('admin-invitation-inv-1')),
          matching: find.text(l10n.status_invitation_revoked),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey<String>('admin-invitation-revoke-inv-1')), findsNothing);
    });
  });

  group('привязки клиентов (UI-45-017/018)', () {
    const conflictCase = CustomerLinkCase(
      customerId: 'cust-1',
      name: 'ОсОО «Строй»',
      displayName: 'Строй',
      inn: '01234567890123',
      links: [
        CustomerLinkCandidate(
          id: 'l-1',
          customerId: 'cust-1',
          status: 'conflict',
          userDisplayName: 'Асан',
          userPhoneMasked: '+996 7** *** *09',
        ),
        CustomerLinkCandidate(id: 'l-2', customerId: 'cust-1', status: 'conflict', userDisplayName: 'Бакыт'),
      ],
    );

    testWidgets('вкладка видна admin; «Подтвердить» — комментарий → step-up customer.link.resolve', (tester) async {
      final repo = seed(links: [conflictCase]);
      final prompter = FakeStepUpPrompter();
      await pumpAdmin(tester, const AdminUsersScreen(), overrides: adminTestOverrides(repo, prompter: prompter));
      await settle(tester);
      expect(find.text(l10n.admin_users_tab_links(1)), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('admin-tab-links')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey<String>('admin-link-case-cust-1')));
      await settle(tester);
      expect(find.byKey(const ValueKey<String>('admin-link-reject-all')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('admin-link-confirm-l-1')));
      await settle(tester);
      await tester.enterText(inDialog(find.byType(TextField)), 'проверено по ИНН');
      await tester.pump();
      await tester.tap(inDialog(find.text(l10n.admin_links_confirm)).last);
      await settle(tester);
      expect(repo.callsOf('confirmLink').map((c) => c.stepUpToken), [null, 'step-up-token']);
      expect(prompter.challenges.single.operation, AdminStepUpOperations.linkResolve);
      expect(find.byKey(const ValueKey<String>('admin-link-confirm-l-1')), findsNothing);
    });

    testWidgets('409 CUSTOMER_LINK_CONFLICT → баннер «У клиента уже есть подтверждённая привязка»', (tester) async {
      final repo = seed(links: [conflictCase])
        ..requireStepUp = false
        ..nextFailure = const ConflictFailure(ConflictKind.customerLinkConflict);
      await pumpAdmin(tester, const AdminUsersScreen(), overrides: adminTestOverrides(repo));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey<String>('admin-tab-links')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey<String>('admin-link-case-cust-1')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey<String>('admin-link-confirm-l-1')));
      await settle(tester);
      await tester.enterText(inDialog(find.byType(TextField)), 'проверено');
      await tester.pump();
      await tester.tap(inDialog(find.text(l10n.admin_links_confirm)).last);
      await settle(tester);
      expect(find.text(l10n.admin_links_error_conflict), findsOneWidget);
    });

    testWidgets('вкладка скрыта при customerSelfService=false и пустом списке', (tester) async {
      final repo = seed();
      await pumpAdmin(
        tester,
        const AdminUsersScreen(),
        overrides: adminTestOverrides(repo, customerSelfService: false),
      );
      await settle(tester);
      expect(find.byKey(const ValueKey<String>('admin-tab-links')), findsNothing);
    });
  });

  group('резервный StepUpDialog (порт core/session не подключён)', () {
    Future<void> openStepUp(WidgetTester tester, FakeGateway gateway, {Size size = const Size(1280, 800)}) async {
      late BuildContext ctx;
      await pumpAdmin(
        tester,
        Builder(
          builder: (c) {
            ctx = c;
            return const Scaffold();
          },
        ),
        overrides: [adminStepUpGatewayProvider.overrideWithValue(gateway)],
        size: size,
      );
      unawaited(AdminStepUpDialog.show(ctx, const StepUpChallenge(operation: AdminStepUpOperations.rolesAssign)));
      await settle(tester);
    }

    Future<void> typePin(WidgetTester tester, String pin) async {
      for (final d in pin.split('')) {
        await tester.tap(find.text(d).last);
        await tester.pump();
      }
      await settle(tester);
    }

    testWidgets('PIN_INVALID → «осталось попыток» из ответа сервера; биометрии нет', (tester) async {
      final gateway = FakeGateway()
        ..pinResults.add(const FailureResult(AuthFailure(AuthReason.pinInvalid, attemptsLeft: 4)));
      await openStepUp(tester, gateway);
      expect(find.byIcon(Icons.fingerprint), findsNothing);
      await typePin(tester, '482913');
      expect(gateway.calls, ['pin:users.roles.assign']);
      expect(find.text(l10n.auth_pin_error_invalid(4)), findsOneWidget);
    });

    testWidgets('PIN_LOCKED → переход к коду из SMS → токен', (tester) async {
      final gateway = FakeGateway()..pinResults.add(const FailureResult(AuthFailure(AuthReason.pinLocked)));
      await openStepUp(tester, gateway);
      await typePin(tester, '482913');
      expect(find.text(l10n.stepup_pin_locked), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('admin-step-up-sms')));
      await settle(tester);
      expect(gateway.calls.last, 'otp-request:users.roles.assign');
      await tester.enterText(find.byType(TextField).last, '123456');
      await settle(tester);
      expect(gateway.calls.last, 'otp:users.roles.assign:ch-1');
      expect(find.byKey(const ValueKey<String>('admin-step-up')), findsNothing);
    });

    testWidgets('compact — нижний лист', (tester) async {
      final gateway = FakeGateway()..pinResults.add(Success(StepUpGrant(token: 't', expiresAt: DateTime.utc(2030))));
      await openStepUp(tester, gateway, size: const Size(390, 844));
      expect(find.byType(BottomSheet), findsOneWidget);
      await typePin(tester, '482913');
      expect(find.byKey(const ValueKey<String>('admin-step-up')), findsNothing);
    });
  });

  group('StepUpDialog core/session смонтирован (StepUpCoordinator.hasPresenter)', () {
    session.StepUpCoordinator coordinator(List<String> asked, {bool cancel = false}) {
      final c = session.StepUpCoordinator(session_cache.StepUpTokenCache(clock: FixedClock(t0)));
      c.attach((challenge) async {
        asked.add('${challenge.operation}:${challenge.allowedMethods.join(',')}');
        if (cancel) return null;
        return session_cache.StepUpGrant(
          token: 'step-up-token', // check-secrets: allow (тест)
          operation: challenge.operation,
          expiresAt: t0.add(const Duration(minutes: 15)),
          method: 'pin',
        );
      });
      return c;
    }

    testWidgets('аварийный код: подтверждение ДО запроса через core/session (только PIN)', (tester) async {
      final repo = seed();
      final asked = <String>[];
      await pumpAdmin(
        tester,
        const AdminUsersScreen(),
        overrides: [...adminTestOverrides(repo), stepUpCoordinatorProvider.overrideWithValue(coordinator(asked))],
      );
      await settle(tester);
      await openEmergency(tester);
      await tester.tap(find.byKey(const ValueKey<String>('emergency-reason-sms_unavailable')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('emergency-issue')));
      await settle(tester);
      expect(asked, ['users.emergency_code.issue:pin']);
      expect(repo.callsOf('issueEmergencyCode').single.stepUpToken, 'step-up-token');
      expect(find.byKey(const ValueKey<String>('emergency-code-value')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('admin-step-up')), findsNothing);
    });

    testWidgets('403 после диалога AuthInterceptor — второго диалога нет (действие отменено)', (tester) async {
      final repo = seed();
      final asked = <String>[];
      await pumpAdmin(
        tester,
        const AdminUsersScreen(),
        overrides: [...adminTestOverrides(repo), stepUpCoordinatorProvider.overrideWithValue(coordinator(asked))],
      );
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey<String>('admin-user-row-$cashierId')));
      await settle(tester);
      await tapKey(tester, 'admin-user-reset-pin');
      await tester.enterText(inDialog(find.byType(TextField)), 'сотрудник забыл PIN');
      await tester.pump();
      await tester.tap(inDialog(find.text(l10n.admin_users_reset_pin)).last);
      await settle(tester);
      expect(repo.callsOf('resetPin'), hasLength(1));
      expect(asked, isEmpty);
      expect(find.byKey(const ValueKey<String>('admin-step-up')), findsNothing);
      expect(find.text(l10n.admin_users_pin_reset), findsNothing);
    });
  });

  test('ProviderScope-переопределение порта core/session принимается провайдером', () {
    final container = ProviderContainer(
      overrides: [adminStepUpPrompterProvider.overrideWithValue((context, challenge) async => null)],
    );
    addTearDown(container.dispose);
    expect(container.read(adminStepUpPrompterProvider), isNotNull);
  });
}
