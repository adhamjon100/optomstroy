// DATA-261: нормализация поиска в Dart повторяет `norm_search` / `norm_sku` сервера
// (pos-api/migrations/0001_init.sql). FavoritesDao: избранное с `pending_op`, недавние ≤ 50.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/database/daos/favorites_dao.dart';
import 'package:optomstroy/core/database/search_norm.dart';

import 'test_database.dart';

void main() {
  group('SearchNorm (norm_search / norm_sku)', () {
    test('нижний регистр, ё → е, й → и, пробелы и пунктуация схлопываются', () {
      expect(SearchNorm.text('  Смеситель   для  КУХНИ, Grohe! '), 'смеситель для кухни grohe');
      expect(SearchNorm.text('Ёлка-ёжик'), 'елка ежик');
      expect(SearchNorm.text('Кран Майевского'), 'кран маиевского');
      expect(SearchNorm.text('Crème brûlée №5'), 'creme brulee 5');
      expect(SearchNorm.text('Труба ПП 20×2,8 / 4м'), 'труба пп 20 2 8 4м');
    });

    test('кыргызские буквы без разложения не меняются', () {
      expect(SearchNorm.text('Өңүү'), 'өңүү');
    });

    test('артикул: верхний регистр без пробелов, «-», «_», «.», «/»', () {
      expect(SearchNorm.sku('gr-33281 ch'), 'GR33281CH');
      expect(SearchNorm.sku('F4252_CR/1.0'), 'F4252CR10');
    });

    test('слова запроса и экранирование LIKE', () {
      expect(SearchNorm.tokens('смеситель фрап'), ['смеситель', 'фрап']);
      expect(SearchNorm.tokens(' ,. '), isEmpty);
      expect(SearchNorm.escapeLike(r'50%_a\b'), r'50\%\_a\\b');
    });
  });

  group('FavoritesDao', () {
    configureSqliteForTests();
    late AppDatabase db;
    late FavoritesDao dao;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      dao = db.favoritesDao;
    });
    tearDown(() => db.close());

    test('серверная копия заменяется, неподтверждённые действия сохраняются', () async {
      await dao.replaceFavoritesFromServer(['p-1', 'p-2'], nowMs: 1);
      await dao.markFavoritePending('p-3', add: true, nowMs: 2);
      await dao.markFavoritePending('p-1', add: false, nowMs: 3);
      expect(await dao.favoriteProductIds(), {'p-2', 'p-3'});
      await dao.replaceFavoritesFromServer(['p-1', 'p-4'], nowMs: 4);
      expect(await dao.favoriteProductIds(), {'p-3', 'p-4'}, reason: 'p-1 ждёт remove, p-3 ждёт add');
      await dao.confirmFavorite('p-1');
      await dao.confirmFavorite('p-3');
      expect(await dao.pendingFavorites(), isEmpty);
      expect(await dao.favoriteProductIds(), {'p-3', 'p-4'});
    });

    test('недавние: touch обновляет время и счётчик, список ≤ 50, очистка', () async {
      for (var i = 0; i < 55; i++) {
        await dao.touchRecent('p-$i', nowMs: 1000 + i);
      }
      await dao.touchRecent('p-54', nowMs: 5000);
      final recent = await dao.recentProducts();
      expect(recent, hasLength(FavoritesDao.recentLimit));
      expect((recent.first.productId, recent.first.viewCount), ('p-54', 2));
      expect(recent.map((r) => r.productId), isNot(contains('p-0')));
      await dao.replaceRecentFromServer([(productId: 'x', viewedAtMs: 1)]);
      expect((await dao.recentProducts()).map((r) => r.productId), ['x']);
      await dao.clearRecent();
      expect(await dao.recentProducts(), isEmpty);
    });
  });
}
