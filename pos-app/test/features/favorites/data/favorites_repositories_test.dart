// Избранное товаров и недавние: `/favorites/products` (Idempotency-Key для PUT), `/catalog/products/recent`,
// локальная копия `favorites_products` / `recent_products`; `ProductSummary` разбирает порт catalog.
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/features/catalog/data/repositories/catalog_repositories_impl.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_repository.dart';
import 'package:optomstroy/features/favorites/data/datasources/favorites_remote_data_source.dart';
import 'package:optomstroy/features/favorites/data/repositories/favorites_repositories_impl.dart';

import '../../../core/database/test_database.dart';
import '../../../core/network/fake_adapter.dart';

void main() {
  configureSqliteForTests();
  late AppDatabase db;
  late FakeAdapter adapter;
  late FavoritesRemoteDataSource remote;
  final clock = FixedClock(DateTime.utc(2026, 10, 19, 10));

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    adapter = FakeAdapter((options) async {
      final path = options.uri.path.replaceFirst('/api/v1', '');
      return switch ((options.method, path)) {
        ('GET', '/favorites/products') => json(200, {
          'items': [
            {'id': 'p-1', 'name': 'Смеситель', 'isFavorite': true},
            {'id': 'p-2', 'name': 'Цемент', 'isFavorite': true},
          ],
          'nextCursor': null,
          'hasMore': false,
          'count': 2,
        }),
        ('PUT', '/favorites/products/p-3') || ('DELETE', '/favorites/products/p-1') => json(204, null),
        ('GET', '/catalog/products/recent') => json(200, {
          'items': [
            {'id': 'p-7', 'name': 'Кран', 'viewedAt': '2026-10-19T08:00:00Z'},
          ],
        }),
        ('DELETE', '/catalog/products/recent') => json(204, null),
        _ => json(404, problem('NOT_FOUND', 404)),
      };
    });
    final dio = Dio(BaseOptions(baseUrl: 'https://pos.test/api/v1'))..httpClientAdapter = adapter;
    remote = FavoritesRemoteDataSource(dio, const CatalogJsonDecoderImpl());
  });
  tearDown(() => db.close());

  test('список избранного заменяет локальную копию; PUT с Idempotency-Key; DELETE', () async {
    final repo = FavoritesRepositoryImpl(remote: remote, dao: () => db.favoritesDao, clock: clock);
    await repo.markPending('p-3', add: true);
    final page = (await repo.list()).valueOrNull!;
    expect(page.count, 2);
    expect([for (final p in page.items) p.id], ['p-1', 'p-2']);
    expect((await repo.cachedIds()).valueOrNull, {'p-1', 'p-2', 'p-3'});
    expect((await repo.add('p-3', idempotencyKey: 'fav-key-1')).isSuccess, isTrue);
    final put = adapter.requests.firstWhere((r) => r.method == 'PUT');
    expect(put.headers['Idempotency-Key'], 'fav-key-1');
    await repo.confirmPending('p-3');
    expect((await repo.remove('p-1')).isSuccess, isTrue);
    expect(await repo.watchCachedIds().first, {'p-1', 'p-2', 'p-3'});
  });

  test('недавние: список с viewedAt, локальная копия, очистка на сервере и локально', () async {
    final repo = RecentProductsRepositoryImpl(remote: remote, dao: () => db.favoritesDao, clock: clock);
    final recent = (await repo.list()).valueOrNull!;
    expect((recent.single.product.id, recent.single.viewedAt), ('p-7', DateTime.utc(2026, 10, 19, 8)));
    expect((await repo.cachedIds()).valueOrNull, ['p-7']);
    await repo.touchLocal('p-8');
    expect((await repo.cachedIds()).valueOrNull, ['p-8', 'p-7']);
    expect((await repo.clear()).isSuccess, isTrue);
    expect(adapter.countPath('/catalog/products/recent'), 2);
    expect((await repo.cachedIds()).valueOrNull, isEmpty);
  });

  test('без БД пользователя: сетевые вызовы работают, кэш — CatalogCacheUnavailable', () async {
    final repo = FavoritesRepositoryImpl(remote: remote, dao: () => null, clock: clock);
    expect((await repo.list()).isSuccess, isTrue);
    final failure = (await repo.cachedIds()).failureOrNull;
    expect((failure! as UnknownFailure).cause, isA<CatalogCacheUnavailable>());
    expect(await repo.watchCachedIds().first, isEmpty);
  });
}
