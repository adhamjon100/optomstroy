// Экраны оформления заявки с планшета SCR-52 и SCR-53 в маршрутах режима (`kioskRoutes()`, каркас
// `KioskShellScreen`; 02 ч. F SCR-52, SCR-53; 13 TAB-2-04): раскладка expanded 1280 × 800 и medium 800 × 1280,
// ввод экранной клавиатурой в `PrivateInputScope`, текст информирования и лист «Подробнее», шаги и адрес `step`,
// «Отправляем заявку…», возврат к корзине по остатку, SCR-53 и сброс, «Назад» и Esc, прямой путь.
//
// 12 T-KIOSK-030 (виджетная часть): SCR-52 обёрнут в `SecureContent` — порт `FLAG_SECURE` включается на SCR-52 и
// снимается после ухода (чёрный кадр снимка — на устройстве, пилот TAB-4-01). Баннер `426` / «Нет связи» — один, под
// шапкой UI-52-001 (02 UI-51-014; T-KIOSK-050); текстовые кнопки покупателя — цель 48 (03 A11Y-003, AC-A11Y-023).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/router/kiosk_routes.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/app_localizations_ru.dart';
import 'package:optomstroy/core/session/secure_content.dart';
import 'package:optomstroy/core/session/secure_screen.dart';
import 'package:optomstroy/core/session/session_overlay.dart' show KioskStatus, kioskStatusProvider;
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/kiosk_keypad.dart';
import 'package:optomstroy/design_system/components/private_input_scope.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart' as catalog;
import 'package:optomstroy/features/kiosk/domain/kiosk_checkout.dart';
import 'package:optomstroy/features/kiosk/kiosk_providers.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_checkout_controller.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_checkout_screen.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_code_step.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_phone_step.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_sending_view.dart';
import 'package:optomstroy/features/kiosk/presentation/done/kiosk_done_screen.dart';
import 'package:optomstroy/features/kiosk/presentation/kiosk_shell_screen.dart';

import 'kiosk_checkout_support.dart';

final AppLocalizationsRu l10n = AppLocalizationsRu();

const Key _openKey = ValueKey<String>('test-open-checkout');
const Key _showcaseKey = ValueKey<String>('test-showcase');

const Size _expanded = Size(1280, 800);
const Size _medium = Size(800, 1280);

/// Порт `FLAG_SECURE`: запоминает вызовы.
final class _FakeSecureScreen implements SecureScreen {
  final List<bool> calls = <bool>[];

  @override
  Future<void> setSecure({required bool enabled}) async => calls.add(enabled);
}

/// Сеть экрана теста (переключается).
final _online = NotifierProvider<_Online, OnlineStatus>(_Online.new);

final class _Online extends Notifier<OnlineStatus> {
  @override
  OnlineStatus build() => OnlineStatus.online;

  void set(OnlineStatus s) => state = s;
}

/// Стенд: маршруты режима (`kioskRoutes()`), тело SCR-51 — заглушка с «Оформить заявку» (`push`, как drawer).
final class _Stand {
  _Stand(this.tester);

  final WidgetTester tester;
  final KioskCheckoutFakes f = KioskCheckoutFakes();
  final _FakeSecureScreen secure = _FakeSecureScreen();
  int startOvers = 0;
  Completer<void>? startOverGate;
  late GoRouter router;
  late ProviderContainer container;

  KioskCheckoutState get state => container.read(kioskCheckoutControllerProvider);

  String get location => router.state.uri.toString();

  Future<void> pump({
    Size size = _expanded,
    String initial = KioskPaths.showcase,
    OnlineStatus online = OnlineStatus.online,
    bool bound = true,
    List<Override> extra = const <Override>[],
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    router = GoRouter(initialLocation: initial, routes: kioskRoutes());
    addTearDown(router.dispose);
    container = ProviderContainer(
      overrides: <Override>[
        ...f.overrides(bound: bound),
        kioskCatalogBodyProvider.overrideWithValue(
          (BuildContext context, KioskCatalogArgs args) => Center(
            key: _showcaseKey,
            child: TextButton(
              key: _openKey,
              onPressed: () => unawaited(GoRouter.of(context).push<void>('/kiosk/checkout?step=phone')),
              child: const Text('SCR-51'),
            ),
          ),
        ),
        cartOnlineStatusProvider.overrideWith((Ref ref) => ref.watch(_online)),
        secureScreenProvider.overrideWithValue(secure),
        kioskTimingsProvider.overrideWithValue(const KioskTimings(done: Duration(seconds: 60))),
        catalog.catalogKioskStartOverProvider.overrideWithValue(() async {
          startOvers++;
          await startOverGate?.future;
        }),
        ...extra,
      ],
    );
    addTearDown(container.dispose);
    container.read(_online.notifier).set(online);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: AppTheme.light(),
          locale: const Locale('ru'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          debugShowCheckedModeBanner: false,
          // Как `App` в режиме планшета: приватный ввод; анимации выключены (reduce-motion).
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: PrivateInputScope(enabled: true, child: child!),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> open() async {
    await tester.tap(find.byKey(_openKey));
    await tester.pumpAndSettle();
    expect(find.byKey(KioskCheckoutScreen.screenKey), findsOneWidget);
  }

  Future<void> keypad(String digits) async {
    for (final String d in digits.split('')) {
      await tester.tap(find.byKey(KioskKeypad.keyFor(d)));
      await tester.pump();
    }
  }

  /// Шаг «Код» на номер A с кодом [kChallengeA].
  Future<void> toCode() async {
    await open();
    await keypad(kPhoneA);
    f.repo.otpAnswers.add(otpSent(kChallengeA));
    await tester.tap(find.byKey(KioskPhoneStep.getCodeKey));
    await tester.pumpAndSettle();
    expect(find.byKey(KioskCodeStep.fieldKey), findsOneWidget);
  }

  /// Кнопка доступна (`AppButton.onPressed`).
  bool enabled(Key key) => tester.widget<AppButton>(find.byKey(key)).onPressed != null;
}

void main() {
  testWidgets('T-KIOSK-030 SCR-52 в SecureContent: FLAG_SECURE на обоих шагах, снимается после ухода', (tester) async {
    final _Stand s = _Stand(tester);
    await s.pump();
    expect(s.secure.calls, isEmpty, reason: 'витрина SCR-51 без FLAG_SECURE');
    await s.toCode();
    expect(
      find.ancestor(of: find.byKey(KioskCheckoutScreen.screenKey), matching: find.byType(SecureContent)),
      findsOneWidget,
    );
    expect(find.ancestor(of: find.byKey(KioskCodeStep.fieldKey), matching: find.byType(SecureContent)), findsOneWidget);
    expect(s.secure.calls, <bool>[true]);
    // «Назад» с шага «Код» — шаг «Телефон», затем SCR-51: защита снята.
    await tester.tap(find.byKey(KioskCheckoutScreen.backKey));
    await tester.pumpAndSettle();
    expect(find.byKey(KioskPhoneStep.fieldKey), findsOneWidget);
    expect(
      find.ancestor(of: find.byKey(KioskPhoneStep.fieldKey), matching: find.byType(SecureContent)),
      findsOneWidget,
    );
    await tester.tap(find.byKey(KioskCheckoutScreen.backKey));
    await tester.pumpAndSettle();
    expect(find.byKey(_showcaseKey), findsOneWidget);
    expect(s.secure.calls, <bool>[true, false]);
    expect(SecureContent.activeCount, 0);
  });

  testWidgets('expanded 1280 × 800: две колонки — состав и сумма, текст о номере слева; поле и клавиатура справа', (
    tester,
  ) async {
    final _Stand s = _Stand(tester);
    await s.pump();
    await s.open();
    expect(find.byKey(KioskCheckoutScreen.titleKey), findsOneWidget);
    expect(find.text(l10n.kiosk_phone_title), findsOneWidget);
    expect(find.text(l10n.cart_summary_items(3)), findsOneWidget);
    expect(find.text(l10n.cart_summary_total), findsOneWidget);
    expect(find.text(l10n.kiosk_notice_short), findsOneWidget);
    final Offset notice = tester.getCenter(find.byKey(KioskNoticeBlock.textKey));
    final Offset keypad = tester.getCenter(find.byType(KioskKeypad));
    expect(notice.dx, lessThan(keypad.dx), reason: 'текст — в левой колонке');
    expect(tester.getSize(find.byType(KioskKeypad)), const Size(KioskKeypad.width, KioskKeypad.height));
    // Предпросмотр открытия — по корзине планшета (cash, pickup, без номера).
    expect(s.f.checkout.calls.single.cartId, kCartId);
    // Клиента, долга, скидки, способа оплаты и доставки на экране нет.
    for (final String hidden in <String>['Клиент', 'Скидка', 'Долг', 'Доставка']) {
      expect(find.textContaining(hidden), findsNothing, reason: hidden);
    }
    expect(s.location, '/kiosk/checkout?step=phone');
  });

  testWidgets('medium 800 × 1280: одна колонка — состав и сумма одной строкой → текст → поле → клавиатура → кнопка', (
    tester,
  ) async {
    final _Stand s = _Stand(tester);
    await s.pump(size: _medium);
    await s.open();
    expect(find.textContaining('${l10n.cart_summary_items(3)} · ${l10n.cart_summary_total}'), findsOneWidget);
    final double summary = tester.getCenter(find.byKey(KioskCheckoutScreen.summaryKey)).dy;
    final double notice = tester.getCenter(find.byKey(KioskNoticeBlock.textKey)).dy;
    final double field = tester.getCenter(find.byKey(KioskPhoneStep.fieldKey)).dy;
    final double keys = tester.getCenter(find.byType(KioskKeypad)).dy;
    final double button = tester.getCenter(find.byKey(KioskPhoneStep.getCodeKey)).dy;
    expect(
      <double>[summary, notice, field, keys, button],
      orderedEquals(<double>[
        ...<double>[summary, notice, field, keys, button]..sort(),
      ]),
    );
    expect(tester.getSize(find.byKey(KioskPhoneStep.getCodeKey)).width, lessThanOrEqualTo(560));
  });

  for (final (String name, Size size) in <(String, Size)>[('expanded', _expanded), ('medium', _medium)]) {
    testWidgets('«Подробнее» ($name): лист с полным текстом той же версии и «Закрыть»', (tester) async {
      final _Stand s = _Stand(tester);
      await s.pump(size: size);
      await s.open();
      await tester.tap(find.byKey(KioskNoticeBlock.moreKey));
      await tester.pumpAndSettle();
      expect(find.text(l10n.kiosk_notice_full_title), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(kioskNoticeFullKey)).data, l10n.kiosk_notice_full);
      // Отметки «Я ознакомлен(а)» нет (P-002 §14.4).
      expect(find.byType(Checkbox), findsNothing);
      await tester.tap(find.byKey(kioskNoticeCloseKey));
      await tester.pumpAndSettle();
      expect(find.byKey(kioskNoticeFullKey), findsNothing);
      expect(find.byKey(KioskCheckoutScreen.screenKey), findsOneWidget);
    });
  }

  testWidgets('номер — только экранной клавиатурой: поле только для чтения, маска 3-3-3, «Получить код» при 9 цифрах', (
    tester,
  ) async {
    final _Stand s = _Stand(tester);
    await s.pump();
    await s.open();
    final EditableText phone = tester.widget<EditableText>(
      find.descendant(of: find.byKey(KioskPhoneStep.fieldKey), matching: find.byType(EditableText)),
    );
    expect((phone.readOnly, phone.keyboardType, phone.autofillHints), (true, TextInputType.none, null));
    expect(s.enabled(KioskPhoneStep.getCodeKey), isFalse);
    await s.keypad('55500010');
    expect(s.enabled(KioskPhoneStep.getCodeKey), isFalse);
    await s.keypad('1');
    expect(find.text('555 000 101'), findsOneWidget);
    expect(s.state.phoneDigits, kPhoneA);
    expect(s.enabled(KioskPhoneStep.getCodeKey), isTrue);
    // Номер не попадает в адрес.
    expect(s.location, isNot(contains(kPhoneA)));
    // «стереть» и Enter (активная основная кнопка — «Получить код» ещё недоступна при 8 цифрах).
    await tester.tap(find.byKey(KioskKeypad.keyFor('backspace')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(s.f.repo.otpCalls, isEmpty);
    await s.keypad('1');
    s.f.repo.otpAnswers.add(otpSent(kChallengeA));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(s.f.repo.otpCalls.single.phone, '+996$kPhoneA');
    expect(find.byKey(KioskCodeStep.fieldKey), findsOneWidget);
  });

  testWidgets('шаг «Код»: маска номера, таймер повторного кода, адрес step=code, «Отправить заявку» при 6 цифрах', (
    tester,
  ) async {
    final _Stand s = _Stand(tester);
    await s.pump();
    await s.toCode();
    expect(find.text(l10n.kiosk_code_title), findsOneWidget);
    expect(find.text(l10n.kiosk_code_sent_to('+996 5** *** *01')), findsOneWidget);
    expect(find.text(l10n.kiosk_resend_in(60)), findsOneWidget);
    expect(s.location, '/kiosk/checkout?step=code');
    final EditableText code = tester.widget<EditableText>(
      find.descendant(of: find.byKey(KioskCodeStep.fieldKey), matching: find.byType(EditableText)),
    );
    expect((code.readOnly, code.keyboardType, code.autofillHints), (true, TextInputType.none, null));
    expect(s.enabled(KioskCodeStep.sendKey), isFalse);
    await s.keypad(kCode);
    expect(s.enabled(KioskCodeStep.sendKey), isTrue);
    expect(s.f.repo.orderCalls, isEmpty, reason: 'автоперехода при 6-й цифре нет');
    // Таймер: от `resendAt` контроллера раз в секунду; по нулю — «Получить код» повторно на тот же номер.
    s.f.advance(const Duration(seconds: 50));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(l10n.kiosk_resend_in(10)), findsOneWidget);
    s.f.advance(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(KioskCodeStep.resendKey), findsOneWidget);
    s.f.repo.otpAnswers.add(otpSent(kChallengeB));
    await tester.tap(find.byKey(KioskCodeStep.resendKey));
    await tester.pumpAndSettle();
    expect(s.f.repo.otpCalls.map((c) => c.phone), <String>['+996$kPhoneA', '+996$kPhoneA']);
    expect(s.state.challengeId, kChallengeB);
    // «Изменить номер» — шаг «Телефон» с прежним номером в поле.
    await tester.tap(find.byKey(KioskCodeStep.changePhoneKey));
    await tester.pumpAndSettle();
    expect(find.text('555 000 101'), findsOneWidget);
    expect(s.location, '/kiosk/checkout?step=phone');
  });

  testWidgets('T-KIOSK-052 02 SCR-52.4 (версия 1.28): A → B → A раньше 60 с, 429 для A — нет «Код отправлен на», '
      '«Новый код можно получить через …», клавиатура не вводит, «Отправить заявку» недоступна; по таймеру '
      '«Получить код» → 202 — обычный шаг «Код»', (tester) async {
    final _Stand s = _Stand(tester);
    await s.pump();
    await s.toCode();
    // «Изменить номер» → номер B → код B (код A вытеснен).
    await tester.tap(find.byKey(KioskCodeStep.changePhoneKey));
    await tester.pumpAndSettle();
    for (var i = 0; i < KioskCheckoutRules.phoneLength; i++) {
      await tester.tap(find.byKey(KioskKeypad.keyFor('backspace')));
      await tester.pump();
    }
    await s.keypad(kPhoneB);
    s.f.repo.otpAnswers.add(otpSent(kChallengeB));
    await tester.tap(find.byKey(KioskPhoneStep.getCodeKey));
    await tester.pumpAndSettle();
    expect(s.state.challengeId, kChallengeB);
    // Снова номер A раньше 60 с — `429 OTP_RATE_LIMITED`.
    await tester.tap(find.byKey(KioskCodeStep.changePhoneKey));
    await tester.pumpAndSettle();
    for (var i = 0; i < KioskCheckoutRules.phoneLength; i++) {
      await tester.tap(find.byKey(KioskKeypad.keyFor('backspace')));
      await tester.pump();
    }
    await s.keypad(kPhoneA);
    s.f.repo.otpAnswers.add(refused(const AuthFailure(AuthReason.otpRateLimited, retryAfter: Duration(seconds: 45))));
    await tester.tap(find.byKey(KioskPhoneStep.getCodeKey));
    await tester.pumpAndSettle();

    expect(find.byKey(KioskCodeStep.fieldKey), findsOneWidget);
    expect(s.state.challengeId, isNull);
    expect(find.byKey(KioskCodeStep.sentToKey), findsNothing, reason: 'не «Код отправлен на …» без кода');
    expect(find.textContaining('Код отправлен на'), findsNothing);
    expect(find.text(l10n.kiosk_code_wait(45)), findsOneWidget);
    expect(find.byKey(KioskCodeStep.messageKey), findsNothing, reason: 'без текста ошибки');
    await s.keypad(kCode);
    expect(s.state.codeDigits, isEmpty, reason: 'клавиатура недоступна');
    expect(s.enabled(KioskCodeStep.sendKey), isFalse);

    // Таймер кончился — «Получить код» → `202`: обычный шаг «Код».
    s.f.advance(const Duration(seconds: 45));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(KioskCodeStep.waitKey), findsNothing);
    s.f.repo.otpAnswers.add(otpSent(kChallengeA));
    await tester.tap(find.byKey(KioskCodeStep.resendKey));
    await tester.pumpAndSettle();
    expect(s.state.challengeId, kChallengeA);
    expect(find.text(l10n.kiosk_code_sent_to('+996 5** *** *01')), findsOneWidget);
    await s.keypad(kCode);
    expect(s.enabled(KioskCodeStep.sendKey), isTrue);
  });

  testWidgets('отправка: «Отправляем заявку…» — кнопки, клавиатура и «Назад» недоступны; затем SCR-53 и «Готово»', (
    tester,
  ) async {
    final _Stand s = _Stand(tester);
    await s.pump();
    await s.toCode();
    await s.keypad(kCode);
    final Completer<Result<KioskOrderAccepted>> slow = Completer<Result<KioskOrderAccepted>>();
    s.f.repo.orderAnswers.add(() => slow.future);
    await tester.tap(find.byKey(KioskCodeStep.sendKey));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(KioskSendingView.overlayKey), findsOneWidget);
    expect(find.text(l10n.kiosk_sending), findsOneWidget);
    expect(tester.widget<AppIconButton>(find.byKey(KioskCheckoutScreen.backKey)).onPressed, isNull);
    // Повторное нажатие, Enter, системное «Назад» и Esc — без второго запроса и без ухода с экрана.
    await tester.tap(find.byKey(KioskCodeStep.sendKey), warnIfMissed: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(s.f.repo.orderCalls, hasLength(1));
    expect(find.byKey(KioskCodeStep.fieldKey), findsOneWidget);

    slow.complete(orderAccepted());
    await tester.pumpAndSettle();
    expect(s.location, '/kiosk/done');
    expect(find.byKey(KioskDoneScreen.screenKey), findsOneWidget);
    expect(find.text(l10n.kiosk_order_sent_title(kPublicNumber)), findsOneWidget);
    expect(find.text(l10n.kiosk_order_sent_body), findsOneWidget);
    expect(find.text(l10n.kiosk_price_note), findsOneWidget);
    expect(find.textContaining('сом'), findsNothing, reason: 'сумм на SCR-53 нет');
    expect(find.byKey(KioskCheckoutScreen.screenKey), findsNothing);
    expect(s.secure.calls.last, isFalse);
    // В адресе номера заявки нет; «Назад» в оформление не возвращает.
    expect(s.location, isNot(contains(kPublicNumber)));

    await tester.tap(find.byKey(KioskDoneScreen.doneKey));
    await tester.pumpAndSettle();
    expect(s.startOvers, 1);
    expect(s.location, KioskPaths.showcase);
    expect(find.byKey(_showcaseKey), findsOneWidget);
    expect((s.state.publicNumber, s.state.phoneDigits, s.state.challengeId), (null, '', null));
  });

  testWidgets(
    'SCR-53: через kiosk_done_seconds без касаний — тот же сброс; «Готово» во время сброса и «Назад» — один сброс',
    (tester) async {
      final _Stand s = _Stand(tester);
      await s.pump();
      await s.toCode();
      await s.keypad(kCode);
      s.f.repo.answerOrder(orderAccepted());
      await tester.tap(find.byKey(KioskCodeStep.sendKey));
      await tester.pumpAndSettle();
      expect(find.byKey(KioskDoneScreen.screenKey), findsOneWidget);
      await tester.pump(const Duration(seconds: 59));
      expect(s.startOvers, 0);
      expect(find.byKey(KioskDoneScreen.screenKey), findsOneWidget);
      s.startOverGate = Completer<void>();
      await tester.pump(const Duration(seconds: 1));
      expect(s.startOvers, 1);
      // Сброс идёт: «Готово» и системное «Назад» — без второго сброса.
      await tester.tap(find.byKey(KioskDoneScreen.doneKey), warnIfMissed: false);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(s.startOvers, 1);
      s.startOverGate!.complete();
      await tester.pumpAndSettle();
      expect(s.location, KioskPaths.showcase);
    },
  );

  testWidgets('SCR-53: системное «Назад» = «Готово»', (tester) async {
    final _Stand s = _Stand(tester);
    await s.pump();
    await s.toCode();
    await s.keypad(kCode);
    s.f.repo.answerOrder(orderAccepted());
    await tester.tap(find.byKey(KioskCodeStep.sendKey));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect((s.startOvers, s.location), (1, KioskPaths.showcase));
  });

  testWidgets('отказ по остатку — SCR-51 под drawer и «Товара стало меньше…»; снова «Оформить заявку» — шаг «Код»', (
    tester,
  ) async {
    final _Stand s = _Stand(tester);
    int stockMarks = 0;
    await s.pump(
      extra: <Override>[
        kioskCartMarkStockChangedProvider.overrideWithValue(
          ([List<KioskCartStockConflict> _ = const <KioskCartStockConflict>[]]) => stockMarks++,
        ),
      ],
    );
    await s.toCode();
    await s.keypad(kCode);
    s.f.repo.answerOrder(refused(const ConflictFailure(ConflictKind.stockInsufficient)));
    await tester.tap(find.byKey(KioskCodeStep.sendKey));
    await tester.pumpAndSettle();
    expect(find.byKey(_showcaseKey), findsOneWidget);
    expect(s.location, KioskPaths.showcase);
    // UI-51-018: «Товара стало меньше…» — баннер над строками drawer (отметка корзины), не снекбар.
    expect(stockMarks, 1);
    expect(find.text(l10n.kiosk_stock_changed), findsNothing);
    expect(s.f.cart.refreshes, 1);
    s.f.repo.answerOrder(orderAccepted());
    await s.open();
    expect(find.byKey(KioskCodeStep.fieldKey), findsOneWidget);
    expect(s.location, '/kiosk/checkout?step=code');
    expect(s.enabled(KioskCodeStep.sendKey), isTrue, reason: 'тот же код в поле (окно 60 с)');
    await tester.tap(find.byKey(KioskCodeStep.sendKey));
    await tester.pumpAndSettle();
    expect(s.location, '/kiosk/done');
    expect(s.f.repo.orderCalls.map((c) => c.request.challengeId).toSet(), <String>{kChallengeA});
  });

  testWidgets('UI-52, T-ANIM-012 (указание владельца 2026-11-18): после неверного кода ячейки красные до первой цифры; '
      'первая цифра — обычные ячейки, текст ошибки снят (03 §9.5 ред. 1.24)', (tester) async {
    final _Stand s = _Stand(tester);
    await s.pump();
    await s.toCode();
    await s.keypad('111111');
    s.f.repo.answerOrder(refused(const AuthFailure(AuthReason.otpInvalid, attemptsLeft: 4)));
    await tester.tap(find.byKey(KioskCodeStep.sendKey));
    await tester.pumpAndSettle();
    expect(find.text(l10n.kiosk_code_invalid(4)), findsOneWidget);
    final DsColors c = tester.element(find.byKey(KioskCodeStep.fieldKey)).colors;
    List<Color> cells() => tester
        .widgetList<Container>(
          find.descendant(
            of: find.byKey(KioskCodeStep.fieldKey),
            matching: find.byWidgetPredicate(
              (Widget w) =>
                  w is Container &&
                  w.decoration is BoxDecoration &&
                  (w.decoration! as BoxDecoration).border is Border &&
                  (w.decoration! as BoxDecoration).borderRadius != null,
            ),
          ),
        )
        .map((Container w) => ((w.decoration! as BoxDecoration).border! as Border).top.color)
        .toList();
    expect(cells(), hasLength(KioskKeypad.smsCodeLength));
    expect(cells().every((Color b) => b == c.error), isTrue, reason: 'момент ошибки: поле пустое, ячейки `error`');
    await s.keypad('5');
    expect(cells().any((Color b) => b == c.error), isFalse, reason: 'новая цифра красной не бывает');
    expect(find.text(l10n.kiosk_code_invalid(4)), findsNothing);
  });

  testWidgets('ошибки — нейтральные тексты: неверный код, код не действует, отказ 1С, лимит', (tester) async {
    final _Stand s = _Stand(tester);
    await s.pump();
    await s.toCode();
    await s.keypad('111111');
    s.f.repo.answerOrder(refused(const AuthFailure(AuthReason.otpInvalid, attemptsLeft: 4)));
    await tester.tap(find.byKey(KioskCodeStep.sendKey));
    await tester.pumpAndSettle();
    expect(find.text(l10n.kiosk_code_invalid(4)), findsOneWidget);
    await s.keypad(kCode);
    s.f.repo.answerOrder(refused(const AuthFailure(AuthReason.otpExpired)));
    await tester.tap(find.byKey(KioskCodeStep.sendKey));
    await tester.pumpAndSettle();
    expect(find.text(l10n.kiosk_code_expired), findsOneWidget);
    await s.keypad(kCode);
    s.f.repo.answerOrder(
      refused(
        const ServerFailure(
          code: 'ONEC_REJECTED',
          status: 422,
          details: <String, Object?>{
            'onec': <String, Object?>{'message': 'Превышен лимит долга клиента'},
          },
        ),
      ),
    );
    await tester.tap(find.byKey(KioskCodeStep.sendKey));
    await tester.pumpAndSettle();
    expect(find.text(l10n.kiosk_order_failed), findsOneWidget);
    expect(find.textContaining('лимит долга'), findsNothing);
    // Шаг «Телефон»: лимит планшета — «Обратитесь к продавцу».
    await tester.tap(find.byKey(KioskCodeStep.changePhoneKey));
    await tester.pumpAndSettle();
    s.f.repo.otpAnswers.add(refused(const ServerFailure(code: 'KIOSK_RATE_LIMITED', status: 429)));
    await tester.tap(find.byKey(KioskPhoneStep.getCodeKey));
    await tester.pumpAndSettle();
    expect(find.text(l10n.kiosk_call_seller), findsOneWidget);
  });

  testWidgets('без связи — баннер «Нет связи…», «Получить код» недоступна; связь вернулась — предпросмотр снова', (
    tester,
  ) async {
    final _Stand s = _Stand(tester);
    s.f.checkout.answers.add(refused(const NetworkFailure(NetworkFailureKind.offline)));
    await s.pump(online: OnlineStatus.offline);
    await s.open();
    expect(find.byKey(KioskCheckoutScreen.offlineKey), findsOneWidget);
    expect(find.text(l10n.kiosk_offline), findsOneWidget);
    await s.keypad(kPhoneA);
    expect(s.enabled(KioskPhoneStep.getCodeKey), isFalse);
    expect(find.text(l10n.kiosk_order_failed), findsNothing);
    s.container.read(_online.notifier).set(OnlineStatus.online);
    await tester.pumpAndSettle();
    expect(find.byKey(KioskCheckoutScreen.offlineKey), findsNothing);
    expect(s.f.checkout.calls, hasLength(2));
    expect(s.enabled(KioskPhoneStep.getCodeKey), isTrue);
  });

  testWidgets('состояние планшета (426, полноэкранные, метка сброса) — «Получить код» недоступна', (tester) async {
    final _Stand s = _Stand(tester);
    await s.pump(extra: <Override>[cartOrderingBlockedProvider.overrideWithValue(true)]);
    await s.open();
    await s.keypad(kPhoneA);
    expect(s.enabled(KioskPhoneStep.getCodeKey), isFalse);
  });

  for (final (String name, Size size) in <(String, Size)>[('expanded', _expanded), ('medium', _medium)]) {
    testWidgets('T-KIOSK-050 UI-51-014 ($name): 426 — баннер «Планшет нужно обновить» с иконкой system_update под '
        'шапкой UI-52-001 во всю ширину; без связи — «Нет связи…» с иконкой wifi_off; 426 и без связи — один баннер', (
      tester,
    ) async {
      final _Stand s = _Stand(tester);
      await s.pump(
        size: size,
        online: OnlineStatus.offline,
        extra: <Override>[
          kioskStatusProvider.overrideWithValue(KioskStatus.updateNeeded),
          cartOrderingBlockedProvider.overrideWithValue(true),
        ],
      );
      await s.open();
      final Finder banner = find.byKey(KioskCheckoutScreen.updateKey);
      expect(banner, findsOneWidget);
      expect(find.descendant(of: banner, matching: find.text(l10n.kiosk_update_needed)), findsOneWidget);
      expect(find.descendant(of: banner, matching: find.byIcon(Icons.system_update_rounded)), findsOneWidget);
      final double screenTop = tester.getTopLeft(find.byKey(KioskCheckoutScreen.screenKey)).dy;
      expect(tester.getTopLeft(banner).dy, greaterThanOrEqualTo(screenTop + 64 - 0.01), reason: 'под шапкой 64');
      expect(
        tester.getTopLeft(banner).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(find.byKey(KioskCheckoutScreen.titleKey)).dy),
      );
      expect(tester.getSize(banner).width, closeTo(size.width, 0.01), reason: 'во всю ширину');
      expect(find.byKey(KioskCheckoutScreen.offlineKey), findsNothing, reason: 'один баннер');
      expect(
        find.descendant(of: find.byKey(KioskCheckoutScreen.screenKey), matching: find.byType(ErrorState)),
        findsOneWidget,
      );
      await s.keypad(kPhoneA);
      expect(s.enabled(KioskPhoneStep.getCodeKey), isFalse);

      // Только без связи — «Нет связи…» на том же месте.
      await tester.pumpWidget(const SizedBox());
      final _Stand offline = _Stand(tester);
      offline.f.checkout.answers.add(refused(const NetworkFailure(NetworkFailureKind.offline)));
      await offline.pump(size: size, online: OnlineStatus.offline);
      await offline.open();
      final Finder noLink = find.byKey(KioskCheckoutScreen.offlineKey);
      expect(noLink, findsOneWidget);
      expect(find.descendant(of: noLink, matching: find.byIcon(Icons.wifi_off_rounded)), findsOneWidget);
      expect(tester.getTopLeft(noLink).dy, greaterThanOrEqualTo(screenTop + 64 - 0.01));
      expect(find.byKey(KioskCheckoutScreen.updateKey), findsNothing);
    });

    testWidgets('AC-A11Y-023 A11Y-003 ($name): «Подробнее», «Изменить номер» и повторное «Получить код» — цель не '
        'меньше 48 lp (размер M)', (tester) async {
      final _Stand s = _Stand(tester);
      await s.pump(size: size);
      await s.open();
      expect(tester.getSize(find.byKey(KioskNoticeBlock.moreKey)).height, greaterThanOrEqualTo(48));
      expect(tester.widget<AppButton>(find.byKey(KioskNoticeBlock.moreKey)).size, AppButtonSize.m);
      await s.keypad(kPhoneA);
      s.f.repo.otpAnswers.add(otpSent(kChallengeA));
      await tester.tap(find.byKey(KioskPhoneStep.getCodeKey));
      await tester.pumpAndSettle();
      expect(find.byKey(KioskCodeStep.fieldKey), findsOneWidget);
      expect(tester.getSize(find.byKey(KioskCodeStep.changePhoneKey)).height, greaterThanOrEqualTo(48));
      // Таймер до нуля — повторное «Получить код».
      s.f.advance(const Duration(seconds: 60));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(KioskCodeStep.resendKey), findsOneWidget);
      expect(tester.getSize(find.byKey(KioskCodeStep.resendKey)).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(find.byKey(KioskCodeStep.changePhoneKey)).height, greaterThanOrEqualTo(48));
    });
  }

  testWidgets('«Назад»: Esc и системное — с шага «Код» на «Телефон», с «Телефон» — SCR-51; память очищена', (
    tester,
  ) async {
    final _Stand s = _Stand(tester);
    await s.pump();
    await s.toCode();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(KioskPhoneStep.fieldKey), findsOneWidget);
    expect(s.state.step.value, 'phone');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(_showcaseKey), findsOneWidget);
    expect((s.state.phoneDigits, s.state.challengeId), ('', null));
  });

  testWidgets('пустая корзина — SCR-51', (tester) async {
    final _Stand s = _Stand(tester);
    s.f.cart.cart = null;
    await s.pump();
    await tester.tap(find.byKey(_openKey));
    await tester.pumpAndSettle();
    expect(find.byKey(_showcaseKey), findsOneWidget);
    expect(s.f.checkout.calls, isEmpty);
  });

  testWidgets('прямой путь и перезапуск: /kiosk/checkout?step=code и /kiosk/done без номера — /kiosk', (tester) async {
    final _Stand s = _Stand(tester);
    await s.pump(initial: '/kiosk/checkout?step=code');
    expect(s.location, KioskPaths.showcase);
    expect(s.f.checkout.calls, isEmpty);
    s.router.go(KioskPaths.done);
    await tester.pumpAndSettle();
    expect(s.location, KioskPaths.showcase);
    expect(s.startOvers, 0);
  });

  testWidgets('без привязки портов маршруты шагов — пустой каркас режима', (tester) async {
    final _Stand s = _Stand(tester);
    await s.pump(initial: KioskPaths.checkout, bound: false);
    expect(s.location, KioskPaths.checkout);
    expect(find.byKey(KioskShellScreen.screenKey), findsOneWidget);
    expect(find.byKey(KioskPhoneStep.fieldKey), findsNothing);
  });

  test('пути фичи совпадают с KioskPaths маршрутов', () {
    expect(
      (KioskCheckoutLocations.showcase, KioskCheckoutLocations.checkout, KioskCheckoutLocations.done),
      (KioskPaths.showcase, KioskPaths.checkout, KioskPaths.done),
    );
  });
}
