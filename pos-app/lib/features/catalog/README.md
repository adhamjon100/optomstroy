# features/catalog

Экраны: SCR-10 `/catalog`, SCR-11 `/catalog/search`, SCR-12 `/catalog/c/:categoryId`, SCR-13 `/catalog/filters`
(заглушки — `presentation/screens/{catalog,catalog_search,category,catalog_filters}_screen.dart`).
SCR-14 — `features/product_details`, SCR-17 — `features/scan`, SCR-50 — `features/home` (E_spec_questions EQ-FEF-07).
Может зависеть (DAG фич, 06 §6.1): cart.

Публичный контракт — `catalog_providers.dart`: `catalogRepositoryProvider`, `searchRepositoryProvider`,
`inventoryRepositoryProvider`, `catalogSyncRepositoryProvider`, `syncStatusRepositoryProvider`, `catalogJsonDecoderProvider`.
Порты и сущности — `domain/` (чистый Dart; деньги — `Money`, количества — `Qty`).
Реализации — `data/` (DTO вручную по OpenAPI, ADR-085; Dio — `dioProvider`; кэш — `CatalogDao` локальной БД),
подключаются `data/catalog_bindings.dart` → `app/di/overrides.dart`.

Правила импортов проверяет `python -I -X utf8 scripts/check_layers.py` (pos-app/NOTES.md §4).
