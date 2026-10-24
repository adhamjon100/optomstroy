// AC-RM-C-004 п. 3 / AC-DATA-260: пошаговые drift-миграции по снимкам схем
// (lib/core/database/schemas/drift_schema_v<N>.json, помощники — test/core/database/generated/,
// `drift_dev schema generate --data-classes --companions`).
// Обновление не теряет cart_draft, cart_items_draft, checkout_draft, outbox_actions,
// registration_draft, settings, app_meta (07 §11.5). v3 (этап E): поля контракта 08 §4.24
// в кэше каталога — новые столбцы пустые, строки кэша сохраняются. v4 (ревью E, EQ-CSYNC-02):
// `server_id` у prices/barcodes/product_images_meta; курсоры этих сущностей сбрасываются для перезагрузки.
// v5 (этап F, D-32): `cart_items_draft.unit_id`, `cart_draft.server_synced_at` — пустые; черновики корзины и
// оформления, очередь (в т. ч. `auth.logout`, `cart.sync`), настройки и кэш сохранены (AC-DATA-260).
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/app_meta_dao.dart';

import 'generated/schema.dart';
import 'generated/schema_v1.dart' as v1;
import 'generated/schema_v2.dart' as v2;
import 'generated/schema_v3.dart' as v3;
import 'generated/schema_v4.dart' as v4;
import 'generated/schema_v5.dart' as v5;
import 'test_database.dart';

void main() {
  configureSqliteForTests();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() => verifier = SchemaVerifier(GeneratedHelper()));

  test('снимки схем: последняя версия = AppDatabase.latestSchemaVersion = 5', () {
    expect(GeneratedHelper.versions, <int>[1, 2, 3, 4, 5]);
    expect(GeneratedHelper.versions.last, AppDatabase.latestSchemaVersion);
  });

  for (final from in <int>[1, 2, 3, 4]) {
    test('v$from → v5: итоговая схема совпадает со снимком v5', () async {
      final schema = await verifier.schemaAt(from);
      final db = AppDatabase(schema.newConnection());
      await verifier.migrateAndValidate(db, AppDatabase.latestSchemaVersion);
      await db.close();
    });
  }

  test('v1 → v5: черновики, очередь и app_meta сохранены; новые столбцы со значениями по умолчанию', () async {
    final schema = await verifier.schemaAt(1);

    final old = v1.DatabaseAtV1(schema.newConnection());
    await old
        .into(old.cartDraft)
        .insert(
          const v1.CartDraftCompanion(
            localId: Value('cart-1'),
            status: Value('active'),
            ownerUserId: Value('user-a'),
            dirty: Value(1),
            baseRowVersion: Value(7),
            updatedAt: Value(1000),
          ),
        );
    await old
        .into(old.cartItemsDraft)
        .insert(
          const v1.CartItemsDraftCompanion(
            localItemId: Value('item-1'),
            localCartId: Value('cart-1'),
            variantId: Value('variant-1'),
            quantityMilli: Value(2500),
            lineNo: Value(1),
            ownerUserId: Value('user-a'),
          ),
        );
    await old
        .into(old.checkoutDraft)
        .insert(
          const v1.CheckoutDraftCompanion(
            localCartId: Value('cart-1'),
            step: Value('review'),
            paymentMethod: Value('cash'),
            orderIdempotencyKey: Value('0f8fad5b-d9cb-469f-a165-70867728950e'),
            updatedAt: Value(1000),
          ),
        );
    await old
        .into(old.outboxActions)
        .insert(
          const v1.OutboxActionsCompanion(
            type: Value('cart.sync'),
            payloadJson: Value('{"op":"set_item"}'),
            idempotencyKey: Value('7c9e6679-7425-40de-944b-e07fc1f90ae7'),
            ownerUserId: Value('user-a'),
            createdAt: Value(1000),
          ),
        );
    await old
        .into(old.registrationDraft)
        .insert(const v1.RegistrationDraftCompanion(key: Value('step'), valueJson: Value('"consents"')));
    await old
        .into(old.settings)
        .insert(
          const v1.SettingsCompanion(
            key: Value('catalog_view'),
            valueJson: Value('"grid"'),
            scope: Value('user'),
            updatedAt: Value(1),
          ),
        );
    await old.into(old.appMeta).insert(const v1.AppMetaCompanion(key: Value('user_id'), value: Value('user-a')));
    await old
        .into(old.stockBalances)
        .insert(
          const v1.StockBalancesCompanion(
            variantId: Value('variant-1'),
            warehouseId: Value('wh-1'),
            availableMilli: Value(5000),
            snapshotAt: Value(1000),
          ),
        );
    await old.into(old.syncMeta).insert(const v1.SyncMetaCompanion(entity: Value('stock'), asOf: Value(1000)));
    await old.close();

    final db = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, AppDatabase.latestSchemaVersion);
    await db.close();

    final migrated = v5.DatabaseAtV5(schema.newConnection());
    final cart = await migrated.select(migrated.cartDraft).getSingle();
    expect((cart.localId, cart.ownerUserId, cart.dirty, cart.baseRowVersion), ('cart-1', 'user-a', 1, 7));
    final item = await migrated.select(migrated.cartItemsDraft).getSingle();
    expect((item.quantityMilli, item.syncState), (2500, 'pending'));
    final checkout = await migrated.select(migrated.checkoutDraft).getSingle();
    expect(checkout.orderIdempotencyKey, '0f8fad5b-d9cb-469f-a165-70867728950e');
    final outbox = await migrated.select(migrated.outboxActions).getSingle();
    expect((outbox.type, outbox.status, outbox.attempts), ('cart.sync', 'pending', 0));
    expect((await migrated.select(migrated.registrationDraft).getSingle()).valueJson, '"consents"');
    expect((await migrated.select(migrated.settings).getSingle()).valueJson, '"grid"');
    final stock = await migrated.select(migrated.stockBalances).getSingle();
    expect((stock.availableMilli, stock.stockLevel), (5000, 'unknown'));
    final sync = await migrated.select(migrated.syncMeta).getSingle();
    expect((sync.asOf, sync.staleAfterSec), (1000, null));
    final meta = {for (final r in await migrated.select(migrated.appMeta).get()) r.key: r.value};
    expect(meta['user_id'], 'user-a');
    expect(meta[AppMetaDao.schemaVersionKey], '${AppDatabase.latestSchemaVersion}');
    await migrated.close();
  });

  test('v2 → v5: кэш каталога сохранён, новые столбцы NULL; черновики и курсоры не тронуты', () async {
    final schema = await verifier.schemaAt(2);
    final old = v2.DatabaseAtV2(schema.newConnection());
    await old
        .into(old.products)
        .insert(
          const v2.ProductsCompanion(
            id: Value('p-1'),
            sku: Value('GR-33281'),
            skuNorm: Value('GR33281'),
            name: Value('Смеситель Grohe'),
            nameNorm: Value('смеситель grohe'),
            baseUnitCode: Value('pcs'),
            qtyPrecision: Value(0),
            serverUpdatedAt: Value(1000),
          ),
        );
    await old
        .into(old.productVariants)
        .insert(
          const v2.ProductVariantsCompanion(
            id: Value('v-1'),
            productId: Value('p-1'),
            name: Value('Хром'),
            serverUpdatedAt: Value(1000),
          ),
        );
    await old
        .into(old.units)
        .insert(const v2.UnitsCompanion(code: Value('pcs'), name: Value('штука'), qtyPrecision: Value(0)));
    await old
        .into(old.packagings)
        .insert(
          const v2.PackagingsCompanion(
            id: Value('pk-1'),
            productId: Value('p-1'),
            unitCode: Value('pcs'),
            name: Value('Коробка'),
            factorMilli: Value(6000),
          ),
        );
    await old
        .into(old.barcodes)
        .insert(const v2.BarcodesCompanion(value: Value('4600000000017'), productId: Value('p-1')));
    await old
        .into(old.syncMeta)
        .insert(const v2.SyncMetaCompanion(entity: Value('products'), serverCursor: Value('cur-7'), asOf: Value(5)));
    await old
        .into(old.cartDraft)
        .insert(
          const v2.CartDraftCompanion(
            localId: Value('cart-1'),
            status: Value('active'),
            ownerUserId: Value('user-a'),
            updatedAt: Value(1000),
          ),
        );
    await old.close();

    final db = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, AppDatabase.latestSchemaVersion);
    await db.close();

    final migrated = v5.DatabaseAtV5(schema.newConnection());
    final product = await migrated.select(migrated.products).getSingle();
    expect(
      (product.sku, product.defaultVariantId, product.baseUnitId, product.description),
      ('GR-33281', null, null, null),
    );
    final variant = await migrated.select(migrated.productVariants).getSingle();
    expect((variant.name, variant.multiplicityMilli, variant.unitId), ('Хром', null, null));
    final unit = await migrated.select(migrated.units).getSingle();
    expect((unit.code, unit.id, unit.shortName), ('pcs', null, null));
    final packaging = await migrated.select(migrated.packagings).getSingle();
    expect((packaging.factorMilli, packaging.variantId, packaging.unitId), (6000, null, null));
    expect((await migrated.select(migrated.barcodes).getSingle()).barcodeType, isNull);
    final cursor = await migrated.select(migrated.syncMeta).getSingle();
    expect((cursor.entity, cursor.serverCursor, cursor.asOf), ('products', 'cur-7', 5));
    expect((await migrated.select(migrated.cartDraft).getSingle()).ownerUserId, 'user-a');
    final indexes = await migrated
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'packagings_variant_idx'")
        .get();
    expect(indexes, hasLength(1));
    await migrated.close();
  });

  test('v3 → v5: server_id пуст, курсоры prices/barcodes/images сброшены, прочие курсоры и строки кэша целы', () async {
    final schema = await verifier.schemaAt(3);
    final old = v3.DatabaseAtV3(schema.newConnection());
    await old
        .into(old.prices)
        .insert(
          const v3.PricesCompanion(
            variantId: Value('v-1'),
            priceListId: Value('pl-1'),
            priceTyiyn: Value(165000),
            serverSyncedAt: Value(1000),
          ),
        );
    await old
        .into(old.barcodes)
        .insert(const v3.BarcodesCompanion(value: Value('4600000000017'), productId: Value('p-1')));
    await old
        .into(old.productImagesMeta)
        .insert(const v3.ProductImagesMetaCompanion(productId: Value('p-1'), sha: Value('ab')));
    for (final e in <String>['prices', 'barcodes', 'images', 'products']) {
      await old
          .into(old.syncMeta)
          .insert(
            v3.SyncMetaCompanion(
              entity: Value(e),
              serverCursor: Value('cur-$e'),
              asOf: const Value(5),
              lastSuccessAt: const Value(6),
            ),
          );
    }
    await old.close();

    final db = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, AppDatabase.latestSchemaVersion);
    await db.close();

    final migrated = v5.DatabaseAtV5(schema.newConnection());
    final price = await migrated.select(migrated.prices).getSingle();
    expect((price.priceTyiyn, price.serverId), (165000, null));
    expect((await migrated.select(migrated.barcodes).getSingle()).serverId, isNull);
    expect((await migrated.select(migrated.productImagesMeta).getSingle()).serverId, isNull);
    final cursors = {
      for (final r in await migrated.select(migrated.syncMeta).get())
        r.entity: (r.serverCursor, r.asOf, r.lastSuccessAt),
    };
    expect(cursors, {
      'prices': (null, null, 6),
      'barcodes': (null, null, 6),
      'images': (null, null, 6),
      'products': ('cur-products', 5, 6),
    });
    await migrated.close();
  });

  test(
    'v4 → v5: cart_draft, cart_items_draft, checkout_draft, outbox_actions, settings сохранены; новые столбцы пусты',
    () async {
      final schema = await verifier.schemaAt(4);
      final old = v4.DatabaseAtV4(schema.newConnection());
      await old
          .into(old.cartDraft)
          .insert(
            const v4.CartDraftCompanion(
              localId: Value('cart-1'),
              serverId: Value('srv-cart-1'),
              status: Value('active'),
              ownerUserId: Value('user-a'),
              dirty: Value(1),
              baseRowVersion: Value(7),
              discountPercentHundredths: Value(500),
              updatedAt: Value(1000),
            ),
          );
      await old
          .into(old.cartItemsDraft)
          .insert(
            const v4.CartItemsDraftCompanion(
              localItemId: Value('item-1'),
              localCartId: Value('cart-1'),
              variantId: Value('variant-1'),
              packagingId: Value('pack-6'),
              quantityMilli: Value(2000),
              priceSnapshotTyiyn: Value(235000),
              lineNo: Value(1),
              ownerUserId: Value('user-a'),
              syncState: Value('dead'),
            ),
          );
      await old
          .into(old.checkoutDraft)
          .insert(
            const v4.CheckoutDraftCompanion(
              localCartId: Value('cart-1'),
              step: Value('payment'),
              customerId: Value('cust-1'),
              deliveryMethod: Value('delivery'),
              receiverKind: Value('other_person'),
              paymentMethod: Value('qr_bakai'),
              orderIdempotencyKey: Value('0f8fad5b-d9cb-469f-a165-70867728950e'),
              submittedAt: Value(1500),
              updatedAt: Value(1600),
            ),
          );
      for (final (String type, String key) in <(String, String)>[
        ('cart.sync', 'k-cart'),
        ('auth.logout', 'k-logout'),
      ]) {
        await old
            .into(old.outboxActions)
            .insert(
              v4.OutboxActionsCompanion(
                type: Value(type),
                payloadJson: const Value('{}'),
                idempotencyKey: Value(key),
                ownerUserId: const Value('user-a'),
                status: const Value('pending'),
                createdAt: const Value(1000),
              ),
            );
      }
      await old
          .into(old.settings)
          .insert(
            const v4.SettingsCompanion(
              key: Value('catalog.view.expanded'),
              valueJson: Value('"grid"'),
              scope: Value('user'),
              updatedAt: Value(1000),
            ),
          );
      await old.close();

      final db = AppDatabase(schema.newConnection());
      await verifier.migrateAndValidate(db, 5);
      expect(await db.appMetaDao.read(AppMetaDao.schemaVersionKey), '5');
      await db.close();

      final migrated = v5.DatabaseAtV5(schema.newConnection());
      final cart = await migrated.select(migrated.cartDraft).getSingle();
      expect(
        (cart.serverId, cart.dirty, cart.baseRowVersion, cart.discountPercentHundredths, cart.serverSyncedAt),
        ('srv-cart-1', 1, 7, 500, null),
      );
      final item = await migrated.select(migrated.cartItemsDraft).getSingle();
      expect(
        (item.packagingId, item.quantityMilli, item.priceSnapshotTyiyn, item.syncState, item.unitId),
        ('pack-6', 2000, 235000, 'dead', null),
      );
      final checkout = await migrated.select(migrated.checkoutDraft).getSingle();
      expect(
        (checkout.step, checkout.paymentMethod, checkout.orderIdempotencyKey, checkout.submittedAt),
        ('payment', 'qr_bakai', '0f8fad5b-d9cb-469f-a165-70867728950e', 1500),
      );
      expect(
        {for (final r in await migrated.select(migrated.outboxActions).get()) r.type},
        {'cart.sync', 'auth.logout'},
      );
      expect((await migrated.select(migrated.settings).getSingle()).valueJson, '"grid"');
      await migrated.close();
    },
  );
}
