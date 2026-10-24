// 13 RM-E-014 п. 5 (ядро §19.4; 10 AC-CAT-003; T-CAT-012): на собранном корне (`scanCartOverrides` из
// `app/di/overrides.dart`) HID-скан под `cashier` добавляет товар в локальную корзину-черновик (`cart_items_draft`),
// под `seller` — открывает карточку SCR-14; `Settings.scanAddsToCart` пользователя (SCR-42) меняет поведение.
// Адаптер `CartDraftScanCartPort`: +1 шаг / `suggestedQuantity` упаковки, «Отменить» возвращает прежнее количество.
// drift в памяти, фейковый поиск штрихкода; синтетические данные.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/app/di/overrides.dart';
import 'package:optomstroy/app/di/scan_cart_adapter.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/enums.dart' show RoleCode;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/data/draft/cart_draft_local_repository.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart' as catalog;
import 'package:optomstroy/features/scan/domain/scan_lookup.dart';
import 'package:optomstroy/features/scan/presentation/hid_scan_scope.dart';
import 'package:optomstroy/features/scan/scan_providers.dart';
import 'package:optomstroy/features/settings/settings_providers.dart' as settings;

import '../core/database/test_database.dart';
import '../features/scan/support/scan_fakes.dart';

final class _FixedUserSetting extends settings.UserScanAddsToCart {
  _FixedUserSetting(this.value);

  final bool? value;

  @override
  bool? build() => value;
}

LogicalKeyboardKey _digit(String ch) => LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + int.parse(ch));

void main() {
  configureSqliteForTests();
  late AppDatabase db;
  late CartDraftRepository draft;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    draft = CartDraftLocalRepository(
      database: () => db,
      ownerUserId: () => 'user-1',
      clock: FixedClock(DateTime.utc(2026, 10, 22, 9)),
    );
  });
  tearDown(() => db.close());

  group('CartDraftScanCartPort', () {
    test('+1 шаг в черновик; повторный скан — +1; «Отменить» возвращает прежнее количество', () async {
      final ScanCartPort port = CartDraftScanCartPort(draft);
      final ScanAddReceipt first = (await port.addStep(frap, idempotencyKey: 'k1')).valueOrNull!;
      final ScanAddReceipt second = (await port.addStep(frap, idempotencyKey: 'k2')).valueOrNull!;
      expect(first.quantityLabel, '1');
      expect((await draft.line(frap.variantId)).valueOrNull!.quantity, Qty.units(2));

      await port.undo(second);
      expect((await draft.line(frap.variantId)).valueOrNull!.quantity, Qty.units(1));
      await port.undo(first);
      expect((await draft.line(frap.variantId)).valueOrNull, isNull, reason: 'строки до скана не было');
    });

    test('штрихкод упаковки: suggestedQuantity в единицах упаковки', () async {
      const ScanLookupResult box = ScanLookupResult(
        productId: 'p-frap',
        productName: 'Смеситель Frap',
        variantId: 'v-frap-chrome',
        packagingId: 'pk-box',
        suggestedQuantity: Qty(1000),
        unitLabel: 'Коробка',
      );
      final ScanAddReceipt r = (await CartDraftScanCartPort(draft).addStep(box, idempotencyKey: 'k')).valueOrNull!;
      expect((r.quantityLabel, r.unitLabel), ('1', 'Коробка'));
      final CartDraftLine line = (await draft.line('v-frap-chrome', packagingId: 'pk-box')).valueOrNull!;
      expect(line.quantity, Qty.units(1));
    });
  });

  group('корень: скан по роли и настройке scan_adds_to_cart', () {
    late Duration now;

    Future<void> pumpRoot(WidgetTester tester, {required RoleCode role, bool? setting}) async {
      now = Duration.zero;
      final FakeScanLookup lookup = FakeScanLookup()..online[eanFound] = const Success<ScanLookupResult>(frap);
      final GoRouter router = GoRouter(
        initialLocation: '/catalog',
        routes: <RouteBase>[
          ShellRoute(
            builder: (BuildContext context, GoRouterState state, Widget child) => HidScanScope(child: child),
            routes: <RouteBase>[
              GoRoute(
                path: '/catalog',
                builder: (_, _) => const Scaffold(body: Text('catalog')),
              ),
              GoRoute(
                path: '/catalog/p/:productId',
                builder: (_, GoRouterState state) => Scaffold(body: Text('product:${state.uri.path}')),
              ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...scanCartOverrides,
            scannerWedgeServiceProvider.overrideWith((Ref ref) {
              final ScannerWedgeService s = ScannerWedgeService(now: () => now);
              ref.onDispose(s.dispose);
              return s;
            }),
            scanBarcodeLookupProvider.overrideWithValue(lookup),
            cartDraftRepositoryProvider.overrideWithValue(draft),
            catalog.catalogViewerRoleProvider.overrideWithValue(role),
            settings.userScanAddsToCartProvider.overrideWith(() => _FixedUserSetting(setting)),
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

    Future<void> scan(WidgetTester tester) async {
      for (final String ch in eanFound.split('')) {
        now += const Duration(milliseconds: 8);
        await tester.sendKeyDownEvent(_digit(ch), character: ch);
        await tester.sendKeyUpEvent(_digit(ch));
      }
      now += const Duration(milliseconds: 8);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
    }

    Future<int> lines() async => (await draft.lines()).valueOrNull!.length;

    testWidgets('cashier (умолчание): строка в cart_items_draft, карточка не открывается', (tester) async {
      await pumpRoot(tester, role: RoleCode.cashier);
      await scan(tester);
      expect(await tester.runAsync(lines), 1);
      expect(find.textContaining('product:'), findsNothing);
    });

    testWidgets('seller (умолчание): открывается карточка SCR-14, черновик не меняется', (tester) async {
      await pumpRoot(tester, role: RoleCode.seller);
      await scan(tester);
      expect(find.text('product:/catalog/p/p-frap'), findsOneWidget);
      expect(await tester.runAsync(lines), 0);
    });

    testWidgets('seller с scan_adds_to_cart = true: добавление в черновик', (tester) async {
      await pumpRoot(tester, role: RoleCode.seller, setting: true);
      await scan(tester);
      expect(await tester.runAsync(lines), 1);
    });

    testWidgets('cashier с scan_adds_to_cart = false: открывается карточка', (tester) async {
      await pumpRoot(tester, role: RoleCode.cashier, setting: false);
      await scan(tester);
      expect(find.text('product:/catalog/p/p-frap'), findsOneWidget);
      expect(await tester.runAsync(lines), 0);
    });

    test('owner и customer — без порта «сразу в корзину»', () {
      for (final RoleCode role in <RoleCode>[RoleCode.owner, RoleCode.customer]) {
        final ProviderContainer c = ProviderContainer(
          overrides: [
            ...scanCartOverrides,
            cartDraftRepositoryProvider.overrideWithValue(draft),
            catalog.catalogViewerRoleProvider.overrideWithValue(role),
            settings.userScanAddsToCartProvider.overrideWith(() => _FixedUserSetting(true)),
          ],
        );
        addTearDown(c.dispose);
        expect(c.read(scanCartPortProvider), isNull, reason: role.name);
      }
    });
  });
}
