// RM-D-011 / RM-D-012: сквозной путь этапа D на Windows против локального тестового контура.
//
// Сценарии (13 RM-D-012, RM-D-017; 02 SCR-00…SCR-06):
//   1. клиент: Splash → SCR-01 телефон → SCR-02 OTP → SCR-03 регистрация → SCR-04 PIN → «Готово» → SCR-50
//      (с этапа E — настоящий экран; корневой ключ `stub-SCR-50` сохранён, каталог — integration_test/catalog_flow_test.dart);
//   2. приглашённый сотрудник: SCR-01 → SCR-02 → SCR-04 «первый вход сотрудника» (без формы SCR-03) → PIN →
//      SCR-10 (с этапа E — настоящий экран, корневой ключ `stub-SCR-10` сохранён);
//   3. клиент с карточкой 1С: SCR-01 → SCR-02 → SCR-03 → SCR-04 → SCR-06 «Привязка к клиенту».
//
// Код подтверждения — тестовый режим OTP 09 §5.8 (`AUTH_OTP_TEST_MODE`, только dev/staging): номера и код
// задаёт `pos-api/scripts/local-stack.mjs` (`AUTH_FIXTURES`), SMS не отправляется. Каждый запуск — на свежем
// стеке (номера регистрируются один раз):
//
//   cd pos-api && npm run build
//   LOCAL_STACK_MIN_APP_VERSION=android=0.1.0,windows=0.1.0 node scripts/local-stack.mjs serve --auth-fixtures
//   cd pos-app && flutter test integration_test/auth_flow_test.dart -d windows --dart-define-from-file=env/dev.json --dart-define-from-file=env/local.json
//
// Значения по умолчанию совпадают с `AUTH_FIXTURES`; переопределяются `--dart-define=E2E_*`.
// Телефоны и код в лог не выводятся (11 SEC-062).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:optomstroy/app/bootstrap.dart';
import 'package:optomstroy/core/config/app_data_directory.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/storage/secure_storage.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/pin_field.dart';
import 'package:optomstroy/features/auth/presentation/screens/no_session_screen.dart';
import 'package:optomstroy/features/auth/presentation/screens/otp_screen.dart';
import 'package:optomstroy/features/auth/presentation/screens/phone_screen.dart';
import 'package:optomstroy/features/registration/presentation/screens/customer_link_screen.dart';
import 'package:optomstroy/features/registration/presentation/screens/registration_form_screen.dart';
import 'package:optomstroy/features/registration/presentation/screens/registration_security_screen.dart';
import 'package:optomstroy/features/splash/presentation/screens/splash_screen.dart';

import 'support/fixture_phones.dart';

/// Тестовый код OTP контура (`AUTH_FIXTURES.otpCode`).
const String _otpCode = String.fromEnvironment('E2E_OTP_CODE', defaultValue: '246810');

/// Национальные номера (9 цифр) из `AUTH_FIXTURES`.
const String _customerPhone = String.fromEnvironment('E2E_CUSTOMER_PHONE', defaultValue: '777000903');
const String _staffPhone = String.fromEnvironment('E2E_STAFF_PHONE', defaultValue: '777000902');

/// `AUTH_FIXTURES.customerLinked` = телефон карточки фикстуры 1С `customers-search.200` (`+996700000001`,
/// сравнение по последним 9 цифрам) → регистрация даёт `customerMatch=proposed` (SCR-06).
const String _linkedPhone = String.fromEnvironment('E2E_LINKED_PHONE', defaultValue: kLinkedPhoneDigits);

const Key _customerHomeStub = ValueKey<String>('stub-SCR-50');
const Key _catalogStub = ValueKey<String>('stub-SCR-10');

/// Ждёт появления [finder], прокачивая кадры; падает по таймауту.
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

/// Пауза на завершение перехода между экранами (page transition игнорирует касания; бесконечные анимации
/// персонажа не дают использовать pumpAndSettle).
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Текущий адрес маршрута (диагностика падений; адреса без ПДн).
String _where(WidgetTester tester) {
  final Iterable<Element> nav = find.byType(Navigator).evaluate();
  if (nav.isEmpty) {
    return '—';
  }
  final GoRouter? router = GoRouter.maybeOf(nav.first);
  return router?.routerDelegate.currentConfiguration.uri.toString() ?? '—';
}

Finder _input(Key key) => find.descendant(of: find.byKey(key), matching: find.byType(EditableText));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

/// PIN цифровой клавиатурой поля PIN (DS `PinField`), как пользователь: нажатие на клавишу,
/// предварительно прокрутив её в видимую область (на окне Windows клавиатура может быть ниже края).
Future<void> _enterPin(WidgetTester tester, String pin) async {
  for (final String d in pin.split('')) {
    final Finder label = find.descendant(of: find.byType(PinField).first, matching: find.text(d));
    final Finder key = find.ancestor(of: label.last, matching: find.byType(AnimatedContainer)).first;
    await Scrollable.ensureVisible(tester.element(key), alignment: 0.5);
    await tester.pump();
    await tester.tap(key);
    await tester.pump(const Duration(milliseconds: 80));
  }
  await _settle(tester);
}

/// Кнопка «Завершить» доступна (PIN принят полем и подтверждён).
Future<void> _expectCompleteEnabled(WidgetTester tester) async {
  await pumpUntilFound(
    tester,
    find.byWidgetPredicate(
      (Widget w) => w is AppButton && w.key == RegistrationSecurityScreen.completeKey && w.onPressed != null,
    ),
    timeout: const Duration(seconds: 10),
  );
}

/// Чистый старт: сессия и черновик регистрации прежнего прогона удаляются (идентификатор устройства остаётся).
Future<void> _cleanStart(WidgetTester tester) async {
  final FlutterSecureStorageAdapter storage = FlutterSecureStorageAdapter();
  await storage.deleteAll(<SecureKey>[...SecureKey.session, ...SecureKey.registration]);
  await bootstrap();
  await tester.pump();
  await pumpUntilFound(tester, find.byKey(SplashScreen.screenKey));
  await pumpUntilFound(tester, find.byKey(NoSessionScreen.screenKey));
}

/// SCR-01 → SCR-02 → код из тестового режима OTP.
Future<void> _phoneAndOtp(WidgetTester tester, String nationalPhone) async {
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

/// SCR-03: ФИО, год рождения, отметка «Я ознакомлен(а)» → «Продолжить».
Future<void> _registrationForm(WidgetTester tester, {required String fullName, required String year}) async {
  await pumpUntilFound(tester, find.byKey(RegistrationFormScreen.screenKey));
  await _settle(tester);
  await tester.enterText(_input(RegistrationFormScreen.nameFieldKey), fullName);
  await tester.pump();
  await tester.enterText(_input(RegistrationFormScreen.yearFieldKey), year);
  await tester.pump();
  await _tap(tester, find.byKey(RegistrationFormScreen.pdAckKey));
  await _tap(tester, find.byKey(RegistrationFormScreen.continueKey));
}

/// SCR-04 клиента: PIN (4 цифры) дважды → «Завершить регистрацию».
Future<void> _customerSecurity(WidgetTester tester, String pin) async {
  await pumpUntilFound(tester, find.byKey(RegistrationSecurityScreen.screenKey));
  await pumpUntilFound(tester, find.byType(PinField));
  await _settle(tester);
  await _enterPin(tester, pin);
  await _enterPin(tester, pin);
  await _expectCompleteEnabled(tester);
  await _tap(tester, find.byKey(RegistrationSecurityScreen.completeKey));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Данные приложения — в APP_DATA_DIR из env/local.json (машина разработки, вне git; не %APPDATA% на C:), до
  // первого обращения к ним. Без APP_DATA_DIR — каталог ОС.
  AppDataDirectory.apply(AppConfig.fromEnvironment());

  testWidgets(
    'T-AUTH-031, T-AUTH-043, T-REG-025 (в): клиент: Splash → телефон → OTP → регистрация → PIN → каталог-заглушка (SCR-50)',
    (tester) async {
      await _cleanStart(tester);
      await _phoneAndOtp(tester, _customerPhone);

      await _registrationForm(tester, fullName: 'Тестов Клиент', year: '1990');
      await _customerSecurity(tester, '4829');

      // «Готово» (автопереход без кнопки «Войти») → главный экран клиента.
      await pumpUntilFound(tester, find.byKey(RegistrationSecurityScreen.doneKey));
      await pumpUntilFound(tester, find.byKey(_customerHomeStub));
      expect(find.byKey(RegistrationFormScreen.screenKey), findsNothing);
    },
  );

  testWidgets('приглашённый сотрудник: OTP → установка PIN без регистрации → каталог-заглушка (SCR-10)', (
    tester,
  ) async {
    await _cleanStart(tester);
    await _phoneAndOtp(tester, _staffPhone);

    // Без формы SCR-03: сразу SCR-04 «первый вход сотрудника» (RM-D-017, ядро §24.2).
    await pumpUntilFound(tester, find.byKey(RegistrationSecurityScreen.screenKey));
    expect(find.byKey(RegistrationFormScreen.screenKey), findsNothing);
    expect(find.byKey(RegistrationSecurityScreen.pinSwitchKey), findsNothing, reason: 'PIN сотрудника обязателен');
    await pumpUntilFound(tester, find.byType(PinField));
    await _settle(tester);
    debugPrint('auth_flow_test: после OTP сотрудника — ${_where(tester)}');
    expect(find.byType(PinField), findsWidgets, reason: 'экран: ${_where(tester)}');
    expect(tester.widget<PinField>(find.byType(PinField).first).length, 6);
    await _enterPin(tester, '582914');
    await _enterPin(tester, '582914');
    await _tap(tester, find.byKey(RegistrationSecurityScreen.pdAckKey));
    await _expectCompleteEnabled(tester);
    await _tap(tester, find.byKey(RegistrationSecurityScreen.completeKey));

    await pumpUntilFound(tester, find.byKey(_catalogStub));
  });

  testWidgets('клиент с карточкой 1С: OTP → регистрация → PIN → SCR-06 «Привязка к клиенту»', (tester) async {
    await _cleanStart(tester);
    await _phoneAndOtp(tester, _linkedPhone);

    await _registrationForm(tester, fullName: 'Асанов Бакыт', year: '1985');
    await _customerSecurity(tester, '7391');

    await pumpUntilFound(tester, find.byKey(CustomerLinkScreen.screenKey));
    // Карточка `legal` из ответа поиска 1С: самоподтверждение недоступно — решение администратора (SEC-130).
    await pumpUntilFound(
      tester,
      find.byWidgetPredicate(
        (Widget w) => w.key == CustomerLinkScreen.waitAdminKey || w.key == CustomerLinkScreen.cardKey,
      ),
    );
  });
}
