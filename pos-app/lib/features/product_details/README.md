# features/product_details

Экраны: SCR-14 `/catalog/p/:productId?variantId=&qty=` (карточка товара), SCR-15 — лист «Выбор варианта»,
SCR-16 — нампад «Ввод количества» (листы без маршрута). Реализация — этап E, RM-E-008.
Может зависеть (DAG фич, 06 §6.1): catalog, cart.

- `domain/entities/qty_rules.dart` — правила количества (10 §4.1, INV-001…010): шаг, начальное, `QTY_NOT_MULTIPLE`,
  `QTY_BELOW_MIN`, точность, целые упаковки, пересчёт упаковок (INV-003).
- `domain/entities/variant_axes.dart` — оси выбора варианта по характеристикам (INV-012).
- `presentation/notifiers/product_details_notifier.dart` — `productDetailsProvider(args)`: кэш drift → `GET /catalog/products/{id}`,
  выбор варианта/упаковки/количества, «В корзину» в локальный черновик (`cartDraftRepositoryProvider`).
- `presentation/screens/product_details_screen.dart` — компоновка compact / medium / expanded (панель).
- `presentation/widgets/` — зоны B–E, нампад (контекст `productCard`), SCR-15.
- `product_details_providers.dart` — `customerStockDisplayProvider`, `productImageBaseUriProvider`, `productStockStaleAfterProvider`.

Правила импортов проверяет `python -I -X utf8 scripts/check_layers.py` (pos-app/NOTES.md §4).
