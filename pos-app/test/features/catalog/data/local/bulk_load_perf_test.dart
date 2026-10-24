// Нагрузочный тест загрузки кэша (RM-E-009 критерий 3 — подготовка; NFR-PERF-006, DATA-257, T-PERF):
// 50 000 синтетических SKU в drift в памяти. Измеряется: (1) запись DAO — 250 страниц по 200 товаров через
// `applySyncPage` (строки уже разобраны); (2) полный конвейер первичной загрузки — фейковый
// `GET /catalog/sync/{entity}` (JSON) → разбор DTO → маппинг → drift — для products, variants, barcodes, prices,
// stock по 50 000 строк (250 000 строк). Время печатается в лог теста.
// Это НЕ замер на целевом устройстве по Wi-Fi (порог ≤ 3 мин — на устройстве, этап RM-E-012); SQLite —
// системная `winsqlite3.dll` Windows, в одном изоляте с тестом.
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/catalog_dao.dart';
import 'package:optomstroy/core/database/search_norm.dart';
import 'package:optomstroy/core/sync/sync_models.dart';

import '../../../../core/sync/sync_test_support.dart';

const int skuCount = 50000;

void main() {
  test(
    'DAO: 50 000 товаров страницами по 200 (applySyncPage, одна транзакция на страницу)',
    () async {
      final stack = SyncStack(FakeCatalogServer(const {}));
      addTearDown(stack.db.close);
      final dao = stack.db.catalogDao;
      final sw = Stopwatch()..start();
      const pageSize = 200;
      for (var start = 0; start < skuCount; start += pageSize) {
        final rows = <LocalProductsCompanion>[
          for (var i = start; i < start + pageSize && i < skuCount; i++)
            LocalProductsCompanion.insert(
              id: 'p-$i',
              sku: 'SKU-$i',
              skuNorm: SearchNorm.sku('SKU-$i'),
              name: 'Смеситель Frap F$i хром',
              nameNorm: SearchNorm.text('Смеситель Frap F$i хром'),
              baseUnitCode: 'шт',
              qtyPrecision: 0,
              serverUpdatedAt: 1,
              categoryId: const Value(catId),
              brand: const Value('Frap'),
            ),
        ];
        final last = start + pageSize >= skuCount;
        await dao.applySyncPage(
          entity: 'products',
          rows: CatalogRows(products: rows),
          deletedIds: const [],
          cursor: 'products#${start ~/ pageSize + 1}',
          asOfMs: 1,
          nowMs: 2,
          completed: last,
        );
      }
      sw.stop();
      expect(await dao.productCount(), skuCount);
      // ignore: avoid_print
      print('PERF dao_insert_50000_products_ms=${sw.elapsedMilliseconds}');
      expect(sw.elapsed, lessThan(const Duration(minutes: 3)));
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'конвейер первичной загрузки: 50 000 SKU × (products, variants, barcodes, prices, stock) из фейкового API',
    () async {
      final server = FakeCatalogServer(syntheticCatalog(skuCount));
      final stack = SyncStack(server);
      addTearDown(stack.db.close);
      final engine = stack.engine();
      final perEntity = <String, int>{};
      final sw = Stopwatch()..start();
      var lastEntity = '';
      var mark = 0;
      final sub = engine.states.listen((s) {
        final e = s.entity;
        if (e != null && e != lastEntity) {
          if (lastEntity.isNotEmpty) perEntity[lastEntity] = sw.elapsedMilliseconds - mark;
          lastEntity = e;
          mark = sw.elapsedMilliseconds;
        }
      });
      final result = await engine.ensureLoaded();
      sw.stop();
      await sub.cancel();
      if (lastEntity.isNotEmpty) perEntity[lastEntity] = sw.elapsedMilliseconds - mark;
      expect(result.phase, CatalogLoadPhase.ready, reason: '${result.failure}');
      expect(await stack.db.catalogDao.productCount(), skuCount);
      final page = await stack.db.catalogDao.listProducts(
        filter: const CatalogLocalFilter(),
        sort: CatalogLocalSort.nameAsc,
        limit: 40,
        offset: 0,
      );
      expect(page.total, skuCount);
      // ignore: avoid_print
      print(
        'PERF pipeline_50000_sku_total_ms=${sw.elapsedMilliseconds} rows=${result.rows} pages=${result.pages} '
        'per_entity_ms=$perEntity',
      );
      expect(sw.elapsed, lessThan(const Duration(minutes: 3)));
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
