// FIX-EF-01 / EQ-CSYNC-02 (OpenAPI 1.1.0): поля выгрузки `GET /catalog/sync/{entity}`, внесённые в контракт,
// читаются DTO по схеме и попадают в строки кэша drift (а не вычисляются заново, когда сервер их прислал).
// T-CAT-041 (ADR-114 п. 3): картинка категории переживает запись и чтение кэша (`imageSha` → `/images/{sha}/card`).
// Ревью RP-03: основное фото товара в кэше выбирает DAO по `product_images_meta` (`imageIds` — uuid, а не sha256).
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/features/catalog/data/dto/catalog_dtos.dart';
import 'package:optomstroy/features/catalog/data/mappers/catalog_mappers.dart';
import 'package:optomstroy/features/catalog/domain/entities/sync.dart';

void main() {
  final DateTime serverTime = DateTime.utc(2026, 10, 22, 9);
  const String root = '0192d1c3-0000-7000-8000-000000000001';
  const String child = '0192d1c3-0000-7000-8000-000000000002';

  test('categories: path, depth, isVisible, updatedAt сервера', () {
    final page = syncItemsToRows(CatalogSyncEntity.categories, <Map<String, dynamic>>[
      <String, dynamic>{
        'id': child,
        'parentId': root,
        'name': 'Смесители',
        'path': '/$root/$child',
        'depth': 1,
        'isVisible': false,
        'updatedAt': '2026-10-22T08:00:00Z',
      },
    ], serverTime: serverTime);
    final row = page.rows.categories.single;
    expect(row.path.value, '/$root/$child');
    expect(row.depth.value, 1);
    expect(row.isVisible.value, isFalse);
    expect(row.serverUpdatedAt.value, DateTime.utc(2026, 10, 22, 8).millisecondsSinceEpoch);
  });

  test('categories без новых полей: временный корень и serverTime страницы', () {
    final page = syncItemsToRows(CatalogSyncEntity.categories, <Map<String, dynamic>>[
      <String, dynamic>{'id': child, 'name': 'Смесители'},
    ], serverTime: serverTime);
    final row = page.rows.categories.single;
    expect((row.path.value, row.depth.value, row.isVisible.value), ('/$child', 0, true));
    expect(row.serverUpdatedAt.value, serverTime.millisecondsSinceEpoch);
  });

  test('T-CAT-041: imageUrl категории → imageSha кэша → тот же imageUrl; null и неверный адрес — null', () {
    final String sha = 'ab' * 32;
    final page = syncItemsToRows(CatalogSyncEntity.categories, <Map<String, dynamic>>[
      <String, dynamic>{'id': root, 'name': 'Сантехника', 'imageUrl': '/images/$sha/card'},
      <String, dynamic>{'id': child, 'name': 'Отопление'},
      <String, dynamic>{'id': 'c-3', 'name': 'Электрика', 'imageUrl': 'https://cdn.example/x.png'},
      <String, dynamic>{'id': 'c-4', 'name': 'Вентиляция', 'imageUrl': 'https://pos.example/images/$sha/card'},
    ], serverTime: serverTime);
    expect(page.rows.categories.map((r) => r.imageSha.value), <String?>[sha, null, null, sha]);

    CategoryRow row(String id, String? imageSha) => CategoryRow(
      id: id,
      name: id,
      nameNorm: id,
      path: '/$id',
      depth: 0,
      sortOrder: 0,
      imageSha: imageSha,
      productCount: 1,
      isVisible: true,
      deletionMark: false,
      serverUpdatedAt: 0,
    );
    final tree = categoryTreeFromRows(<CategoryRow>[row('a', sha), row('b', null)]);
    expect(tree.find('a')?.imageUrl, '/images/$sha/card');
    expect(tree.find('b')?.imageUrl, isNull);
    expect(categoryImageShaFromUrl(null), isNull);
    expect(categoryImageShaFromUrl('/images/${'A' * 64}/card'), isNull, reason: 'sha256 — строчные hex');
    expect(categoryImageShaFromUrl('/images/$sha/thumb'), isNull);
  });

  test('RP-03: products — primaryImageSha не берётся из imageIds (uuid строк images)', () {
    final page = syncItemsToRows(CatalogSyncEntity.products, <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'p-1',
        'name': 'Унитаз',
        'imageIds': <String>['00dc6acf-ac01-7293-8000-000000000001'],
      },
    ], serverTime: serverTime);
    expect(page.rows.products.single.primaryImageSha.value, isNull);
  });

  test('products: multiplicity и isSellable', () {
    final page = syncItemsToRows(CatalogSyncEntity.products, <Map<String, dynamic>>[
      <String, dynamic>{'id': 'p-1', 'name': 'Кран', 'multiplicity': '6.000', 'isSellable': false},
      <String, dynamic>{'id': 'p-2', 'name': 'Труба', 'multiplicity': null},
    ], serverTime: serverTime);
    final rows = page.rows.products;
    expect((rows[0].multiplicityMilli.value, rows[0].isSellable.value), (6000, false));
    expect((rows[1].multiplicityMilli.value, rows[1].isSellable.value), (null, true));
  });

  test('warehouses: shortName; barcodes, packagings: productId; images: id и sortOrder', () {
    final warehouses = syncItemsToRows(CatalogSyncEntity.warehouses, <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'w-1',
        'name': 'Основной склад',
        'shortName': 'Осн',
        'isDefaultForPos': true,
        'sortOrder': 2,
      },
    ], serverTime: serverTime);
    expect(warehouses.rows.warehouses.single.shortName.value, 'Осн');
    expect(warehouses.rows.warehouses.single.isDefault.value, isTrue);

    final barcodes = syncItemsToRows(CatalogSyncEntity.barcodes, <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'b-1',
        'barcode': '4600000000017',
        'variantId': 'v-1',
        'type': 'EAN13',
        'productId': 'p-1',
      },
      <String, dynamic>{'barcode': '4600000000024', 'variantId': 'v-2', 'type': 'EAN13'},
    ], serverTime: serverTime);
    expect(barcodes.rows.barcodes.map((r) => (r.productId.value, r.serverId.value)), <(String, String?)>[
      ('p-1', 'b-1'),
      ('', null),
    ]);

    final packagings = syncItemsToRows(CatalogSyncEntity.packagings, <Map<String, dynamic>>[
      <String, dynamic>{
        'id': 'pk-1',
        'unitId': 'u-1',
        'factor': '6.000',
        'variantId': 'v-1',
        'productId': 'p-1',
        'sortOrder': 1,
      },
    ], serverTime: serverTime);
    expect(packagings.rows.packagings.single.productId.value, 'p-1');

    final images = syncItemsToRows(CatalogSyncEntity.images, <Map<String, dynamic>>[
      <String, dynamic>{'id': 'i-1', 'sha256': 'a' * 64, 'productId': 'p-1', 'sortOrder': 5},
      <String, dynamic>{'id': 'i-2', 'sha256': 'b' * 64, 'productId': 'p-1'},
    ], serverTime: serverTime);
    expect(images.rows.images.map((r) => (r.serverId.value, r.sortOrder.value)), <(String?, int)>[
      ('i-1', 5),
      ('i-2', 1),
    ]);
  });

  test('attributes: новые поля разбираются, локальных строк нет (07 §11.4)', () {
    final dto = SyncAttributeDto.fromJson(<String, dynamic>{
      'id': 'a-1',
      'code': 'diameter',
      'name': 'Диаметр',
      'valueType': 'number',
      'unitLabel': 'мм',
      'isFilterable': true,
      'isVariantAxis': false,
      'sortOrder': 3,
    });
    expect(
      (dto.valueType, dto.unitLabel, dto.isFilterable, dto.isVariantAxis, dto.sortOrder),
      ('number', 'мм', true, false, 3),
    );
    expect(SyncAttributeDto.valueTypes, contains(dto.valueType));
    final page = syncItemsToRows(CatalogSyncEntity.attributes, <Map<String, dynamic>>[
      <String, dynamic>{'id': 'a-1', 'code': 'diameter', 'name': 'Диаметр'},
    ], serverTime: serverTime);
    expect(page.keys, isEmpty);
  });
}
