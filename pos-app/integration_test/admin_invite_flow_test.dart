// RM-D-010 п. 3 (13 §3.4; ядро §24.2; RM-D-017): сквозной путь «администратор создаёт приглашение в UI →
// приглашённый входит по OTP → устанавливает PIN» на Windows против локального тестового контура.
//
//   1. admin (`AUTH_FIXTURES.admin`, без PIN): Splash → SCR-01 → SCR-02 → SCR-04 «первый вход сотрудника» (PIN) →
//      главный экран режима; SCR-45 `/admin/users` → «Пригласить» (телефон, ФИО, роль «Кассир») → StepUpDialog
//      (PIN администратора) → приглашение во вкладке «Приглашения»;
//   2. выход через SCR-42 «Устройства и сессии» → «Выйти» (текущая сессия) → SCR-01;
//   3. приглашённый (`AUTH_FIXTURES.invitedByAdmin`): SCR-01 → SCR-02 → SCR-04 без формы SCR-03 → PIN (6 цифр) →
//      «Готово» → главный экран кассира `/cashier`.
//
// Код подтверждения — тестовый режим OTP 09 §5.8 (только dev): номера и код задаёт `pos-api/scripts/local-stack.mjs`
// (`AUTH_FIXTURES`), SMS не отправляется. Запуск — на свежем стеке (приглашение и PIN создаются один раз):
//
//   cd pos-api && npm run build
//   LOCAL_STACK_MIN_APP_VERSION=android=0.1.0,windows=0.1.0 node scripts/local-stack.mjs serve --auth-fixtures
//   cd pos-app && flutter test integration_test/admin_invite_flow_test.dart -d windows --dart-define-from-file=env/dev.json --dart-define-from-file=env/local.json
//
// Значения по умолчанию совпадают с `AUTH_FIXTURES`; переопределяются `--dart-define=E2E_*`. Номера синтетические
// (+99677700090N); телефоны и код в лог не выводятся (11 SEC-062).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:optomstroy/app/bootstrap.dart';
import 'package:optomstroy/core/config/app_data_directory.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/pin_field.dart';
import 'package:optomstroy/features/auth/presentation/screens/no_session_screen.dart';
import 'package:optomstroy/features/auth/presentation/screens/otp_screen.dart';
import 'package:optomstroy/features/auth/presentation/screens/phone_screen.dart';
import 'package:optomstroy/features/registration/presentation/screens/registration_form_screen.dart';
import 'package:optomstroy/features/registration/presentation/screens/registration_security_screen.dart';
import 'package:optomstroy/features/settings/presentation/widgets/sessions_section.dart';
import 'package:optomstroy/features/splash/presentation/screens/splash_screen.dart';

/// Тестовый код OTP контура (`AUTH_FIXTURES.otpCode`).
const String _otpCode = String.fromEnvironment('E2E_OTP_CODE', defaultValue: '246810');

/// Национальные номера (9 цифр) из `AUTH_FIXTURES`: администратор без PIN и номер для приглашения.
const String _adminPhone = String.fromEnvironment('E2E_ADMIN_PHONE', defaultValue: '777000901');
const String _invitedPhone = String.fromEnvironment('E2E_INVITED_PHONE', defaultValue: '777000904');

const String _adminPin = '604817';
const String _cashierPin = '739258';
const String _invitedName = 'Тестов Кассир';

final AppLocalizations _l10n = lookupAppLocalizations(const Locale('ru'));

Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      fail('не дождались ${finder.describeMatch(Plurality.one)} за ${timeout.inSeconds} с; экран: ${_where(tester)}');
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> pumpUntil(WidgetTester tester, bool Function() done, String what, {int seconds = 30}) async {
  final DateTime deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('не дождались: $what; экран: ${_where(tester)}');
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

GoRouter? _router(WidgetTester tester) {
  final Iterable<Element> nav = find.byType(Navigator).evaluate();
  return nav.isEmpty ? null : GoRouter.maybeOf(nav.first);
}

String _where(WidgetTester tester) => _router(tester)?.routerDelegate.currentConfiguration.uri.toString() ?? '—';

Finder _input(Key key) => find.descendant(of: find.byKey(key), matching: find.byType(EditableText));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

/// PIN цифрами нампада последнего `PinField` на экране (SCR-04 / StepUpDialog).
Future<void> _enterPin(WidgetTester tester, String pin) async {
  for (final String d in pin.split('')) {
    final Finder label = find.descendant(of: find.byType(PinField).last, matching: find.text(d));
    final Finder key = find.ancestor(of: label.last, matching: find.byType(AnimatedContainer)).first;
    await Scrollable.ensureVisible(tester.element(key), alignment: 0.5);
    await tester.pump();
    await tester.tap(key);
    await tester.pump(const Duration(milliseconds: 80));
  }
  await _settle(tester);
}

Future<void> _phoneAndOtp(WidgetTester tester, String nationalPhone) async {
  await pumpUntilFound(tester, find.byKey(PhoneScreen.fieldKey));
  await tester.enterText(_input(PhoneScreen.fieldKey), nationalPhone);
  await tester.pump();
  await _tap(tester, find.byKey(PhoneScreen.submitKey));
  await pumpUntilFound(tester, find.byKey(OtpScreen.screenKey));
  await tester.enterText(
    find.descendant(of: find.byKey(OtpScreen.screenKey), matching: find.byType(EditableText)),
    _otpCode,
  );
  await tester.pump();
}

/// SCR-04 «первый вход сотрудника»: PIN 6 цифр дважды → отметка ознакомления → «Завершить».
Future<void> _staffFirstPin(WidgetTester tester, String pin) async {
  await pumpUntilFound(tester, find.byKey(RegistrationSecurityScreen.screenKey));
  expect(find.byKey(RegistrationFormScreen.screenKey), findsNothing, reason: 'сотрудник не заполняет SCR-03');
  await pumpUntilFound(tester, find.byType(PinField));
  await _settle(tester);
  expect(tester.widget<PinField>(find.byType(PinField).first).length, 6);
  await _enterPin(tester, pin);
  await _enterPin(tester, pin);
  if (find.byKey(RegistrationSecurityScreen.pdAckKey).evaluate().isNotEmpty) {
    await _tap(tester, find.byKey(RegistrationSecurityScreen.pdAckKey));
  }
  await pumpUntilFound(
    tester,
    find.byWidgetPredicate(
      (Widget w) => w is AppButton && w.key == RegistrationSecurityScreen.completeKey && w.onPressed != null,
    ),
    timeout: const Duration(seconds: 10),
  );
  await _tap(tester, find.byKey(RegistrationSecurityScreen.completeKey));
  await pumpUntilFound(tester, find.byKey(RegistrationSecurityScreen.doneKey));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Данные приложения — в APP_DATA_DIR из env/local.json (машина разработки, вне git; не %APPDATA% на C:), до
  // первого обращения к ним. Без APP_DATA_DIR — каталог ОС.
  AppDataDirectory.apply(AppConfig.fromEnvironment());

  testWidgets('RM-D-010 п.3: admin приглашает в UI (SCR-45) → приглашённый входит по OTP → PIN → касса', (
    WidgetTester tester,
  ) async {
    // Чистый старт: сессия и черновик прежнего прогона удаляются (идентификатор устройства остаётся).
    await FlutterSecureStorageAdapter().deleteAll(<SecureKey>[...SecureKey.session, ...SecureKey.registration]);
    await bootstrap();
    await tester.pump();
    await pumpUntilFound(tester, find.byKey(SplashScreen.screenKey));
    await pumpUntilFound(tester, find.byKey(NoSessionScreen.screenKey));

    // 1. Администратор: первый вход → PIN.
    await _phoneAndOtp(tester, _adminPhone);
    await _staffFirstPin(tester, _adminPin);
    await pumpUntil(
      tester,
      () => !_where(tester).startsWith('/auth') && !_where(tester).startsWith('/register'),
      'главный экран admin',
    );
    debugPrint('admin_invite_flow: admin вошёл — ${_where(tester)}');

    // SCR-45 → «Пригласить».
    _router(tester)!.go('/admin/users');
    await pumpUntilFound(tester, find.byKey(const ValueKey<String>('scr-45')));
    await _settle(tester);
    final Finder inviteButton = find.byKey(const ValueKey<String>('admin-invite-button'));
    final Finder inviteFab = find.byKey(const ValueKey<String>('admin-invite-fab'));
    await pumpUntil(
      tester,
      () => inviteButton.evaluate().isNotEmpty || inviteFab.evaluate().isNotEmpty,
      'кнопка «Пригласить»',
    );
    await _tap(tester, inviteButton.evaluate().isNotEmpty ? inviteButton : inviteFab);
    await pumpUntilFound(tester, find.byKey(const ValueKey<String>('admin-invite-form')));
    await tester.enterText(_input(const ValueKey<String>('admin-invite-phone')), _invitedPhone);
    await tester.pump();
    await tester.enterText(_input(const ValueKey<String>('admin-invite-name')), _invitedName);
    await tester.pump();
    await _tap(tester, find.byKey(const ValueKey<String>('admin-invite-role-cashier')));
    await _tap(tester, find.byKey(const ValueKey<String>('admin-invite-submit')));

    // `403 STEP_UP_REQUIRED` (invitations.manage) → StepUpDialog → PIN администратора → повтор запроса.
    await pumpUntil(tester, () => find.byType(PinField).evaluate().isNotEmpty, 'StepUpDialog с PIN', seconds: 20);
    await _settle(tester);
    await _enterPin(tester, _adminPin);
    await pumpUntil(
      tester,
      () => find.byKey(const ValueKey<String>('admin-invite-form')).evaluate().isEmpty,
      'приглашение создано (форма закрыта)',
    );
    await _settle(tester);
    expect(find.byKey(const ValueKey<String>('admin-invite-error')), findsNothing);
    debugPrint('admin_invite_flow: приглашение создано — ${_where(tester)}');

    // 2. Выход через SCR-42 «Устройства и сессии» → «Выйти» (текущая сессия).
    _router(tester)!.go('/settings?section=sessions');
    await pumpUntilFound(tester, find.byKey(SessionsSectionKeys.logoutAll));
    final Finder logoutCurrent = find.byWidgetPredicate(
      (Widget w) =>
          w is AppButton &&
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('settings-session-logout-'),
    );
    await pumpUntilFound(tester, logoutCurrent);
    await _tap(tester, logoutCurrent.first);
    await pumpUntilFound(tester, find.byType(ConfirmDialog));
    await _tap(tester, find.descendant(of: find.byType(ConfirmDialog), matching: find.text(_l10n.profile_logout)).last);
    await pumpUntilFound(tester, find.byKey(PhoneScreen.fieldKey));
    debugPrint('admin_invite_flow: admin вышел — ${_where(tester)}');

    // 3. Приглашённый: OTP → PIN без регистрационной формы → касса.
    await _phoneAndOtp(tester, _invitedPhone);
    await _staffFirstPin(tester, _cashierPin);
    await pumpUntil(tester, () => _where(tester).startsWith('/cashier'), 'главный экран кассира /cashier');
    debugPrint('admin_invite_flow: приглашённый вошёл — ${_where(tester)}');
  });
}
