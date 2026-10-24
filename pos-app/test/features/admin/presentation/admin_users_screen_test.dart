// Widget-тесты SCR-45: режимы admin/owner (ядро §21 п.3, AC-UI-45-009), step-up для критических
// действий (RM-D-010 п.1, AC-UI-45-005), ошибки 403/409 (AC-UI-45-006, AC-UI-45-011), compact.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/features/admin/domain/users/admin_viewer.dart';
import 'package:optomstroy/features/admin/domain/users/invitation.dart';
import 'package:optomstroy/features/admin/domain/users/step_up.dart';
import 'package:optomstroy/features/admin/presentation/users/admin_users_screen.dart';

import '../support/fake_admin_repository.dart';

final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));

FakeAdminUsersRepository seed({AdminViewer me = adminViewer}) => FakeAdminUsersRepository(
  me: me,
  users: [
    staff(adminId, role: RoleCode.admin, name: 'Гульнара Админова', phone: '+996700000010'),
    staff(cashierId, name: 'Иван Петров', phone: '+996700000001'),
    staff(otherAdminId, role: RoleCode.admin, name: 'Бакыт Асанов', phone: '+996700000002'),
    staff(ownerId, role: RoleCode.owner, name: 'Нурлан Руководитель', phone: '+996700000003'),
  ],
  invitations: [
    Invitation(
      id: 'inv-1',
      phoneMasked: '+996 7** *** *07',
      roles: const ['seller'],
      status: 'pending',
      createdByName: 'Г. А.',
      createdAt: t0,
      expiresAt: t0.add(const Duration(days: 30)),
    ),
  ],
);

Finder inDialog(Finder f) => find.descendant(of: find.byType(ConfirmDialog), matching: f);

Future<void> openCard(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(ValueKey<String>('admin-user-row-$id')));
  await settle(tester);
}

/// Прокрутить к элементу карточки и нажать.
Future<void> tapKey(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey<String>(key));
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await settle(tester);
}

Future<void> confirmWithReason(WidgetTester tester, String cta, {String reason = 'перевод на старшего'}) async {
  await tester.enterText(inDialog(find.byType(TextField)), reason);
  await tester.pump();
  // Заголовок диалога может совпадать с CTA — кнопка последняя.
  await tester.tap(inDialog(find.text(cta)).last);
  await settle(tester);
}

void main() {
  group('режим admin (expanded)', () {
    testWidgets('список, вкладки, карточка со всеми действиями; owner-радио недоступно', (tester) async {
      final repo = seed();
      await pumpAdmin(tester, const AdminUsersScreen(), overrides: adminTestOverrides(repo));
      await settle(tester);

      expect(find.text(l10n.admin_users_tab_users(4)), findsOneWidget);
      expect(find.text(l10n.admin_users_tab_invitations(1)), findsOneWidget);
      expect(find.text(l10n.admin_users_tab_links(0)), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('admin-invite-button')), findsOneWidget);
      expect(find.text('Иван Петров'), findsOneWidget);

      await openCard(tester, cashierId);
      expect(find.byKey(const ValueKey<String>('admin-user-reset-pin')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('admin-user-emergency-code')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('admin-user-block')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('admin-user-logout-all')), findsOneWidget);
      // Полный телефон для admin (UI-45-004).
      expect(find.text('+996 700 000 001'), findsWidgets);
      // SEC-040: admin не назначает owner.
      final ownerRadio = tester.widget<Semantics>(
        find.descendant(of: find.byKey(const ValueKey<String>('role-owner')), matching: find.byType(Semantics)).first,
      );
      expect(ownerRadio.properties.enabled, isFalse);
    });

    testWidgets('смена роли: причина → 403 STEP_UP_REQUIRED → StepUpDialog → повтор тем же ключом', (tester) async {
      final repo = seed();
      final prompter = FakeStepUpPrompter();
      await pumpAdmin(tester, const AdminUsersScreen(), overrides: adminTestOverrides(repo, prompter: prompter));
      await settle(tester);
      await openCard(tester, cashierId);

      await tapKey(tester, 'role-senior_seller');
      await tapKey(tester, 'admin-user-save-role');
      // Диалог с diff «было → стало» и обязательной причиной.
      expect(
        find.textContaining(l10n.admin_users_role_diff('Иван Петров', l10n.role_senior_seller, l10n.role_cashier)),
        findsOneWidget,
      );
      await confirmWithReason(tester, l10n.admin_users_role_save);

      final calls = repo.callsOf('setRoles').toList();
      expect(calls, hasLength(2));
      expect(calls[0].stepUpToken, isNull);
      expect(calls[1].stepUpToken, 'step-up-token');
      expect(calls[0].idempotencyKey, calls[1].idempotencyKey);
      expect(calls[1].args['roles'], ['senior_seller']);
      expect(calls[1].args['reason'], 'перевод на старшего');
      expect(prompter.challenges.single.operation, AdminStepUpOperations.rolesAssign);
      expect(find.text(l10n.admin_users_role_saved), findsOneWidget);
      expect(find.byType(ConfirmDialog), findsNothing);
    });

    testWidgets('причина < 5 символов не позволяет подтвердить (UI-45-015)', (tester) async {
      final repo = seed();
      await pumpAdmin(
        tester,
        const AdminUsersScreen(),
        overrides: adminTestOverrides(repo, prompter: FakeStepUpPrompter()),
      );
      await settle(tester);
      await openCard(tester, cashierId);
      await tapKey(tester, 'role-seller');
      await tapKey(tester, 'admin-user-save-role');
      await confirmWithReason(tester, l10n.admin_users_role_save, reason: 'abc');
      expect(repo.callsOf('setRoles'), isEmpty);
      expect(find.byType(ConfirmDialog), findsOneWidget);
    });

    testWidgets('отмена StepUpDialog — повторного запроса нет, роль не меняется', (tester) async {
      final repo = seed();
      final prompter = FakeStepUpPrompter(cancel: true);
      await pumpAdmin(tester, const AdminUsersScreen(), overrides: adminTestOverrides(repo, prompter: prompter));
      await settle(tester);
      await openCard(tester, cashierId);
      await tapKey(tester, 'admin-user-block');
      expect(find.textContaining(l10n.admin_users_block_confirm('Иван Петров')), findsOneWidget);
      await confirmWithReason(tester, l10n.admin_users_block, reason: 'увольнение');
      expect(repo.callsOf('setBlocked'), hasLength(1));
      expect(prompter.challenges.single.operation, AdminStepUpOperations.usersManage);
      expect(repo.users.firstWhere((u) => u.id == cashierId).status, 'active');
    });

    testWidgets('блокировка со step-up → статус «Заблокирован»', (tester) async {
      final repo = seed();
      await pumpAdmin(
        tester,
        const AdminUsersScreen(),
        overrides: adminTestOverrides(repo, prompter: FakeStepUpPrompter()),
      );
      await settle(tester);
      await openCard(tester, cashierId);
      await tapKey(tester, 'admin-user-block');
      await confirmWithReason(tester, l10n.admin_users_block, reason: 'увольнение');
      expect(repo.callsOf('setBlocked').last.args, {'blocked': true, 'reason': 'увольнение'});
      expect(find.text(l10n.status_user_blocked), findsWidgets);
      expect(find.text(l10n.admin_users_unblock), findsOneWidget);
    });

    testWidgets('сброс PIN и завершение сессий — step-up, снекбары', (tester) async {
      final repo = seed();
      final prompter = FakeStepUpPrompter();
      await pumpAdmin(tester, const AdminUsersScreen(), overrides: adminTestOverrides(repo, prompter: prompter));
      await settle(tester);
      await openCard(tester, cashierId);

      await tapKey(tester, 'admin-user-reset-pin');
      expect(find.text(l10n.admin_users_reset_pin_confirm), findsOneWidget);
      await confirmWithReason(tester, l10n.admin_users_reset_pin, reason: 'сотрудник забыл PIN');
      expect(repo.callsOf('resetPin').last.stepUpToken, 'step-up-token');
      expect(find.text(l10n.admin_users_pin_reset), findsOneWidget);

      await tapKey(tester, 'admin-user-logout-all');
      await confirmWithReason(tester, l10n.admin_users_revoke_sessions, reason: 'утерян телефон');
      expect(repo.callsOf('logoutAll').last.stepUpToken, 'step-up-token');
      expect(find.text(l10n.admin_users_sessions_revoked), findsOneWidget);
      expect(find.textContaining(l10n.admin_users_devices(0, '').split('·').first.trim()), findsWidgets);
      expect(prompter.challenges.map((c) => c.operation), [
        AdminStepUpOperations.pinReset,
        AdminStepUpOperations.sessionRevokeAny,
      ]);
    });

    testWidgets('своя учётная запись: роли недоступны, «Сбросить PIN»/«Заблокировать» disabled, аварийного кода нет '
        '(AC-UI-45-006а, AC-UI-45-008)', (tester) async {
      final repo = seed();
      await pumpAdmin(tester, const AdminUsersScreen(), overrides: adminTestOverrides(repo));
      await settle(tester);
      await openCard(tester, adminId);
      expect(find.text(l10n.admin_users_error_self_demotion), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('admin-user-save-role')), findsNothing);
      expect(find.byKey(const ValueKey<String>('admin-user-emergency-code')), findsNothing);
      for (final key in ['admin-user-reset-pin', 'admin-user-block', 'admin-user-logout-all']) {
        final button = tester.widget<Semantics>(
          find.descendant(of: find.byKey(ValueKey<String>(key)), matching: find.byType(Semantics)).first,
        );
        expect(button.properties.enabled, isNot(true), reason: key);
      }
    });

    testWidgets('403 FORBIDDEN (owner_role_reserved) — подсказка SEC-040, данные не меняются', (tester) async {
      final repo = seed()..nextFailure = const PermissionFailure(serverReason: 'owner_role_reserved');
      await pumpAdmin(
        tester,
        const AdminUsersScreen(),
        overrides: adminTestOverrides(repo, prompter: FakeStepUpPrompter()),
      );
      await settle(tester);
      await openCard(tester, cashierId);
      await tapKey(tester, 'role-admin');
      await tapKey(tester, 'admin-user-save-role');
      await confirmWithReason(tester, l10n.admin_users_role_save);
      expect(find.text(l10n.admin_users_owner_hint), findsWidgets);
      expect(repo.users.firstWhere((u) => u.id == cashierId).roles, ['cashier']);
    });

    testWidgets('403 FORBIDDEN без причины → error_forbidden', (tester) async {
      final repo = seed()..nextFailure = const PermissionFailure();
      await pumpAdmin(
        tester,
        const AdminUsersScreen(),
        overrides: adminTestOverrides(repo, prompter: FakeStepUpPrompter()),
      );
      await settle(tester);
      await openCard(tester, cashierId);
      await tapKey(tester, 'admin-user-reset-pin');
      await confirmWithReason(tester, l10n.admin_users_reset_pin, reason: 'сотрудник забыл PIN');
      expect(find.text(l10n.error_forbidden), findsOneWidget);
    });

    testWidgets('409 VERSION_CONFLICT → баннер «изменено другим администратором», «Повторить» перечитывает карточку '
        '(AC-UI-45-011)', (tester) async {
      final repo = seed()..nextFailure = const ConflictFailure(ConflictKind.versionConflict);
      await pumpAdmin(
        tester,
        const AdminUsersScreen(),
        overrides: adminTestOverrides(repo, prompter: FakeStepUpPrompter()),
      );
      await settle(tester);
      await openCard(tester, cashierId);
      final readsBefore = repo.callsOf('getUser').length;
      await tapKey(tester, 'role-seller');
      await tapKey(tester, 'admin-user-save-role');
      await confirmWithReason(tester, l10n.admin_users_role_save);
      expect(find.text(l10n.admin_users_conflict_banner), findsWidgets);
      // Список не потерян.
      expect(find.byKey(const ValueKey<String>('admin-user-row-$otherAdminId')), findsOneWidget);
      await tester.ensureVisible(find.text(l10n.ds_button_retry));
      await tester.pump();
      await tester.tap(find.text(l10n.ds_button_retry));
      await settle(tester);
      expect(repo.callsOf('getUser').length, readsBefore + 1);
      expect(find.text(l10n.admin_users_conflict_banner), findsNothing);
      expect(find.byKey(const ValueKey<String>('admin-user-card-$cashierId')), findsOneWidget);
    });

    testWidgets('сеть недоступна при действии — диалог остаётся с «Повторить», повтор тем же ключом', (tester) async {
      final repo = seed()..requireStepUp = false;
      repo.nextFailure = const NetworkFailure(NetworkFailureKind.offline);
      await pumpAdmin(
        tester,
        const AdminUsersScreen(),
        overrides: adminTestOverrides(repo, prompter: FakeStepUpPrompter()),
      );
      await settle(tester);
      await openCard(tester, cashierId);
      await tapKey(tester, 'admin-user-logout-all');
      await confirmWithReason(tester, l10n.admin_users_revoke_sessions, reason: 'утерян телефон');
      expect(find.byType(ConfirmDialog), findsOneWidget);
      expect(find.text(l10n.auth_error_network), findsOneWidget);
      await tester.tap(inDialog(find.text(l10n.ds_button_retry)));
      await settle(tester);
      final calls = repo.callsOf('logoutAll').toList();
      expect(calls, hasLength(2));
      expect(calls[0].idempotencyKey, calls[1].idempotencyKey);
      expect(find.byType(ConfirmDialog), findsNothing);
    });
  });

  group('режим owner (ядро §21 п.3, AC-UI-45-009)', () {
    testWidgets('просмотр: нет «Пригласить», вкладки «Привязки», меню приглашений; маска телефона', (tester) async {
      final repo = seed(me: ownerViewer);
      await pumpAdmin(tester, const AdminUsersScreen(), overrides: adminTestOverrides(repo));
      await settle(tester);
      expect(find.byKey(const ValueKey<String>('admin-invite-button')), findsNothing);
      expect(find.byKey(const ValueKey<String>('admin-tab-links')), findsNothing);
      expect(repo.callsOf('listLinkCases'), isEmpty);

      await tester.tap(find.byKey(const ValueKey<String>('admin-tab-invitations')));
      await settle(tester);
      expect(find.byKey(const ValueKey<String>('admin-invitation-inv-1')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('admin-invitation-revoke-inv-1')), findsNothing);
    });

    testWidgets(
      'карточка кассира: нет сброса PIN, блокировки, аварийного кода, logout-all; роли — только admin/owner',
      (tester) async {
        final repo = seed(me: ownerViewer);
        await pumpAdmin(tester, const AdminUsersScreen(), overrides: adminTestOverrides(repo));
        await settle(tester);
        await openCard(tester, cashierId);
        for (final key in [
          'admin-user-reset-pin',
          'admin-user-block',
          'admin-user-emergency-code',
          'admin-user-logout-all',
        ]) {
          expect(find.byKey(ValueKey<String>(key)), findsNothing, reason: key);
        }
        bool enabled(String role) => tester
            .widget<Semantics>(
              find.descendant(of: find.byKey(ValueKey<String>('role-$role')), matching: find.byType(Semantics)).first,
            )
            .properties
            .enabled!;
        expect(enabled('admin'), isTrue);
        expect(enabled('owner'), isTrue);
        expect(enabled('seller'), isFalse);
        expect(enabled('senior_seller'), isFalse);
      },
    );

    testWidgets('назначение роли admin вызывает StepUpDialog (RM-D-014 п.7)', (tester) async {
      final repo = seed(me: ownerViewer);
      final prompter = FakeStepUpPrompter();
      await pumpAdmin(tester, const AdminUsersScreen(), overrides: adminTestOverrides(repo, prompter: prompter));
      await settle(tester);
      await openCard(tester, cashierId);
      await tapKey(tester, 'role-admin');
      await tapKey(tester, 'admin-user-save-role');
      await confirmWithReason(tester, l10n.admin_users_role_save, reason: 'назначение администратором');
      expect(prompter.challenges.single.operation, AdminStepUpOperations.rolesAssign);
      expect(repo.callsOf('setRoles').last.args['roles'], ['admin']);
      expect(find.text(l10n.admin_users_role_saved), findsOneWidget);
    });

    testWidgets('logout-all учётной записи admin — доступен со step-up', (tester) async {
      final repo = seed(me: ownerViewer);
      final prompter = FakeStepUpPrompter();
      await pumpAdmin(tester, const AdminUsersScreen(), overrides: adminTestOverrides(repo, prompter: prompter));
      await settle(tester);
      await openCard(tester, otherAdminId);
      await tapKey(tester, 'admin-user-logout-all');
      await confirmWithReason(tester, l10n.admin_users_revoke_sessions, reason: 'смена устройства');
      expect(prompter.challenges.single.operation, AdminStepUpOperations.sessionRevokeAny);
      expect(repo.callsOf('logoutAll').last.id, otherAdminId);
    });
  });

  group('доступ и состояния', () {
    testWidgets('роль без users.read → экран «Недостаточно прав», запросов списков нет', (tester) async {
      final repo = seed(
        me: const AdminViewer(userId: cashierId, roles: [RoleCode.cashier]),
      );
      await pumpAdmin(tester, const AdminUsersScreen(), overrides: adminTestOverrides(repo));
      await settle(tester);
      expect(find.text(l10n.error_forbidden), findsOneWidget);
      expect(repo.callsOf('listUsers'), isEmpty);
    });

    testWidgets('офлайн при загрузке — offlineNoCache с «Повторить» (данные не кэшируются)', (tester) async {
      final repo = seed()..viewerFailure = const NetworkFailure(NetworkFailureKind.offline);
      await pumpAdmin(tester, const AdminUsersScreen(), overrides: adminTestOverrides(repo));
      await settle(tester);
      expect(find.text(l10n.auth_error_network), findsOneWidget);
      repo.viewerFailure = null;
      await tester.tap(find.text(l10n.ds_button_retry));
      await settle(tester);
      expect(find.text('Иван Петров'), findsOneWidget);
    });

    testWidgets('фильтр «Заблокирован» передаётся в запрос (AC-UI-45-002)', (tester) async {
      final repo = seed();
      repo.users.add(staff('blk', status: 'blocked', name: 'Заблокированный Сотрудник'));
      await pumpAdmin(tester, const AdminUsersScreen(), overrides: adminTestOverrides(repo));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey<String>('admin-users-filter-status')));
      await settle(tester);
      await tester.tap(find.widgetWithText(MenuItemButton, l10n.status_user_blocked));
      await settle(tester);
      expect(repo.callsOf('listUsers').last.args['status'], 'blocked');
      expect(find.text('Заблокированный Сотрудник'), findsOneWidget);
      expect(find.text('Иван Петров'), findsNothing);
    });

    testWidgets('поиск по части телефона «700 000» с debounce 300 мс', (tester) async {
      final repo = seed();
      await pumpAdmin(tester, const AdminUsersScreen(), overrides: adminTestOverrides(repo));
      await settle(tester);
      final before = repo.callsOf('listUsers').length;
      await tester.enterText(
        find.descendant(of: find.byKey(const ValueKey<String>('admin-users-search')), matching: find.byType(TextField)),
        '000 001',
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(repo.callsOf('listUsers').length, before);
      await tester.pump(const Duration(milliseconds: 300));
      await settle(tester);
      expect(repo.callsOf('listUsers').length, before + 1);
      expect(find.text('Иван Петров'), findsOneWidget);
      expect(find.text('Бакыт Асанов'), findsNothing);
    });

    testWidgets('compact: карточка — отдельный экран, FAB «+ Пригласить»', (tester) async {
      final repo = seed();
      await pumpAdmin(
        tester,
        const AdminUsersScreen(),
        overrides: adminTestOverrides(repo),
        size: const Size(390, 844),
      );
      await settle(tester);
      expect(find.byKey(const ValueKey<String>('admin-invite-fab')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('admin-invite-button')), findsNothing);
      await openCard(tester, cashierId);
      expect(find.byKey(const ValueKey<String>('admin-user-card-$cashierId')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('admin-users-list')), findsNothing);
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await settle(tester);
      expect(find.byKey(const ValueKey<String>('admin-users-list')), findsOneWidget);
    });

    testWidgets('?userId= восстанавливает карточку (02 SCR-45.11)', (tester) async {
      final repo = seed();
      await pumpAdmin(tester, const AdminUsersScreen(initialUserId: cashierId), overrides: adminTestOverrides(repo));
      await settle(tester);
      expect(find.byKey(const ValueKey<String>('admin-user-card-$cashierId')), findsOneWidget);
    });
  });
}
