// UI-10-033 / SCR-10.4.A: меню профиля шапки SCR-10 — пункт «Выйти» → ConfirmDialog «Выйти из аккаунта?»
// (фокус на «Отмена») → `POST /auth/logout` через `SessionController.logout()`; при неотправленных изменениях —
// предупреждение FLOW-009.E1 («В корзине есть неотправленные изменения», «Выйти всё равно»).
import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/session/session_local_data.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/top_app_bar_pos.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_screen.dart';

import 'support/catalog_fakes.dart';

/// Счётчик вызовов `logout()` фейка.
final class _Calls {
  int logout = 0;
}

final class _FakeSession extends SessionController {
  _FakeSession(this._pending, this._calls);

  final PendingLocalChanges _pending;
  final _Calls _calls;

  @override
  SessionState build() => SessionState.initial;

  @override
  Future<PendingLocalChanges> pendingLocalChanges() async => _pending;

  @override
  Future<void> logout() async => _calls.logout++;
}

Future<_Calls> _openLogout(WidgetTester tester, PendingLocalChanges pending) async {
  final _Calls calls = _Calls();
  final _FakeSession session = _FakeSession(pending, calls);
  setWindow(tester, kExpanded);
  await tester.pumpWidget(
    catalogApp(
      CatalogHarness(extra: [sessionControllerProvider.overrideWith(() => session)]),
      home: const CatalogScreen(),
    ),
  );
  await settle(tester);
  await tester.tap(find.byType(TopAppBarUser));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey<String>('profile-menu-logout')));
  await tester.pumpAndSettle();
  return calls;
}

void main() {
  testWidgets('«Выйти» → ConfirmDialog, фокус на «Отмена»; «Отмена» — без выхода', (tester) async {
    final _Calls session = await _openLogout(tester, PendingLocalChanges.none);
    expect(find.text('Выйти из аккаунта?'), findsOneWidget);
    final Finder focused = find.byWidgetPredicate((Widget w) => w is AppButton && w.autofocus);
    expect(focused, findsOneWidget);
    expect(tester.widget<AppButton>(focused).label, 'Отмена');

    await tester.tap(focused);
    await tester.pumpAndSettle();
    expect(session.logout, 0);
  });

  testWidgets('подтверждение — SessionController.logout()', (tester) async {
    final _Calls session = await _openLogout(tester, PendingLocalChanges.none);
    await tester.tap(find.widgetWithText(AppButton, 'Выйти'));
    await tester.pumpAndSettle();
    expect(session.logout, 1);
  });

  testWidgets('неотправленные изменения — предупреждение FLOW-009.E1 и «Выйти всё равно»', (tester) async {
    final _Calls session = await _openLogout(tester, const PendingLocalChanges(cartItems: 2));
    expect(find.text('В корзине есть неотправленные изменения'), findsOneWidget);
    await tester.tap(find.widgetWithText(AppButton, 'Выйти всё равно'));
    await tester.pumpAndSettle();
    expect(session.logout, 1);
  });
}
