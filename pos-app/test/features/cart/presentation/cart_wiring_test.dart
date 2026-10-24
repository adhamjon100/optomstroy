// RM-F-005: привязка корзины к этапу E и восстановление после перезапуска.
// - корень (`cartUiOverrides`): постоянная `CartPanel` на expanded и `CartFab` каталога, «+ Добавить» (`catalogCartPortProvider`
//   → `CartSync.addStep` варианта по умолчанию с ценой карточки как `priceSnapshot`; `owner` — без порта),
//   обработчик `cart.sync` в реестре очереди (`outboxHandlersProvider`);
// - SCR-20 на реальном `DriftCartSync` (drift в памяти, фейковый сервер): после «перезапуска» черновик показывается из
//   локальной копии с меткой «предварительно» до ответа `GET /cart` (AC-UI-20-013, D-32), затем — итоги сервера;
//   серия «+» → один `PUT` из очереди `cart.sync` с базой `rowVersion` копии.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/app/di/catalog_cart_adapter.dart';
import 'package:optomstroy/app/di/overrides.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/sync/outbox_queue.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/data/sync/drift_cart_sync.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/cart/domain/sync/cart_sync.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_fab_view.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_panel_view.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart' as catalog;
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_ports.dart';

import '../../../core/database/test_database.dart';
import '../../../support/f_fakes.dart';
import '../support/cart_test_support.dart';

const String owner = '00000000-0000-4000-8000-00000000000a';
final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));

final class _RecordingSync extends FakeCartSync {
  _RecordingSync(super.repo);

  final List<(CartLineKey, Money?)> added = <(CartLineKey, Money?)>[];
  Result<Qty>? addResult;

  @override
  Future<Result<Qty>> addStep(CartLineKey key, {Money? priceSnapshot}) async {
    added.add((key, priceSnapshot));
    return addResult ?? Success<Qty>(Qty.units(1));
  }
}

void main() {
  configureSqliteForTests();

  group('корень: корзина в каталоге', () {
    test('«+ Добавить» → addStep варианта по умолчанию; owner — без порта', () async {
      final _RecordingSync sync = _RecordingSync(FakeCartRepository());
      final ProductSummary p = ProductSummary(
        id: 'p-1',
        name: 'Смеситель Gappo G1007',
        defaultVariantId: 'v-1',
        price: Price(priceListId: 'pl', amount: Money.som(1650)),
      );
      expect((await CartSyncCatalogCartPort(sync).add(p)).isSuccess, isTrue);
      expect(sync.added.single, (const CartLineKey('v-1'), Money.som(1650)));
      expect(
        (await CartSyncCatalogCartPort(sync).add(const ProductSummary(id: 'p-2', name: 'Без варианта'))).isSuccess,
        isFalse,
      );

      // T-CART-022 / CART-024: сервер отклонил 201-ю строку — отказ (каталог не показывает «Добавлено») и текст
      // «Слишком много позиций (максимум 200)…» на любом классе окна.
      const ValidationFailure maxItems = ValidationFailure(
        errors: <FieldError>[FieldError(field: 'quantity', rule: 'max_items')],
      );
      sync.addResult = const FailureResult<Qty>(maxItems);
      final Result<void> rejected = await CartSyncCatalogCartPort(sync).add(p);
      expect(rejected.failureOrNull, maxItems);
      expect(CartSyncCatalogCartPort(sync).rejectionText(maxItems, l10n), l10n.cart_max_items('200'));
      expect(CartSyncCatalogCartPort(sync).rejectionText(const ValidationFailure(), l10n), isNull);
      expect(CartSyncCatalogCartPort(sync).rejectionText(const PermissionFailure(), l10n), isNull);

      for (final (RoleCode role, bool hasPort) in <(RoleCode, bool)>[
        (RoleCode.seller, true),
        (RoleCode.customer, true),
        (RoleCode.owner, false),
      ]) {
        final ProviderContainer c = ProviderContainer(
          overrides: <Override>[
            ...cartUiOverrides,
            cartSyncProvider.overrideWithValue(sync),
            catalog.catalogViewerRoleProvider.overrideWithValue(role),
          ],
        );
        addTearDown(c.dispose);
        expect(c.read(catalogCartPortProvider) != null, hasPort, reason: role.value);
      }
    });

    testWidgets('CartPanel (expanded) и CartFab (compact) каталога строит корзина', (tester) async {
      final FakeCartRepository repo = FakeCartRepository();
      final FakeCartSync sync = FakeCartSync(repo);
      serveCart(repo, canonCart());
      final ProviderContainer c = ProviderContainer(overrides: <Override>[...cartUiOverrides]);
      addTearDown(c.dispose);
      final CatalogCartPanelBuilder panel = c.read(catalogCartPanelProvider)!;
      final WidgetBuilder fab = c.read(catalogCartFabProvider)!;
      tester.view.physicalSize = const Size(390, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        cartApp(
          overrides: cartOverrides(sync: sync, repo: repo),
          cartBuilder: (BuildContext context) => Scaffold(
            body: Column(
              children: <Widget>[
                Expanded(child: panel(context)),
                fab(context),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CartPanelView), findsOneWidget);
      expect(find.byType(CartFabView), findsOneWidget);
      expect(find.text(PriceText.format(const Money(1600750), fixed2: true)), findsWidgets);
    });

    test('реестр очереди: обработчик cart.sync добавлен к избранному и «очистить недавние»', () {
      final ProviderContainer c = ProviderContainer(
        overrides: <Override>[...cartUiOverrides, cartRepositoryProvider.overrideWithValue(FakeCartRepository())],
      );
      addTearDown(c.dispose);
      final Set<String> types = <String>{
        for (final OutboxActionHandler h in c.read(outboxHandlersProvider)) ...h.types,
      };
      expect(
        types,
        containsAll(<String>[
          OutboxTypes.cartSync,
          OutboxTypes.notificationRead,
          OutboxTypes.favoriteAdd,
          OutboxTypes.recentClear,
        ]),
      );
    });
  });

  group('SCR-20 на DriftCartSync', () {
    late AppDatabase db;
    late FakeCartRepository repo;
    late OutboxQueue queue;
    late DriftCartSync sync;
    late bool offline;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      repo = FakeCartRepository();
      offline = false;
      sync = DriftCartSync(
        database: () => db,
        owner: () => owner,
        clock: FixedClock(cartNow),
        repository: repo,
        queue: () => queue,
        offline: () => offline,
      );
      queue = OutboxQueue(
        database: () => db,
        owner: () => owner,
        clock: FixedClock(cartNow),
        handlers: <OutboxActionHandler>[sync],
      );
      // Кэш каталога: названия строк офлайн.
      await db
          .into(db.localUnits)
          .insert(
            LocalUnitsCompanion.insert(
              code: 'pc',
              name: 'Штука',
              qtyPrecision: 0,
              id: const Value<String?>('u-pc'),
              shortName: const Value<String?>('шт'),
            ),
          );
      for (final CartLine l in canonCart().items) {
        await db
            .into(db.localProducts)
            .insert(
              LocalProductsCompanion.insert(
                id: l.productId!,
                sku: l.sku!,
                skuNorm: l.sku!.toLowerCase(),
                name: l.productName!,
                nameNorm: l.productName!.toLowerCase(),
                baseUnitCode: 'pc',
                qtyPrecision: 0,
                serverUpdatedAt: 1,
                baseUnitId: const Value<String?>('u-pc'),
              ),
            );
        await db
            .into(db.localProductVariants)
            .insert(
              LocalProductVariantsCompanion.insert(
                id: l.variantId,
                productId: l.productId!,
                name: 'Хром',
                serverUpdatedAt: 1,
              ),
            );
      }
    });

    tearDown(() async {
      await sync.dispose();
      await db.close();
    });

    testWidgets('перезапуск: копия drift сразу с «предварительно», затем итоги GET /cart; «+» → один PUT', (
      tester,
    ) async {
      // «Прошлый сеанс»: сервер ответил корзиной (rowVersion 17), затем офлайн изменили количество.
      final Cart cart = canonCart();
      await tester.runAsync(() async {
        repo.onFetch = () async => Success<Cart>(cart);
        await sync.refresh();
        offline = true;
        await sync.setQuantity(const CartLineKey('v-f4252'), Qty.units(4));
        await sync.sync();
      });
      // «Перезапуск»: сервер пока не отвечает.
      offline = false;
      repo.onFetch = () => Future<Result<Cart>>.delayed(const Duration(seconds: 3), () => Success<Cart>(cart));
      final List<CartItemPut> puts = <CartItemPut>[];
      repo.onPutItem = (String variantId, CartItemPut put, String? key) async {
        puts.add(put);
        return Success<Cart>(canonCart(rowVersion: put.rowVersion + 1));
      };
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        cartApp(
          overrides: <Override>[
            cartSyncProvider.overrideWithValue(sync),
            cartRepositoryProvider.overrideWithValue(repo),
            cartViewerRoleProvider.overrideWithValue(RoleCode.seller),
            cartOnlineStatusProvider.overrideWithValue(OnlineStatus.offline),
            clockProvider.overrideWithValue(FixedClock(cartNow)),
            appDatabaseProvider.overrideWithValue(db),
          ],
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      expect(find.text('Смеситель для кухни Frap F4252'), findsOneWidget, reason: 'копия drift после перезапуска');
      expect(find.text('Смеситель для раковины Gappo G1007'), findsOneWidget);
      expect(find.text(l10n.cart_summary_preliminary), findsOneWidget);
      expect(find.text(l10n.cart_banner_offline), findsOneWidget);
      expect(puts, isEmpty, reason: 'офлайн — без запросов');
      final List<OutboxActionRow> rows =
          await tester.runAsync(() => db.select(db.outboxActions).get()) ?? <OutboxActionRow>[];
      expect(rows.where((OutboxActionRow r) => r.type == OutboxTypes.cartSync && r.status == 'pending'), hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('перезапуск онлайн: очередь отправляется с базой rowVersion копии, серия «+» — один PUT', (
      tester,
    ) async {
      final Cart cart = canonCart();
      await tester.runAsync(() async {
        repo.onFetch = () async => Success<Cart>(cart);
        await sync.refresh();
        offline = true;
        await sync.setQuantity(const CartLineKey('v-f4252'), Qty.units(4));
        await sync.sync();
      });
      offline = false;
      Cart server = cart;
      final List<CartItemPut> puts = <CartItemPut>[];
      repo.onFetch = () async => Success<Cart>(server);
      repo.onPutItem = (String variantId, CartItemPut put, String? key) async {
        puts.add(put);
        server = canonCart(
          rowVersion: put.rowVersion + 1,
          items: <CartLine>[
            canonLine('f4252', 'Смеситель для кухни Frap F4252', 'F4252', put.quantity.value.milli ~/ 1000, 2350),
            ...cart.items.skip(1),
          ],
        );
        return Success<Cart>(server);
      };
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        cartApp(
          overrides: <Override>[
            cartSyncProvider.overrideWithValue(sync),
            cartRepositoryProvider.overrideWithValue(repo),
            cartViewerRoleProvider.overrideWithValue(RoleCode.seller),
            cartOnlineStatusProvider.overrideWithValue(OnlineStatus.online),
            clockProvider.overrideWithValue(FixedClock(cartNow)),
            appDatabaseProvider.overrideWithValue(db),
          ],
        ),
      );
      Future<void> settle() async {
        for (int i = 0; i < 5; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await settle();
      expect(puts.map((CartItemPut p) => (p.quantity.value.milli, p.rowVersion)), <(int, int)>[(4000, 17)]);
      expect(
        find.descendant(of: find.byKey(CartKeys.line(const CartLineKey('v-f4252'))), matching: find.text('4')),
        findsOneWidget,
      );

      final Finder plus = find.descendant(
        of: find.byKey(CartKeys.line(const CartLineKey('v-f4252'))),
        matching: find.byKey(const ValueKey<String>('quantity-stepper-increment')),
      );
      for (int i = 0; i < 3; i++) {
        await tester.tap(plus);
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(puts, hasLength(1), reason: 'до конца паузы 500 мс запросов нет');
      await tester.pump(const Duration(milliseconds: 600));
      await settle();
      expect(puts.map((CartItemPut p) => (p.quantity.value.milli, p.rowVersion, p.mode)), <(int, int, CartPutMode)>[
        (4000, 17, CartPutMode.set),
        (7000, 18, CartPutMode.set),
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
