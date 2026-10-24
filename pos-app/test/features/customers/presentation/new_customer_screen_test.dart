// Widget-тесты SCR-26 «Новый клиент» (RM-F-006; 02 AC-UI-26-001…012): проверка дублей по телефону до создания,
// выбор существующего, «Всё равно создать» по ролям, ошибка проверки, ИНН юр. лица, одно создание на двойное нажатие.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_radio.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/entities/new_customer.dart';
import 'package:optomstroy/features/customers/domain/repositories/customers_repository.dart';
import 'package:optomstroy/features/customers/presentation/new/new_customer_controller.dart';
import 'package:optomstroy/features/customers/presentation/new/new_customer_screen.dart';

import '../../../support/f_fakes.dart';

final class _Host {
  _Host({this.role = RoleCode.cashier, this.online = true});

  final RoleCode role;
  final bool online;
  final FFakes fakes = FFakes();
  int _keys = 0;
  String? result = 'not-closed';

  Future<void> pump(WidgetTester tester, {Size size = const Size(390, 844)}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          ...fakes.overrides,
          newCustomerViewerRoleProvider.overrideWithValue(role),
          newCustomerOnlineProvider.overrideWithValue(online),
          newCustomerKeyFactoryProvider.overrideWithValue(() => 'cust-key-${++_keys}'),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('ru'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (BuildContext context, Widget? app) =>
              MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: app!),
          home: Builder(
            builder: (BuildContext ctx) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    result = await Navigator.of(ctx).push<String>(
                      MaterialPageRoute<String>(builder: (_) => const NewCustomerScreen(returnTo: 'checkout')),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _settle(tester);
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder _field(String key) =>
    find.descendant(of: find.byKey(ValueKey<String>(key)), matching: find.byType(EditableText));

bool _enabled(WidgetTester tester, Key key) => tester.widget<AppButton>(find.byKey(key)).onPressed != null;

Future<void> _tap(WidgetTester tester, String key) async {
  final Finder f = find.byKey(ValueKey<String>(key));
  await tester.ensureVisible(f);
  await tester.tap(f);
  await _settle(tester);
}

Customer _existing() => const Customer(id: 'cust-9', name: 'Азамат Бекович', phoneMasked: '+996 700 ••• 456');

PageResult<Customer> _page(List<Customer> items) => PageResult<Customer>(items: items);

void main() {
  testWidgets(
    'AC-UI-26-001, AC-UI-26-007: проверка дублей на 9-й цифре; без совпадений — создание; двойное нажатие — один '
    'запрос; результат — ID клиента',
    (WidgetTester tester) async {
      final _Host h = _Host();
      h.fakes.customers.onSearch = (CustomerSearchQuery q) async => Success<PageResult<Customer>>(_page(<Customer>[]));
      final Completer<Result<NewCustomerOutcome>> pending = Completer<Result<NewCustomerOutcome>>();
      h.fakes.customers.onCreate = (NewCustomerRequest r, String key) => pending.future;
      await h.pump(tester);
      expect(_enabled(tester, NewCustomerScreen.createKey), isFalse);
      await tester.enterText(_field('customer-new-phone'), '700123456');
      await _settle(tester);
      final ({String method, List<Object?> args}) search = h.fakes.customers.calls.single;
      expect((search.args.single! as CustomerSearchQuery).q, '+996700123456');
      expect(find.text('Совпадений не найдено'), findsOneWidget);
      await tester.enterText(_field('customer-new-name'), 'Нурлан Асанов');
      await tester.pump();
      expect(_enabled(tester, NewCustomerScreen.createKey), isTrue);
      await tester.tap(find.byKey(NewCustomerScreen.createKey));
      await tester.pump();
      await tester.tap(find.byKey(NewCustomerScreen.createKey), warnIfMissed: false);
      await tester.pump();
      pending.complete(
        const Success<NewCustomerOutcome>(NewCustomerCreated(Customer(id: 'cust-new', name: 'Нурлан Асанов'))),
      );
      await _settle(tester);
      final List<({String method, List<Object?> args})> creates = h.fakes.customers.calls
          .where((c) => c.method == 'create')
          .toList();
      expect(creates, hasLength(1));
      final NewCustomerRequest req = creates.single.args.first! as NewCustomerRequest;
      expect(req.phonesE164, <String>['+996700123456']);
      expect(req.customerType, CustomerType.individual);
      expect(req.forceCreate, isFalse);
      expect(h.result, 'cust-new');
    },
  );

  testWidgets('AC-UI-26-008, T-UI-026: ответ 201 с STALE_DATA — баннер «Проверка в 1С сейчас недоступна — возможен '
      'дубль» под телефоном; повторно создать нельзя; закрытие возвращает созданного клиента', (
    WidgetTester tester,
  ) async {
    final _Host h = _Host();
    h.fakes.customers.onSearch = (_) async => Success<PageResult<Customer>>(_page(<Customer>[]));
    h.fakes.customers.onCreate = (NewCustomerRequest r, String key) async => const Success<NewCustomerOutcome>(
      NewCustomerCreated(
        Customer(id: 'cust-new', name: 'Нурлан Асанов'),
        warningCodes: <String>['STALE_DATA'],
      ),
    );
    await h.pump(tester);
    await tester.enterText(_field('customer-new-phone'), '700123456');
    await _settle(tester);
    await tester.enterText(_field('customer-new-name'), 'Нурлан Асанов');
    await tester.pump();
    expect(find.byKey(NewCustomerScreen.onecCheckSkippedKey), findsNothing);
    await tester.ensureVisible(find.byKey(NewCustomerScreen.createKey));
    await tester.tap(find.byKey(NewCustomerScreen.createKey));
    await _settle(tester);

    expect(find.byKey(NewCustomerScreen.onecCheckSkippedKey), findsOneWidget);
    expect(find.textContaining('Проверка в 1С сейчас недоступна — возможен дубль'), findsOneWidget);
    expect(h.result, 'not-closed', reason: 'предупреждение видно до закрытия экрана');
    expect(_enabled(tester, NewCustomerScreen.createKey), isFalse, reason: 'клиент уже создан');

    await _tap(tester, 'customer-new-close');
    expect(h.result, 'cust-new', reason: 'результат экрана — созданный клиент');
    expect(h.fakes.customers.calls.where((c) => c.method == 'create'), hasLength(1));
  });

  testWidgets('AC-UI-26-002: найден клиент — «Выбрать этого клиента» возвращает его без создания', (
    WidgetTester tester,
  ) async {
    final _Host h = _Host();
    h.fakes.customers.onSearch = (_) async => Success<PageResult<Customer>>(_page(<Customer>[_existing()]));
    await h.pump(tester);
    await tester.enterText(_field('customer-new-phone'), '700123456');
    await _settle(tester);
    expect(find.text('Найден клиент с этим номером'), findsOneWidget);
    await tester.enterText(_field('customer-new-name'), 'Нурлан Асанов');
    await tester.pump();
    expect(_enabled(tester, NewCustomerScreen.createKey), isFalse);
    await _tap(tester, 'customer-new-use-cust-9');
    expect(h.result, 'cust-9');
    expect(h.fakes.customers.calls.where((c) => c.method == 'create'), isEmpty);
  });

  testWidgets('AC-UI-26-003: продавец не видит «Всё равно создать» — подпись про кассира', (WidgetTester tester) async {
    final _Host h = _Host(role: RoleCode.seller);
    h.fakes.customers.onSearch = (_) async => Success<PageResult<Customer>>(_page(<Customer>[_existing()]));
    await h.pump(tester);
    await tester.enterText(_field('customer-new-phone'), '700123456');
    await _settle(tester);
    expect(find.byKey(const ValueKey<String>('customer-new-force')), findsNothing);
    expect(find.text('Если это другой клиент — обратитесь к кассиру или старшему продавцу'), findsOneWidget);
  });

  testWidgets('AC-UI-26-003: кассир — «Всё равно создать» с причиной ≥ 5: forceCreate, forceReason, новый ключ', (
    WidgetTester tester,
  ) async {
    final _Host h = _Host();
    h.fakes.customers.onSearch = (_) async => Success<PageResult<Customer>>(_page(<Customer>[_existing()]));
    h.fakes.customers.onCreate = (NewCustomerRequest r, String key) async =>
        const Success<NewCustomerOutcome>(NewCustomerCreated(Customer(id: 'cust-new', name: 'Нурлан')));
    await h.pump(tester);
    await tester.enterText(_field('customer-new-phone'), '700123456');
    await _settle(tester);
    await tester.enterText(_field('customer-new-name'), 'Нурлан Асанов');
    await tester.pump();
    await _tap(tester, 'customer-new-force');
    await tester.enterText(_field('customer-new-force-reason'), 'Тест');
    await tester.pump();
    expect(_enabled(tester, NewCustomerScreen.createKey), isFalse);
    await tester.enterText(_field('customer-new-force-reason'), 'Другой человек, тёзка');
    await tester.pump();
    expect(_enabled(tester, NewCustomerScreen.createKey), isTrue);
    await tester.ensureVisible(find.byKey(NewCustomerScreen.createKey));
    await tester.tap(find.byKey(NewCustomerScreen.createKey));
    await _settle(tester);
    final ({String method, List<Object?> args}) call = h.fakes.customers.calls.firstWhere((c) => c.method == 'create');
    final NewCustomerRequest req = call.args[0]! as NewCustomerRequest;
    expect(req.forceCreate, isTrue);
    expect(req.forceReason, 'Другой человек, тёзка');
    expect(req.comment, isNull);
    expect(call.args[1], 'cust-key-1');
    expect(h.result, 'cust-new');
  });

  testWidgets('AC-UI-26-004: 409 при создании — кандидаты, клиент не создан', (WidgetTester tester) async {
    final _Host h = _Host();
    h.fakes.customers.onSearch = (_) async => Success<PageResult<Customer>>(_page(<Customer>[]));
    h.fakes.customers.onCreate = (NewCustomerRequest r, String key) async => const Success<NewCustomerOutcome>(
      NewCustomerDuplicates(<DuplicateCandidate>[DuplicateCandidate(id: 'cust-7', displayName: 'ОсОО Ак-Таш')]),
    );
    await h.pump(tester);
    await tester.enterText(_field('customer-new-phone'), '700123456');
    await _settle(tester);
    await tester.enterText(_field('customer-new-name'), 'Ак-Таш');
    await tester.pump();
    await tester.ensureVisible(find.byKey(NewCustomerScreen.createKey));
    await tester.tap(find.byKey(NewCustomerScreen.createKey));
    await _settle(tester);
    expect(find.text('ОсОО Ак-Таш'), findsOneWidget);
    expect(h.result, 'not-closed');
  });

  testWidgets('AC-UI-26-010: ошибка проверки — «Повторить проверку», создание недоступно', (WidgetTester tester) async {
    final _Host h = _Host();
    int n = 0;
    h.fakes.customers.onSearch = (_) async => ++n == 1
        ? const FailureResult<PageResult<Customer>>(NetworkFailure(NetworkFailureKind.timeout))
        : Success<PageResult<Customer>>(_page(<Customer>[]));
    await h.pump(tester);
    await tester.enterText(_field('customer-new-phone'), '700123456');
    await _settle(tester);
    expect(find.text('Не удалось проверить номер на дубли'), findsOneWidget);
    await tester.enterText(_field('customer-new-name'), 'Нурлан Асанов');
    await tester.pump();
    expect(_enabled(tester, NewCustomerScreen.createKey), isFalse);
    await _tap(tester, 'customer-new-check-retry');
    expect(n, 2);
    expect(find.text('Совпадений не найдено'), findsOneWidget);
    expect(_enabled(tester, NewCustomerScreen.createKey), isTrue);
  });

  testWidgets('AC-UI-26-006/012: «Юр. лицо» — ИНН обязателен (14 цифр); «Физ. лицо» — поля ИНН нет', (
    WidgetTester tester,
  ) async {
    final _Host h = _Host(role: RoleCode.seller);
    h.fakes.customers.onSearch = (_) async => Success<PageResult<Customer>>(_page(<Customer>[]));
    await h.pump(tester);
    expect(find.byKey(const ValueKey<String>('customer-new-inn')), findsNothing);
    await _tap(tester, 'customer-new-type-legal');
    expect(find.byKey(const ValueKey<String>('customer-new-inn')), findsOneWidget);
    await tester.enterText(_field('customer-new-phone'), '700123456');
    await _settle(tester);
    await tester.enterText(_field('customer-new-name'), 'ОсОО Ак-Таш');
    await tester.pump();
    await tester.ensureVisible(find.byKey(NewCustomerScreen.createKey));
    await tester.tap(find.byKey(NewCustomerScreen.createKey));
    await _settle(tester);
    expect(find.text('ИНН — 14 цифр'), findsOneWidget);
    expect(h.fakes.customers.calls.where((c) => c.method == 'create'), isEmpty);
  });

  testWidgets('AC-UI-26-009: без сети — «Нужна сеть, чтобы создать клиента», создание недоступно', (
    WidgetTester tester,
  ) async {
    final _Host h = _Host(online: false);
    await h.pump(tester);
    expect(find.text('Нужна сеть, чтобы создать клиента'), findsOneWidget);
    expect(_enabled(tester, NewCustomerScreen.createKey), isFalse);
  });

  testWidgets('AC-UI-26-011: кассир, «Юр. лицо» — на 14-й цифре ИНН существующего клиента «Найден клиент с этим ИНН»; '
      'продавец — кандидаты только после «Создать клиента» (409)', (WidgetTester tester) async {
    final _Host cashier = _Host();
    cashier.fakes.customers.onSearch = (CustomerSearchQuery q) async => Success<PageResult<Customer>>(
      _page(<Customer>[if (q.q == '01234567890123') const Customer(id: 'cust-7', name: 'ОсОО Ак-Таш')]),
    );
    await cashier.pump(tester);
    await _tap(tester, 'customer-new-type-legal');
    await tester.enterText(_field('customer-new-inn'), '0123456789012');
    await _settle(tester);
    expect(find.text('Найден клиент с этим ИНН'), findsNothing, reason: '13 цифр — проверки нет');
    await tester.enterText(_field('customer-new-inn'), '01234567890123');
    await _settle(tester);
    expect(find.text('Найден клиент с этим ИНН'), findsOneWidget);
    expect(
      cashier.fakes.customers.calls.where(
        (c) => c.method == 'search' && (c.args.single! as CustomerSearchQuery).q == '01234567890123',
      ),
      hasLength(1),
    );

    await tester.pumpWidget(const SizedBox());
    final _Host seller = _Host(role: RoleCode.seller);
    seller.fakes.customers.onSearch = (_) async => Success<PageResult<Customer>>(_page(<Customer>[]));
    seller.fakes.customers.onCreate = (NewCustomerRequest r, String key) async => const Success<NewCustomerOutcome>(
      NewCustomerDuplicates(<DuplicateCandidate>[DuplicateCandidate(id: 'cust-7', displayName: 'ОсОО Ак-Таш')]),
    );
    await seller.pump(tester);
    await _tap(tester, 'customer-new-type-legal');
    await tester.enterText(_field('customer-new-inn'), '01234567890123');
    await _settle(tester);
    expect(find.text('Найден клиент с этим ИНН'), findsNothing, reason: 'продавцу поиск по ИНН не выполняется');
    await tester.enterText(_field('customer-new-phone'), '700123456');
    await _settle(tester);
    await tester.enterText(_field('customer-new-name'), 'Ак-Таш');
    await tester.pump();
    await tester.ensureVisible(find.byKey(NewCustomerScreen.createKey));
    await tester.tap(find.byKey(NewCustomerScreen.createKey));
    await _settle(tester);
    expect(find.text('ОсОО Ак-Таш'), findsOneWidget);
  });

  testWidgets('AC-UI-26-012: тип — три радиокнопки «Физ. лицо» / «ИП» / «Юр. лицо»; customerType в запросе; ИНН — у ИП '
      'и юр. лица', (WidgetTester tester) async {
    for (final (CustomerType type, bool inn) in <(CustomerType, bool)>[
      (CustomerType.individual, false),
      (CustomerType.entrepreneur, true),
      (CustomerType.legal, true),
    ]) {
      final _Host h = _Host(role: RoleCode.seller);
      h.fakes.customers.onSearch = (_) async => Success<PageResult<Customer>>(_page(<Customer>[]));
      h.fakes.customers.onCreate = (NewCustomerRequest r, String key) async =>
          const Success<NewCustomerOutcome>(NewCustomerCreated(Customer(id: 'cust-new', name: 'Клиент')));
      await tester.pumpWidget(const SizedBox());
      await h.pump(tester);
      expect(find.byType(AppRadio<CustomerType>), findsNWidgets(3));
      await _tap(tester, 'customer-new-type-${type.value}');
      expect(
        find.byKey(const ValueKey<String>('customer-new-inn')),
        inn ? findsOneWidget : findsNothing,
        reason: '$type',
      );
      await tester.enterText(_field('customer-new-phone'), '700123456');
      await _settle(tester);
      await tester.enterText(_field('customer-new-name'), 'Клиент Тест');
      if (inn) await tester.enterText(_field('customer-new-inn'), '01234567890123');
      await tester.pump();
      await tester.ensureVisible(find.byKey(NewCustomerScreen.createKey));
      await tester.tap(find.byKey(NewCustomerScreen.createKey));
      await _settle(tester);
      final NewCustomerRequest req =
          h.fakes.customers.calls.firstWhere((c) => c.method == 'create').args.first! as NewCustomerRequest;
      expect(req.customerType, type);
      expect(req.customerType.value, switch (type) {
        CustomerType.individual => 'individual',
        CustomerType.entrepreneur => 'entrepreneur',
        CustomerType.legal => 'legal',
      });
    }
  });

  testWidgets('SCR-26 роли (F-flutter-ui-4): «Всё равно создать» — cashier, senior_seller, admin; seller — нет', (
    WidgetTester tester,
  ) async {
    for (final (RoleCode role, bool force) in <(RoleCode, bool)>[
      (RoleCode.cashier, true),
      (RoleCode.seniorSeller, true),
      (RoleCode.admin, true),
      (RoleCode.seller, false),
    ]) {
      final _Host h = _Host(role: role);
      h.fakes.customers.onSearch = (_) async => Success<PageResult<Customer>>(_page(<Customer>[_existing()]));
      await tester.pumpWidget(const SizedBox());
      await h.pump(tester);
      await tester.enterText(_field('customer-new-phone'), '700123456');
      await _settle(tester);
      expect(
        find.byKey(const ValueKey<String>('customer-new-force')),
        force ? findsOneWidget : findsNothing,
        reason: role.value,
      );
    }
  });
}
