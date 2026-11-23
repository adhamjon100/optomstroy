// Пределы сетки товаров (15 ADR-114, уточнение 2026-11-18; 03 §7.3 ред. 1.25; 02 AC-UI-10-035 ред. 1.32). Указание
// владельца 2026-11-18 (чат, дословно): «i pri zume ili na oborot setka tovarov doljna menyatsya 3 ili 4  5 i tak alee
// no postav ogranicheniya» (прочтение исполнителя: «и при зуме или наоборот сетка товаров должна меняться — 3 или 4, 5
// и так далее, но поставь ограничения»). Правило: колонки — auto-fill от минимума карточки (176; SCR-50 — 160), не
// меньше 2 и не больше предела класса окна (токены 1.4.0, пакет own-server:GAP-APP: compact 3, medium 4, expanded 5,
// large 6 — не больше 6 ни в одном окне; в 1.3.0 было 7 / 9; SCR-50 — ещё и 6); карточка не шире 280: шире — область
// товаров (блоки над списком и сетка) не растягивается и стоит по центру зоны (пустые полосы поровну слева и справа).
// Тест-кейсы 12_TEST_PLAN: T-CAT-038 (сетка каталога; ред. 1.20 — пределы и прогон ширин 320…2560 с шагом 40, масштаб
// текста 1 и 1,3, отдаление в браузере 2880/3200/3840), T-DS-104 (токены пределов). SCR-50 и SCR-51 — тот же прогон в
// `customer_home_screen_test.dart` и `kiosk_catalog_view_test.dart`. Данные синтетические.
import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/enums.dart' show RoleCode;
import 'package:optomstroy/design_system/components/product_card.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/domain/entities/search.dart';
import 'package:optomstroy/features/catalog/presentation/screens/catalog_search_screen.dart';
import 'package:optomstroy/features/catalog/presentation/screens/category_screen.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_toolbar.dart';

import '../../../design_system/ds_test_support.dart' show loadInterFont;

import 'support/catalog_fakes.dart';
import 'support/grid_sweep.dart';

/// 12 товаров: первый ряд при наибольшем пределе (6) заполнен дважды; самые длинные цены — в узких карточках.
List<ProductSummary> _items() => <ProductSummary>[
  product(0, priceSom: 10450),
  product(1, priceSom: 99999999, name: 'Смеситель для кухни с длинным названием, выдвижной лейкой и гибким шлангом'),
  product(2, hasVariants: true, variantCount: 3, priceSom: 450),
  ...products(9, from: 3),
];

GoRouter _router(String initial) => GoRouter(
  initialLocation: initial,
  routes: <RouteBase>[
    GoRoute(
      path: '/catalog/c/:categoryId',
      builder: (BuildContext c, GoRouterState s) =>
          CategoryScreen(categoryId: s.pathParameters['categoryId']!, view: s.uri.queryParameters['view']),
    ),
    GoRoute(
      path: '/catalog/search',
      builder: (BuildContext c, GoRouterState s) =>
          CatalogSearchScreen(q: s.uri.queryParameters['q'], view: s.uri.queryParameters['view']),
    ),
    GoRoute(path: '/catalog/p/:productId', builder: (BuildContext c, GoRouterState s) => const SizedBox()),
  ],
);

/// Прогон экрана [initial] роли [role]: окно меняется без пересоздания экрана (как перетаскивание края окна, поворот
/// планшета или масштаб страницы в браузере).
Future<GridSweep> _sweep(
  WidgetTester tester, {
  required String label,
  required String initial,
  RoleCode role = RoleCode.seller,
  double textScale = 1,
  Iterable<double>? widths,
}) async {
  await tester.runAsync(loadInterFont);
  if (textScale != 1) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
  final FakeSearchRepository search = FakeSearchRepository()
    ..results = (String q) => SearchResult(query: q, page: page(_items()));
  final CatalogHarness h = CatalogHarness(
    role: role,
    catalog: FakeCatalogRepository(items: _items()),
    search: search,
  );
  final GoRouter router = _router(initial);
  addTearDown(router.dispose);
  final GridSweep sweep = GridSweep(label: label, minCardWidth: DsBreakpoints.catalogCardMinWidth);
  bool first = true;
  for (final double w in widths ?? <double>[...kGridSweepWidths, ...kGridZoomOutWidths]) {
    setWindow(tester, Size(w, 900));
    if (first) {
      await tester.pumpWidget(catalogApp(h, router: router));
      first = false;
    }
    await settle(tester);
    sweep.check(tester, w, note: textScale == 1 ? null : 'текст ×$textScale');
  }
  return sweep;
}

void main() {
  group('правило 03 §7.3 (T-DS-104, T-CAT-038)', () {
    test('колонки: от 2 до предела класса окна, без убывания с шириной; карточка ≥ минимума, кроме вынужденных 2; '
        'шире предела × 280 — ровно предел колонок по 280', () {
      for (final WindowClass wc in WindowClass.values) {
        for (final (double minCard, double gap, int? screenMax) in <(double, double, int?)>[
          (DsBreakpoints.catalogCardMinWidth, 14, null),
          (DsBreakpoints.catalogCardMinWidth, 16, null),
          (DsBreakpoints.cardMinWidth, 12, DsBreakpoints.gridMaxColumns),
          (DsBreakpoints.cardMinWidth, 16, DsBreakpoints.gridMaxColumns),
        ]) {
          final int cap = DsBreakpoints.gridColumnsCap(wc, maxColumns: screenMax);
          final double bound = DsBreakpoints.gridMaxContentWidth(cap, gap);
          int previous = 0;
          for (double w = 0; w <= 4000; w += 2) {
            final double content = w < bound ? w : bound; // область не шире предела (CatalogProductView)
            final int n = DsBreakpoints.gridColumns(
              content,
              gap,
              windowClass: wc,
              minCardWidth: minCard,
              maxColumns: screenMax,
            );
            final String at = '${wc.name}, min $minCard, gap $gap, W $w';
            expect(n, inInclusiveRange(DsBreakpoints.gridMinColumns, cap), reason: at);
            expect(n, greaterThanOrEqualTo(previous), reason: '$at: без убывания');
            previous = n;
            final double card = (content - gap * (n - 1)) / n;
            expect(card, lessThanOrEqualTo(DsBreakpoints.gridCardMaxWidth + 1e-9), reason: '$at: не шире 280');
            if (n > DsBreakpoints.gridMinColumns) {
              expect(card, greaterThanOrEqualTo(minCard - 1e-9), reason: '$at: не уже минимума');
            }
            if (w >= bound) {
              expect(n, cap, reason: '$at: предел');
              expect(card, closeTo(DsBreakpoints.gridCardMaxWidth, 1e-9), reason: '$at: карточка 280');
            }
          }
        }
      }
    });

    test('окна прототипа (ADR-114) с пределами 1.4.0: 1024 / 1280 / 1366 / 1440 / 1536 / 1920 → 4 / 5 / 5 / 5 / 5 / 6 '
        '(прототип — 4 / 5 / 6 / 6 / 7 / 9); шире 1920 — 6 (предел large), отдаление 50 % на 1920 — 6 по 280', () {
      // Ширина контента сотрудника = окно − колонка 144 − поля 8 + 24 (02 П.3 п. 6).
      int staff(double window) => DsBreakpoints.gridColumns(
        window - 176,
        DsCatalogMetrics.gridGap,
        windowClass: DsBreakpoints.forWidth(window),
        minCardWidth: DsCatalogMetrics.gridMinCard,
      );
      expect(
        <int>[
          for (final double w in <double>[1024, 1280, 1366, 1440, 1536, 1920]) staff(w),
        ],
        <int>[4, 5, 5, 5, 5, 6],
      );
      expect(
        <int>[
          for (final double w in <double>[1600, 2062, 2133, 2400, 2560]) staff(w),
        ],
        <int>[6, 6, 6, 6, 6],
      );
      // Диапазоны просьбы владельца по классам окна (каталог сотрудника, текст 1): expanded 4–5 (5 — с 1112 lp),
      // large — 6 с первого окна класса; medium 3–4 — с 732 lp (уже — 2: карточка не уже 176).
      expect(<int>[staff(1023), staff(1024), staff(1111), staff(1112), staff(1599)], <int>[4, 4, 4, 5, 5]);
      expect(<int>[staff(600), staff(731), staff(732), staff(921), staff(922)], <int>[2, 2, 3, 3, 4]);
      expect(((1600 - 176 + 14) / (176 + 14)).floor(), 7, reason: 'без предела large на 1600 было бы 7');
      // Масштаб 200 % на 1920 — окно 960 (medium): 4; 300 % — 640: 2; телефон 360 (сетка compact, зазор 16): 2.
      expect(staff(960), 4);
      expect(staff(640), 2);
      expect(
        DsBreakpoints.gridColumns(328, 16, windowClass: WindowClass.compact, minCardWidth: 176),
        DsBreakpoints.gridMinColumns,
      );
      // Предел ширины области сотрудника на large: 6 × 280 + 5 × 14 = 1750 (окно ≈ 1926 с колонкой и полями).
      expect(DsBreakpoints.gridMaxContentWidth(6, DsCatalogMetrics.gridGap), 1750);
    });
  });

  group('прогон ширин 320…2560 (шаг 40) и отдаление 2880/3200/3840 (T-CAT-038)', () {
    testWidgets('SCR-12 сотрудник: сетка во всех классах окна, пределы, без переполнения', (tester) async {
      final GridSweep s = await _sweep(tester, label: 'SCR-12 продавец', initial: '/catalog/c/c-mix?view=grid');
      s.expectMonotonic(expectGridIn: WindowClass.values.toSet());
      // Пределы 1.4.0: 1040 — 4, 1280 и 1440 — 5, 1920 и шире — 6; 3840 — 6 по 280 (область не растягивается).
      int at(double w) => s.rows.firstWhere((GridSweepRow r) => r.width == w).columns;
      expect(
        <int>[at(1040), at(1280), at(1440), at(1920), at(2560), at(3840)],
        <int>[4, 5, 5, 6, 6, 6],
        reason: s.describe(),
      );
      expect(s.rows.every((GridSweepRow r) => r.columns <= 6), isTrue, reason: 'не больше 6: ${s.describe()}');
      expect(s.rows.firstWhere((GridSweepRow r) => r.width == 3840).card, closeTo(280, 0.01));
      // Строка управления (переключатель вида справа) — в пределах той же области, что и сетка.
      final Rect toolbar = tester.getRect(find.byType(CatalogToolbarControls).first);
      final List<Rect> row = firstGridRow(tester);
      expect(
        toolbar.right,
        lessThanOrEqualTo(row.last.right + 24 + 0.01),
        reason: '3840: строка управления над сеткой',
      );
      // 3840: область товаров по центру своей зоны — пустые полосы поровну слева и справа от карточек (ревью: прежде
      // область стояла у колонки категорий, справа — одна широкая пустая полоса; токены 1.4.0).
      final Rect zone = tester.getRect(find.byKey(const ValueKey<String>('catalog-products')));
      expect(row.first.left - zone.left, closeTo(zone.right - row.last.right, 1), reason: '3840: сетка по центру');
      expect(row.first.left - zone.left, greaterThan(400), reason: '3840: полосы есть');
      expect(toolbar.left, greaterThanOrEqualTo(row.first.left - 8 - 0.01), reason: 'строка управления — над сеткой');
    });

    testWidgets('SCR-12 сотрудник, масштаб текста 1,3: карточки без переполнения на всех ширинах', (tester) async {
      final GridSweep s = await _sweep(
        tester,
        label: 'SCR-12 продавец',
        initial: '/catalog/c/c-mix?view=grid',
        textScale: 1.3,
      );
      s.expectMonotonic(expectGridIn: WindowClass.values.toSet());
      // Высота ячейки — по масштабу (крупнее, чем при 1).
      expect(
        tester.getSize(find.byType(ProductCardGrid).first).height,
        greaterThan(kProductCardGridExtent(TextScaler.noScaling)),
      );
    });

    testWidgets('SCR-12 клиент (сайдбар-список на expanded/large): те же пределы', (tester) async {
      final GridSweep s = await _sweep(
        tester,
        label: 'SCR-12 клиент',
        initial: '/catalog/c/c-mix?view=grid',
        role: RoleCode.customer,
        widths: <double>[...kGridSweepWidths, 3840],
      );
      s.expectMonotonic(expectGridIn: WindowClass.values.toSet());
    });

    testWidgets('SCR-11 результаты поиска: те же пределы, масштаб текста 1,3', (tester) async {
      final GridSweep s = await _sweep(
        tester,
        label: 'SCR-11 поиск',
        initial: '/catalog/search?q=смеситель&view=grid',
        textScale: 1.3,
        widths: <double>[...kGridSweepWidths, 3200],
      );
      s.expectMonotonic(expectGridIn: WindowClass.values.toSet());
    });
  });
}
