// FIX-EF-10 / E-flutter-data-6 (04 FLOW-002.A3, FLOW-009.E1; 07 §11.4): на SCR-01 — предупреждение о неотправленных
// изменениях прежнего сотрудника (`auth_pending_changes_other_user`), источник — файл БД пользователя, ушедшего
// на SCR-01 с SCR-08 (токены и `sub` сохранены до нового входа).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/session/session_local_data.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/core/session/session_status.dart';
import 'package:optomstroy/features/auth/auth_providers.dart';
import 'package:optomstroy/features/auth/data/auth_bindings.dart' show pendingChangesNotice;
import 'package:optomstroy/features/auth/domain/entities/session_profile.dart';
import 'package:optomstroy/features/auth/presentation/screens/phone_screen.dart';

import '../support/fakes.dart';

final class _Session extends SessionController {
  _Session(this._state, this._pending);

  final SessionState _state;
  final PendingLocalChanges _pending;

  @override
  SessionState build() => _state;

  @override
  Future<PendingLocalChanges> pendingLocalChanges() async => _pending;
}

void main() {
  late AppLocalizations l10n;

  setUpAll(() async => l10n = await ru());

  testWidgets('SCR-01: предупреждение с именем прежнего сотрудника; без изменений — нет баннера', (tester) async {
    final AuthHarness h = AuthHarness(
      extraOverrides: <Override>[
        authPendingChangesNoticeProvider.overrideWith((ref) async => const PendingChangesNotice(ownerName: 'Иван')),
      ],
    );
    await h.pump(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(PhoneScreen.pendingChangesKey), findsOneWidget);
    expect(find.text(l10n.auth_pending_changes_other_user('Иван')), findsOneWidget);
  });

  testWidgets('SCR-01: без предупреждения (по умолчанию — нет привязки)', (tester) async {
    final AuthHarness h = AuthHarness();
    await h.pump(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(PhoneScreen.pendingChangesKey), findsNothing);
  });

  group('источник предупреждения (auth_bindings)', () {
    Future<PendingChangesNotice?> run(SessionState state, PendingLocalChanges pending, {String? name}) async {
      final FakeAuthRepository repo = FakeAuthRepository()
        ..profile = SessionProfile(kind: UserKind.staff, roles: const <RoleCode>[RoleCode.cashier], displayName: name);
      final ProviderContainer c = ProviderContainer(
        overrides: <Override>[
          sessionControllerProvider.overrideWith(() => _Session(state, pending)),
          authRepositoryProvider.overrideWithValue(repo),
          authPendingChangesNoticeProvider.overrideWith(pendingChangesNotice),
        ],
      );
      addTearDown(c.dispose);
      final sub = c.listen(authPendingChangesNoticeProvider, (_, _) {});
      addTearDown(sub.close);
      return c.read(authPendingChangesNoticeProvider.future);
    }

    const SessionState leftToPhone = SessionState(
      status: SessionStatus.unauthenticated,
      endReason: SessionEndReason.phoneLogin,
      userKind: UserKind.staff,
      userId: '0192d1c3-0000-7000-8000-000000000001',
    );

    test('ушёл на SCR-01 с SCR-08, в корзине неотправленное → имя из кэша профиля', () async {
      final notice = await run(leftToPhone, const PendingLocalChanges(cartItems: 2), name: 'Иван Петров');
      expect(notice?.ownerName, 'Иван Петров');
      expect(notice.toString(), isNot(contains('Иван')));
    });

    test('имени нет → предупреждение без имени', () async {
      final notice = await run(leftToPhone, const PendingLocalChanges(outboxActions: 1));
      expect(notice, isNotNull);
      expect(notice!.ownerName, isNull);
    });

    test('изменений нет / вошёл / выход без sub — предупреждения нет', () async {
      expect(await run(leftToPhone, PendingLocalChanges.none, name: 'Иван'), isNull);
      expect(
        await run(
          const SessionState(status: SessionStatus.authenticated, userId: 'u'),
          const PendingLocalChanges(cartItems: 1),
          name: 'Иван',
        ),
        isNull,
      );
      expect(
        await run(
          const SessionState(status: SessionStatus.unauthenticated, endReason: SessionEndReason.logout),
          const PendingLocalChanges(cartItems: 1),
        ),
        isNull,
      );
    });
  });
}
