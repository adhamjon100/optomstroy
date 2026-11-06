// Обвязка тестов автосброса планшета магазина FLOW-045 (13 TAB-2-05): фейк корзины планшета с меткой сброса без сети
// (семантика `KioskCartSync.reset`), переключаемые состояние планшета и сеть, буфер обмена платформы, стенд маршрутов
// режима (`kioskRoutes()`, каркас `KioskShellScreen`) с телом витрины-заглушкой (состояние — только в `State`, как у
// SCR-51) и шагами SCR-52 / SCR-53 на фейках оформления. Данные тестовые: UUID-заглушки, номера — шаблон
// `+996 555 000 xxx`, имён людей нет.
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
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/session_overlay.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/private_input_scope.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/sync/cart_sync.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart' as catalog;
import 'package:optomstroy/features/kiosk/kiosk_providers.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_checkout_controller.dart';
import 'package:optomstroy/features/kiosk/presentation/kiosk_idle_monitor.dart';
import 'package:optomstroy/features/kiosk/presentation/kiosk_reset_orchestrator.dart';

import '../../support/f_fakes.dart';
import 'checkout/kiosk_checkout_support.dart';

/// Новая корзина после сброса (тестовый UUID).
String newCartId(int n) => '0192f3a1-6c3e-7a1b-9f00-${(300 + n).toString().padLeft(12, '0')}';

/// Пустая корзина [id].
Cart newEmptyCart(String id) => Cart(id: id, status: CartStatus.active, items: const <CartLine>[], rowVersion: 1);

/// Корзина планшета (`KioskCartControl`) с семантикой `KioskCartSync.reset`: метка (только id) — до запроса, корзина на
/// экране сразу пуста; без сети запроса нет; `200` — метка снята, на экране новая корзина.
final class FakeKioskCartControl implements KioskCartControl {
  /// Корзина на экране.
  String? cart = kCartId;

  /// Метка сброса без сети.
  String? held;
  bool offline = false;
  int prepares = 0;

  /// Сколько раз запрос сброса ушёл на сервер (`request` вызван) и с каким id.
  final List<String?> requested = <String?>[];

  /// Журнал корзины: `prepare`, `reset:<id>`, `request:<id>` — порядок первых запросов.
  final List<String> journal = <String>[];

  @override
  String? get cartId => held == null ? cart : null;

  @override
  String? get pendingResetCartId => held;

  @override
  Future<void> prepare() async {
    prepares++;
    journal.add('prepare');
  }

  @override
  Future<Result<Cart>> reset(Future<Result<Cart>> Function(String? cartId) request) async {
    final String? id = held ?? cart;
    journal.add('reset:$id');
    if (id != null) {
      held = id;
      cart = null;
    }
    if (offline) return const FailureResult<Cart>(NetworkFailure(NetworkFailureKind.offline));
    requested.add(id);
    journal.add('request:$id');
    final Result<Cart> r = await request(id);
    if (r case Success<Cart>(:final Cart value)) {
      held = null;
      cart = value.id;
    }
    return r;
  }

  @override
  Future<Result<Qty>> addStepWithUnit(CartLineKey key, {String? unitId, Money? priceSnapshot}) =>
      throw UnimplementedError('«В корзину» в тестах сброса не нужно');
}

/// Состояние планшета теста (переключается).
final kioskTestStatusProvider = NotifierProvider<KioskTestStatus, KioskStatus>(KioskTestStatus.new);

final class KioskTestStatus extends Notifier<KioskStatus> {
  @override
  KioskStatus build() => KioskStatus.ready;

  void set(KioskStatus s) => state = s;
}

/// Сеть корзины теста (переключается).
final kioskTestOnlineProvider = NotifierProvider<KioskTestOnline, OnlineStatus>(KioskTestOnline.new);

final class KioskTestOnline extends Notifier<OnlineStatus> {
  @override
  OnlineStatus build() => OnlineStatus.online;

  void set(OnlineStatus s) => state = s;
}

/// Буфер обмена платформы (`SystemChannels.platform`): значение и вызовы `Clipboard.setData`.
final class ClipboardStub {
  String? text;
  final List<String?> sets = <String?>[];

  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, _handle);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  }

  Future<Object?> _handle(MethodCall call) async {
    switch (call.method) {
      case 'Clipboard.setData':
        final Map<Object?, Object?> args = call.arguments as Map<Object?, Object?>;
        text = args['text'] as String?;
        sets.add(text);
      case 'Clipboard.getData':
        return <String, Object?>{'text': text};
      case 'Clipboard.hasStrings':
        return <String, Object?>{'value': (text ?? '').isNotEmpty};
    }
    return null;
  }
}

/// Ключи тела витрины-заглушки.
abstract final class ShowcaseKeys {
  static const Key root = ValueKey<String>('test-showcase');
  static const Key query = ValueKey<String>('test-showcase-query');
  static const Key search = ValueKey<String>('test-showcase-search');
  static const Key sheet = ValueKey<String>('test-showcase-sheet');
  static const Key sheetBody = ValueKey<String>('test-showcase-sheet-body');
  static const Key checkout = ValueKey<String>('test-showcase-checkout');
  static const Key startOver = ValueKey<String>('test-showcase-start-over');
}

/// Тело витрины SCR-51 теста: «поиск» — только в `State` (как у `KioskCatalogView`), лист без страницы (как drawer и
/// слой карточки), «Оформить заявку» (`push` SCR-52), «Начать заново» (порт `catalogKioskStartOverProvider`).
class TestShowcase extends ConsumerStatefulWidget {
  const TestShowcase({super.key});

  @override
  ConsumerState<TestShowcase> createState() => _TestShowcaseState();
}

class _TestShowcaseState extends ConsumerState<TestShowcase> {
  String _query = '';

  @override
  Widget build(BuildContext context) => Column(
    key: ShowcaseKeys.root,
    children: <Widget>[
      Text('q:$_query', key: ShowcaseKeys.query),
      TextButton(
        key: ShowcaseKeys.search,
        onPressed: () => setState(() => _query = 'смеситель'),
        child: const Text('search'),
      ),
      TextButton(
        key: ShowcaseKeys.sheet,
        onPressed: () => unawaited(
          showGeneralDialog<void>(
            context: context,
            barrierDismissible: true,
            barrierLabel: 'sheet',
            pageBuilder: (BuildContext context, _, _) => const Align(
              alignment: Alignment.centerRight,
              child: Material(key: ShowcaseKeys.sheetBody, child: SizedBox(width: 420, height: 800)),
            ),
          ),
        ),
        child: const Text('sheet'),
      ),
      TextButton(
        key: ShowcaseKeys.checkout,
        onPressed: () => unawaited(GoRouter.of(context).push<void>('/kiosk/checkout?step=phone')),
        child: const Text('checkout'),
      ),
      TextButton(
        key: ShowcaseKeys.startOver,
        onPressed: () => unawaited(ref.read(catalog.catalogKioskStartOverProvider)?.call()),
        child: const Text('start over'),
      ),
    ],
  );
}

/// Стенд: маршруты режима, корзина планшета, фейки оформления, порт «Начать заново» → оркестратор (как корень).
final class KioskResetStand {
  KioskResetStand(this.tester);

  final WidgetTester tester;
  final KioskCheckoutFakes f = KioskCheckoutFakes();
  final FakeKioskCartControl cart = FakeKioskCartControl();
  final FakeCartRepository carts = FakeCartRepository();
  final ClipboardStub clipboard = ClipboardStub();
  late GoRouter router;
  late ProviderContainer container;

  String get location => router.state.uri.toString();
  KioskIdleController get idle => container.read(kioskIdleControllerProvider);
  KioskResetOrchestrator get orchestrator => container.read(kioskResetOrchestratorProvider);
  KioskCheckoutState get checkout => container.read(kioskCheckoutControllerProvider);
  KioskCheckoutController get checkoutController => container.read(kioskCheckoutControllerProvider.notifier);

  void status(KioskStatus s) => container.read(kioskTestStatusProvider.notifier).set(s);
  void online(OnlineStatus s) => container.read(kioskTestOnlineProvider.notifier).set(s);

  Future<void> pump({
    String initial = '/kiosk',
    KioskTimings timings = const KioskTimings(),
    bool bindCart = true,
    KioskCartControl? control,
    List<Override> extra = const <Override>[],
  }) async {
    tester.view
      ..physicalSize = const Size(1280, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    clipboard.install(tester);
    router = GoRouter(initialLocation: initial, routes: kioskRoutes());
    addTearDown(router.dispose);
    container = ProviderContainer(
      overrides: <Override>[
        ...f.overrides(),
        kioskStatusProvider.overrideWith((Ref ref) => ref.watch(kioskTestStatusProvider)),
        cartOnlineStatusProvider.overrideWith((Ref ref) => ref.watch(kioskTestOnlineProvider)),
        kioskTimingsProvider.overrideWithValue(timings),
        kioskCartControlProvider.overrideWithValue(control ?? (bindCart ? cart : null)),
        cartRepositoryProvider.overrideWithValue(carts),
        kioskCatalogBodyProvider.overrideWithValue(
          (BuildContext context, KioskCatalogArgs args) => const TestShowcase(),
        ),
        catalog.catalogKioskStartOverProvider.overrideWith(kioskStartOverPort),
        ...extra,
      ],
    );
    addTearDown(container.dispose);
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
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: PrivateInputScope(enabled: true, child: child!),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Покупатель ввёл номер A и код и получил `challengeId` (память контроллера оформления).
  Future<void> enterPhoneAndCode() async {
    await checkoutController.open();
    for (final String d in kPhoneA.split('')) {
      checkoutController.typePhoneDigit(d);
    }
    f.repo.otpAnswers.add(otpSent(kChallengeA));
    await checkoutController.requestCode();
    for (final String d in kCode.split('')) {
      checkoutController.typeCodeDigit(d);
    }
  }

  /// Заявка принята — номер для SCR-53 (память контроллера).
  Future<void> submitOrder() async {
    await enterPhoneAndCode();
    f.repo.answerOrder(orderAccepted());
    await checkoutController.submit();
  }

  /// Перевести приложение в [states] по порядку (как платформа: inactive → hidden → paused и обратно).
  Future<void> lifecycle(List<AppLifecycleState> states) async {
    for (final AppLifecycleState s in states) {
      tester.binding.handleAppLifecycleStateChanged(s);
      await tester.pump();
    }
  }

  /// Экран погашен или приложение ушло в фон.
  Future<void> toBackground() => lifecycle(const <AppLifecycleState>[
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]);

  /// Экран включён, приложение снова на переднем плане.
  Future<void> toForeground() => lifecycle(const <AppLifecycleState>[
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]);
}
