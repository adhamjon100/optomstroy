// Unit-тесты провайдеров и правил presentation каталога (RM-E-007): список (кэш → сеть, офлайн,
// подгрузка без дублей и параллельных запросов, отбрасывание устаревших ответов), дерево категорий,
// ввод поиска (debounce 300 мс, минимум 2 символа, цифры — с 1, Enter), кодек фильтров `f`, история
// запросов (без телефонов), правила карточки (INV-013/014/023/052, CUST-022), форматы.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' show RoleCode;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/error/screen_state.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/product_card.dart';
import 'package:optomstroy/design_system/components/stock_badge.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/category.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/presentation/providers/catalog_list_controller.dart';
import 'package:optomstroy/features/catalog/presentation/providers/category_tree_provider.dart';
import 'package:optomstroy/features/catalog/presentation/state/catalog_filter_codec.dart';
import 'package:optomstroy/features/catalog/presentation/state/catalog_prefs.dart';
import 'package:optomstroy/features/catalog/presentation/state/search_input_policy.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_card_mapper.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_formats.dart';

import 'support/catalog_fakes.dart';

const CatalogListKey _key = CatalogListKey.catalog(filter: CatalogFilter(), sort: CatalogSort.nameAsc);

ProviderContainer _container(FakeCatalogRepository repo, {FakeSearchRepository? search}) {
  final ProviderContainer c = ProviderContainer(
    overrides: [
      catalogRepositoryProvider.overrideWithValue(repo),
      searchRepositoryProvider.overrideWithValue(search ?? FakeSearchRepository()),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

/// Держит autoDispose-провайдер живым и ждёт завершения микрозадач загрузки.
Future<CatalogListState> _load(ProviderContainer c, CatalogListKey key) async {
  c.listen(catalogListProvider(key), (_, _) {});
  for (int i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  return c.read(catalogListProvider(key));
}

Future<AppLocalizations> _l10n() => AppLocalizations.delegate.load(const Locale('ru'));

void main() {
  group('CatalogListController', () {
    test('кэш показывается сразу, затем заменяется ответом сервера', () async {
      final FakeCatalogRepository repo = FakeCatalogRepository(items: products(3))
        ..cached = Success<CatalogPage<ProductSummary>>(page(products(1), source: DataSource.cache));
      repo.gate.hold();
      final ProviderContainer c = _container(repo);
      CatalogListState s = await _load(c, _key);
      expect(s.phase, CatalogListPhase.ready);
      expect(s.items, hasLength(1));
      expect(s.refreshing, isTrue);
      repo.gate.release();
      s = await _load(c, _key);
      expect(s.items, hasLength(3));
      expect(s.refreshing, isFalse);
      expect(s.source, DataSource.network);
    });

    test('сеть недоступна: кэш остаётся, флаг offline; без кэша — offlineNoCache', () async {
      final FakeCatalogRepository withCache = FakeCatalogRepository()
        ..cached = Success<CatalogPage<ProductSummary>>(page(products(2), source: DataSource.cache))
        ..networkPages.add(const FailureResult<CatalogPage<ProductSummary>>(kOffline));
      final CatalogListState a = await _load(_container(withCache), _key);
      expect(a.phase, CatalogListPhase.ready);
      expect(a.offline, isTrue);
      expect(a.source, DataSource.cache);

      final FakeCatalogRepository noCache = FakeCatalogRepository()
        ..networkPages.add(const FailureResult<CatalogPage<ProductSummary>>(kOffline));
      final CatalogListState b = await _load(_container(noCache), _key);
      expect(b.phase, CatalogListPhase.offlineNoCache);
    });

    test('ошибка сервера без кэша — error; без привязки порта (исключение) — тоже error, не падение', () async {
      final FakeCatalogRepository repo = FakeCatalogRepository()
        ..networkPages.add(
          const FailureResult<CatalogPage<ProductSummary>>(ServerFailure(code: 'INTERNAL', status: 500)),
        );
      expect((await _load(_container(repo), _key)).phase, CatalogListPhase.error);

      final ProviderContainer unbound = ProviderContainer();
      addTearDown(unbound.dispose);
      final CatalogListState s = await _load(unbound, _key);
      expect(s.phase, CatalogListPhase.error);
      expect(s.failure, isA<UnknownFailure>());
    });

    test('подгрузка: курсор, без дублей, не более одного запроса одновременно', () async {
      final FakeCatalogRepository repo = FakeCatalogRepository()
        ..networkPages.add(Success<CatalogPage<ProductSummary>>(page(products(3), next: 'c2')))
        ..byCursor['c2'] = Success<CatalogPage<ProductSummary>>(page(<ProductSummary>[product(2), product(3)]));
      final ProviderContainer c = _container(repo);
      await _load(c, _key);
      final CatalogListController ctl = c.read(catalogListProvider(_key).notifier);
      repo.gate.hold();
      final Future<void> first = ctl.loadMore();
      final Future<void> second = ctl.loadMore();
      repo.gate.release();
      await Future.wait(<Future<void>>[first, second]);
      final CatalogListState s = c.read(catalogListProvider(_key));
      expect(repo.productCalls.where((CatalogQuery q) => q.cursor == 'c2'), hasLength(1));
      expect(s.items.map((ProductSummary p) => p.id), <String>['p0', 'p1', 'p2', 'p3']);
      expect(s.hasMore, isFalse);
    });

    test('ответ устаревшего запроса отбрасывается (повтор до ответа)', () async {
      final FakeCatalogRepository repo = FakeCatalogRepository();
      repo.networkPages
        ..add(Success<CatalogPage<ProductSummary>>(page(products(1))))
        ..add(Success<CatalogPage<ProductSummary>>(page(products(5))));
      repo.gate.hold();
      final ProviderContainer c = _container(repo);
      c.listen(catalogListProvider(_key), (_, _) {});
      await Future<void>.delayed(Duration.zero);
      final Future<void> again = c.read(catalogListProvider(_key).notifier).reload();
      repo.gate.release();
      await again;
      await Future<void>.delayed(Duration.zero);
      expect(c.read(catalogListProvider(_key)).items, hasLength(5));
    });

    test('ключи списков равны по смыслу фильтра', () {
      const CatalogListKey a = CatalogListKey.catalog(filter: CatalogFilter(inStock: true), sort: CatalogSort.skuAsc);
      const CatalogListKey b = CatalogListKey.catalog(filter: CatalogFilter(inStock: true), sort: CatalogSort.skuAsc);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        a == const CatalogListKey.search(q: 'x', filter: CatalogFilter(inStock: true), sort: CatalogSort.skuAsc),
        isFalse,
      );
    });
  });

  group('CategoryTreeController', () {
    test('кэш → сеть; ошибка сети сохраняет кэш', () async {
      final FakeCatalogRepository repo = FakeCatalogRepository()
        ..cachedTree = CategoryTree.fromFlat(const <Category>[Category(id: 'old', name: 'Старое')])
        ..categoriesResult = const FailureResult<CategoryTree>(kOffline);
      final ProviderContainer c = _container(repo);
      c.listen(categoryTreeProvider, (_, _) {});
      for (int i = 0; i < 6; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      final CategoryTreeState s = c.read(categoryTreeProvider);
      expect(s.tree!.find('old'), isNotNull);
      expect(s.source, DataSource.cache);
      expect(s.failure, isA<NetworkFailure>());
      expect(s.authoritative, isFalse);

      repo.categoriesResult = null;
      await c.read(categoryTreeProvider.notifier).refresh();
      expect(c.read(categoryTreeProvider).tree!.find('c-mix'), isNotNull);
      expect(c.read(categoryTreeProvider).authoritative, isTrue);
    });
  });

  group('SearchInputController', () {
    testWidgets('debounce 300 мс; < 2 букв — нет запроса; цифры — с 1; Enter — сразу; повтор той же строки — нет', (
      tester,
    ) async {
      final List<String> sent = <String>[];
      final SearchInputController c = SearchInputController(onQuery: sent.add);
      addTearDown(c.dispose);
      c.changed('с');
      await tester.pump(const Duration(seconds: 1));
      expect(sent, isEmpty);
      for (final String s in <String>['см', 'сме', 'смес', 'смеси', 'смесит']) {
        c.changed(s);
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(sent, isEmpty);
      await tester.pump(const Duration(milliseconds: 200));
      expect(sent, <String>['смесит']);
      c.changed('4');
      await tester.pump(const Duration(milliseconds: 300));
      expect(sent.last, '4');
      c.changed('F42');
      c.submit('F42');
      expect(sent.last, 'F42');
      await tester.pump(const Duration(seconds: 1));
      expect(sent.where((String s) => s == 'F42'), hasLength(1));
      c.changed('  F42  ');
      await tester.pump(const Duration(milliseconds: 300));
      expect(sent.where((String s) => s == 'F42'), hasLength(1), reason: 'та же строка после нормализации');
    });

    test('политика: нормализация, обрезка до 100, «введите ещё N»', () {
      expect(SearchInputPolicy.normalize('  F4252  '), 'F4252');
      expect(SearchInputPolicy.normalize('x' * 150).length, 100);
      expect(SearchInputPolicy.missingChars('с'), 1);
      expect(SearchInputPolicy.missingChars(''), 2);
      expect(SearchInputPolicy.missingChars('7'), 0);
      expect(SearchInputPolicy.canSearch('  '), isFalse);
    });
  });

  group('CatalogFilterCodec', () {
    test('кодирование/разбор f без потерь; мусор и лишние attr отбрасываются', () {
      final CatalogFilter f = CatalogFilter(
        categoryId: 'c-mix',
        includeSubcategories: false,
        warehouseId: 'w-2',
        inStock: true,
        priceMin: Money.som(1500),
        priceMax: const Money(420050),
        brands: const <String>['Frap', 'Grohe, Германия'],
        attrs: const <String, String>{'color': 'хром', 'size': '1/2"'},
        favorite: true,
        hasImage: true,
      );
      final String encoded = CatalogFilterCodec.encode(f)!;
      final CatalogFilter back = CatalogFilterCodec.decode(encoded);
      expect(CatalogFilterCodec.same(f, back), isTrue);
      expect(back.brands, <String>['Frap', 'Grohe, Германия']);
      expect(back.priceMax, const Money(420050));
      expect(back.activeCount, 7);
      expect(CatalogFilterCodec.encode(const CatalogFilter()), isNull);
      expect(CatalogFilterCodec.decode('pmin=abc&stock=yes').priceMin, isNull);
      expect(CatalogFilterCodec.decode('pmin=abc&stock=yes').inStock, isNull);
      final String many = List<String>.generate(12, (int i) => 'attr.k$i=v').join('&');
      expect(CatalogFilterCodec.decode(many).attrs, hasLength(CatalogFilter.maxAttrs));
      expect(CatalogFilterCodec.cleared(f).activeCount, 0);
      expect(CatalogFilterCodec.cleared(f).categoryId, 'c-mix');
    });
  });

  group('SearchHistory', () {
    test('телефоны не сохраняются; до 5 последних, без повторов', () {
      final ProviderContainer c = ProviderContainer();
      addTearDown(c.dispose);
      final SearchHistory h = c.read(searchHistoryProvider.notifier);
      h.add('+996 555 123 456');
      h.add('0555123456');
      h.add('F4252-CR');
      expect(c.read(searchHistoryProvider), <String>['F4252-CR']);
      for (final String q in <String>['a1', 'b2', 'c3', 'd4', 'e5', 'F4252-CR']) {
        h.add(q);
      }
      expect(c.read(searchHistoryProvider), <String>['F4252-CR', 'e5', 'd4', 'c3', 'b2']);
      expect(SearchHistory.isPhoneLike('(0555) 12-34-56'), isTrue);
      expect(SearchHistory.isPhoneLike('4600000000017'), isTrue, reason: 'ровно правило 02: ≥ 9 цифр');
      expect(SearchHistory.isPhoneLike('F4252-CR'), isFalse);
    });
  });

  group('CatalogCardMapper', () {
    test('контрол количества: owner скрыт; варианты; нет цены; неизвестный остаток; нет в наличии', () async {
      final AppLocalizations l10n = await _l10n();
      CatalogCardContext ctx(RoleCode role) => CatalogCardContext(l10n: l10n, now: kNow, role: role);
      expect(CatalogCardMapper.action(ctx(RoleCode.owner), product(1)).$1, ProductCardActionKind.hidden);
      expect(
        CatalogCardMapper.action(ctx(RoleCode.seller), product(1, hasVariants: true)).$1,
        ProductCardActionKind.chooseVariant,
      );
      expect(CatalogCardMapper.action(ctx(RoleCode.seller), product(1, noPrice: true)).$2, 'Цена не указана');
      expect(CatalogCardMapper.action(ctx(RoleCode.seller), product(1, noStock: true)).$2, 'Остаток неизвестен');
      // «Компакт» (QA прототипа 2026-10-29): короткая подпись тем же кеглем, полная — в тултипе.
      final ProductCardData unknown = CatalogCardMapper.map(ctx(RoleCode.seller), product(1, noStock: true));
      expect(unknown.actionShortLabel, 'Нет данных');
      expect(unknown.actionLabel, 'Остаток неизвестен');
      expect(CatalogCardMapper.map(ctx(RoleCode.seller), product(1, noPrice: true)).actionShortLabel, isNull);
      expect(CatalogCardMapper.action(ctx(RoleCode.seller), product(1, level: StockLevel.out)).$2, 'Нет в наличии');
      expect(CatalogCardMapper.action(ctx(RoleCode.seller), product(1)).$1, ProductCardActionKind.add);
    });

    test('остаток: число — значение сервера; customer — без числа; устаревание > 30 мин и офлайн', () async {
      final AppLocalizations l10n = await _l10n();
      final CatalogCardContext staff = CatalogCardContext(l10n: l10n, now: kNow, role: RoleCode.seller);
      expect(CatalogCardMapper.stock(staff, product(1, available: 7)), (StockBadgeLevel.inStock, 'В наличии · 7 шт'));
      final CatalogCardContext customer = CatalogCardContext(l10n: l10n, now: kNow, role: RoleCode.customer);
      expect(CatalogCardMapper.stock(customer, product(1)).$2, 'В наличии');
      final ProductCardData old = CatalogCardMapper.map(
        staff,
        product(1, asOf: kNow.subtract(const Duration(minutes: 45))),
      );
      expect(old.stockAsOf, 'данные от 08:56');
      expect(CatalogCardMapper.map(staff, product(1)).stockAsOf, isNull);
      final CatalogCardContext offline = CatalogCardContext(
        l10n: l10n,
        now: kNow,
        role: RoleCode.seller,
        offline: true,
      );
      expect(CatalogCardMapper.map(offline, product(1)).stockAsOf, 'данные от 09:36');
    });

    test('цена «от» для вариантов разной цены; единица «/ шт»; артикул не указан', () async {
      final AppLocalizations l10n = await _l10n();
      final CatalogCardContext ctx = CatalogCardContext(l10n: l10n, now: kNow, role: RoleCode.seller);
      final ProductCardData v = CatalogCardMapper.map(
        ctx,
        product(1, hasVariants: true, variantCount: 3, priceSom: 2350),
      );
      expect(v.price, Money.som(2350));
      expect(v.pricePrefix!('2 350 сом'), 'от 2 350 сом');
      expect(v.priceUnit, '/ шт');
      expect(v.variantsLabel, '3 варианта');
      expect(CatalogCardMapper.map(ctx, product(2, noSku: true)).skuLabel, 'Артикул не указан');
    });
  });

  group('CatalogFormats', () {
    test('время Бишкека, количества без double, разбор «текст · действие»', () {
      expect(CatalogFormats.time(DateTime.utc(2026, 10, 22, 3, 41)), '09:41');
      expect(CatalogFormats.time(DateTime.utc(2026, 10, 22, 20, 5)), '02:05');
      expect(CatalogFormats.qty(Qty.units(24)), '24');
      expect(CatalogFormats.qty(const Qty(2500)), '2,5');
      expect(CatalogFormats.qty(const Qty(-3000)), '−3');
      expect(CatalogFormats.splitAction('Не удалось загрузить · Повторить'), ('Не удалось загрузить', 'Повторить'));
      expect(CatalogFormats.splitAction('Каталог загружен'), ('Каталог загружен', null));
    });

    test('InMemoryCatalogPrefs: вид по классу окна и сортировка раздельно для поиска', () async {
      final InMemoryCatalogPrefs p = InMemoryCatalogPrefs();
      await p.setSort(CatalogSort.skuAsc, search: false);
      expect(await p.sort(search: false), CatalogSort.skuAsc);
      expect(await p.sort(search: true), isNull);
      expect(CatalogDefaults.viewFor(WindowClass.compact).value, 'list');
      expect(CatalogDefaults.viewFor(WindowClass.expanded).value, 'grid');
    });
  });
}
