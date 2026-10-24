// T-CAT-011, T-CAT-002, T-CAT-009 (widget): SCR-11 «Результаты поиска» (RM-E-007 критерий 2).
// Поиск не вызывает API при < 2 символов (цифры — с 1) и не чаще 1 раза в 300 мс; Enter — сразу;
// ответ устаревшего запроса не заменяет более новый; чипы matchType фильтруют загруженное; пусто;
// офлайн-пометка; «Введите ещё N символ» и недавние запросы (телефоны не сохраняются).
import 'dart:async';

import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/error/screen_state.dart';
import 'package:optomstroy/design_system/components/product_card.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/domain/entities/search.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_search_screen.dart';

import 'support/catalog_fakes.dart';

Finder get _field => find.descendant(
  of: find.byKey(const ValueKey<String>('catalog-search-field')),
  matching: find.byType(EditableText),
);

Future<CatalogHarness> _pump(WidgetTester tester, CatalogHarness h, {String? q, Size size = kExpanded}) async {
  setWindow(tester, size);
  await tester.pumpWidget(catalogApp(h, home: CatalogSearchScreen(q: q)));
  await settle(tester);
  return h;
}

/// Ввод посимвольно с паузой [gap] между символами.
Future<void> _typeSlowly(WidgetTester tester, String text, {Duration gap = const Duration(milliseconds: 100)}) async {
  for (int i = 1; i <= text.length; i++) {
    await tester.enterText(_field, text.substring(0, i));
    await tester.pump(gap);
  }
}

void main() {
  testWidgets('1 буква — «Введите ещё 1 символ», запроса нет; 2 символа — один запрос через 300 мс', (tester) async {
    final CatalogHarness h = await _pump(tester, CatalogHarness());
    expect(find.byKey(const ValueKey<String>('stub-SCR-11')), findsOneWidget);
    await tester.enterText(_field, 'с');
    await tester.pump(const Duration(milliseconds: 600));
    expect(h.search.queries, isEmpty);
    expect(find.byKey(const ValueKey<String>('search-more-chars')), findsOneWidget);
    expect(find.textContaining('Введите ещё 1'), findsOneWidget);

    await tester.enterText(_field, 'см');
    await tester.pump(const Duration(milliseconds: 299));
    expect(h.search.queries, isEmpty, reason: 'не раньше 300 мс после последнего символа');
    await tester.pump(const Duration(milliseconds: 2));
    await settle(tester);
    expect(h.search.queries, <String>['см']);
    expect(find.byType(ProductCardGrid), findsNWidgets(2));
  });

  testWidgets('6 символов с интервалом 100 мс — ровно 1 сетевой запрос (AC-UI-11-001)', (tester) async {
    final CatalogHarness h = await _pump(tester, CatalogHarness());
    await _typeSlowly(tester, 'смесит');
    expect(h.search.queries, isEmpty);
    await tester.pump(const Duration(milliseconds: 300));
    await settle(tester);
    expect(h.search.queries, <String>['смесит']);
  });

  testWidgets('строка из 1 цифры запускает поиск (артикул/штрихкод)', (tester) async {
    final CatalogHarness h = await _pump(tester, CatalogHarness());
    await tester.enterText(_field, '4');
    await tester.pump(const Duration(milliseconds: 350));
    await settle(tester);
    expect(h.search.queries, <String>['4']);
  });

  testWidgets('Enter — немедленный поиск без ожидания debounce; таймер сбрасывается', (tester) async {
    final CatalogHarness h = await _pump(tester, CatalogHarness());
    await tester.enterText(_field, 'F4252');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await settle(tester);
    expect(h.search.queries, <String>['F4252']);
    await tester.pump(const Duration(milliseconds: 400));
    expect(h.search.queries, <String>['F4252'], reason: 'отложенный запрос не дублируется');
  });

  testWidgets('ответ устаревшего запроса не заменяет результаты нового (AC-UI-11-007)', (tester) async {
    final FakeSearchRepository search = FakeSearchRepository();
    final Completer<void> slow = Completer<void>();
    search.holds['смес'] = slow;
    final CatalogHarness h = await _pump(tester, CatalogHarness(search: search));
    await tester.enterText(_field, 'смес');
    await tester.pump(const Duration(milliseconds: 310));
    await settle(tester);
    await tester.enterText(_field, 'смеси');
    await tester.pump(const Duration(milliseconds: 310));
    await settle(tester);
    expect(find.text('Смеситель смеси артикул'), findsOneWidget);
    slow.complete();
    await settle(tester);
    expect(h.search.queries, <String>['смес', 'смеси']);
    expect(find.text('Смеситель смеси артикул'), findsOneWidget);
    expect(find.text('Смеситель смес артикул'), findsNothing);
  });

  testWidgets('чипы matchType: счётчики из ответа; «Артикул» оставляет только matchType=sku', (tester) async {
    await _pump(tester, CatalogHarness(), q: 'L74103');
    expect(find.text('Найдено: 2 по «L74103»'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('chip-match-sku')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('chip-match-sku')));
    await settle(tester);
    final List<ProductCardGrid> cards = tester.widgetList<ProductCardGrid>(find.byType(ProductCardGrid)).toList();
    expect(cards, hasLength(1));
    expect(cards.single.data.matchLabel, 'артикул');
  });

  testWidgets('UI-11-009: поиск с SCR-12 — чип «В категории «…»» ограничивает поиск; «Во всех категориях» — без', (
    tester,
  ) async {
    final CatalogHarness h = CatalogHarness();
    setWindow(tester, kExpanded);
    await tester.pumpWidget(
      catalogApp(
        h,
        home: const CatalogSearchScreen(q: 'L74103', categoryId: 'c-mix'),
      ),
    );
    await settle(tester);
    final Finder scope = find.byKey(const ValueKey<String>('chip-search-scope'));
    expect(scope, findsOneWidget);
    expect(find.text('В категории «Смесители»'), findsOneWidget);
    expect(h.search.calls.last.filter.categoryId, 'c-mix');
    expect(h.search.calls.last.filter.includeSubcategories, isTrue);

    await tester.ensureVisible(scope);
    await tester.tap(scope);
    await settle(tester);
    expect(find.text('Во всех категориях'), findsOneWidget);
    expect(h.search.calls.last.q, 'L74103');
    expect(h.search.calls.last.filter.categoryId, isNull);
  });

  testWidgets('UI-11-009: поиск из корня каталога — чипа области нет', (tester) async {
    await _pump(tester, CatalogHarness(), q: 'L74103');
    expect(find.byKey(const ValueKey<String>('chip-search-scope')), findsNothing);
  });

  testWidgets('пустой результат: «Ничего не найдено по «…»» и «Возможно, вы искали»', (tester) async {
    final FakeSearchRepository search = FakeSearchRepository()
      ..results = (String q) =>
          SearchResult(query: q, page: page(const <ProductSummary>[]), suggestedQuery: 'смеситель');
    await _pump(tester, CatalogHarness(search: search), q: 'смиситель');
    expect(find.text('Ничего не найдено по «смиситель»'), findsOneWidget);
    expect(find.text('Возможно, вы искали «смеситель»'), findsOneWidget);
    await tester.tap(find.text('Возможно, вы искали «смеситель»'));
    await settle(tester);
    expect(search.queries.last, 'смеситель');
  });

  testWidgets('офлайн: «Поиск по сохранённому каталогу от …», результаты из кэша', (tester) async {
    final _OfflineSearch search = _OfflineSearch();
    await _pump(tester, CatalogHarness(search: search), q: 'смес');
    expect(find.byKey(const ValueKey<String>('search-offline-note')), findsOneWidget);
    expect(find.byType(ProductCardGrid), findsOneWidget);
  });

  testWidgets('сортировки поиска: «По релевантности» по умолчанию, «По артикулу» → sort=sku:asc', (tester) async {
    final CatalogHarness h = await _pump(tester, CatalogHarness(), q: 'смес');
    expect(h.search.calls.single.sort, CatalogSort.relevanceDesc);
    await tester.tap(find.byKey(const ValueKey<String>('catalog-sort')));
    await tester.pumpAndSettle();
    expect(find.text('По релевантности'), findsWidgets);
    await tester.tap(find.text('По артикулу').last);
    await settle(tester);
    expect(h.search.calls.last.sort, CatalogSort.skuAsc);
    expect(h.search.calls.last.q, 'смес');
  });

  testWidgets('история запросов: телефон не сохраняется, артикул сохраняется', (tester) async {
    final CatalogHarness h = await _pump(tester, CatalogHarness(), size: kCompact);
    await tester.enterText(_field, '+996 555 123 456');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await settle(tester);
    await tester.enterText(_field, 'F4252-CR');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await settle(tester);
    expect(h.search.queries, <String>['+996 555 123 456', 'F4252-CR']);
    await tester.enterText(_field, '');
    await settle(tester);
    expect(find.byKey(const ValueKey<String>('search-history-F4252-CR')), findsOneWidget);
    expect(find.textContaining('+996'), findsNothing);
  });
}

/// Сервер недоступен: `searchProducts` → сеть недоступна, кэш даёт 1 товар.
final class _OfflineSearch extends FakeSearchRepository {
  @override
  Future<Result<SearchResult>> searchProducts(SearchQuery query) async {
    queries.add(query.q);
    return const FailureResult<SearchResult>(kOffline);
  }

  @override
  Future<Result<SearchResult>> searchCached(SearchQuery query) async => Success<SearchResult>(
    SearchResult(
      query: query.q,
      page: page(<ProductSummary>[product(1, matchType: MatchType.fts)], source: DataSource.cache),
    ),
  );
}
