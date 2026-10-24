// HidScanScope (HID «без экрана», 02 п. 2.2.11): скан → GET /search/barcode → SCR-14;
// не найдено → SCR-11 + снекбар; «сразу в корзину» — добавление со снекбаром; ручной ввод — без действий.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/scan/domain/scan_lookup.dart';
import 'package:optomstroy/features/scan/presentation/hid_scan_scope.dart';
import 'package:optomstroy/features/scan/scan_providers.dart';

import 'support/scan_fakes.dart';

LogicalKeyboardKey _digit(String ch) => LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + int.parse(ch));

void main() {
  late FakeScanLookup lookup;
  late FakeScanCart cart;
  late Duration now;

  setUp(() {
    lookup = FakeScanLookup()..online[eanFound] = const Success<ScanLookupResult>(frap);
    cart = FakeScanCart();
    now = Duration.zero;
  });

  Future<void> pumpApp(WidgetTester tester, {bool addsToCart = false}) async {
    final router = GoRouter(
      initialLocation: '/catalog',
      routes: <RouteBase>[
        ShellRoute(
          builder: (context, state, child) => HidScanScope(child: child),
          routes: <RouteBase>[
            GoRoute(
              path: '/catalog',
              builder: (_, _) => const Scaffold(body: Text('catalog')),
            ),
            GoRoute(
              path: '/catalog/search',
              builder: (_, state) => Scaffold(body: Text('search:${state.uri}')),
            ),
            GoRoute(
              path: '/catalog/p/:productId',
              builder: (_, state) => Scaffold(body: Text('product:${state.uri}')),
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          scannerWedgeServiceProvider.overrideWith((ref) {
            final s = ScannerWedgeService(now: () => now);
            ref.onDispose(s.dispose);
            return s;
          }),
          scanBarcodeLookupProvider.overrideWithValue(lookup),
          scanCartPortProvider.overrideWithValue(cart),
          scanAddsToCartProvider.overrideWithValue(addsToCart),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          theme: AppTheme.light(),
          locale: const Locale('ru'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> scan(WidgetTester tester, String code, {Duration step = const Duration(milliseconds: 8)}) async {
    for (final ch in code.split('')) {
      now += step;
      await tester.sendKeyDownEvent(_digit(ch), character: ch);
      await tester.sendKeyUpEvent(_digit(ch));
    }
    now += step;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
  }

  testWidgets('HID-скан существующего кода → SCR-14 найденного варианта', (tester) async {
    await pumpApp(tester);
    await scan(tester, eanFound);
    expect(lookup.onlineCalls, <String>[eanFound]);
    expect(find.text('product:/catalog/p/p-frap?variantId=v-frap-chrome'), findsOneWidget);
  });

  testWidgets('не найдено → снекбар «Штрихкод … не найден» и SCR-11 с кодом', (tester) async {
    await pumpApp(tester);
    await scan(tester, eanMissing);
    expect(find.text(ru.scan_not_found(eanMissing)), findsOneWidget);
    expect(find.text('search:/catalog/search?q=$eanMissing'), findsOneWidget);
  });

  testWidgets('«Сразу добавлять в корзину» → +1 шаг и снекбар «Отсканировано … · Отменить»', (tester) async {
    await pumpApp(tester, addsToCart: true);
    await scan(tester, eanFound);
    expect(cart.added, <String>['v-frap-chrome']);
    expect(find.text(ru.scan_hid_result(frap.productName, '1', 'шт', eanFound)), findsOneWidget);
    expect(find.text('catalog'), findsOneWidget);
    // Каждый HID-скан — отдельное +1 (Q-207).
    await scan(tester, eanFound);
    expect(cart.added, hasLength(2));
    expect(cart.keys.toSet(), hasLength(2));
  });

  testWidgets('ручной ввод цифр + Enter — запроса нет', (tester) async {
    await pumpApp(tester);
    await scan(tester, eanFound, step: const Duration(milliseconds: 150));
    expect(lookup.onlineCalls, isEmpty);
    expect(find.text('catalog'), findsOneWidget);
  });
}
