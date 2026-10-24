# src/db — миграции, seed и Drizzle-схема (RM-C-006)

| Путь | Назначение |
|---|---|
| `../../migrations/NNNN_*.sql` | Источник истины схемы (forward-only, expand → migrate → contract — 07 §15.2). `0001_init.sql` — DDL RM-B-005, `0002_rbac_seed.sql` — RBAC RM-B-008 |
| `../../seeds/NNNN_*.sql` | Идемпотентный seed (`ON CONFLICT DO NOTHING`): `app_settings` (ключи R0 §17.7 + `customer_stock_display`), вид цены «Розничная» `[ТИПОВО]`, «Розничный покупатель», `role_discount_limits` (Q-015) |
| `migrator.ts` | Применение миграций: журнал `pos_meta.schema_migrations` (версия, имя, sha256, кто/когда), advisory lock, файл + запись журнала — одна транзакция, изменённый применённый файл → `MIGRATION_CHECKSUM_MISMATCH`; `app.env` = `APP_ENV` |
| `migrator-config.ts` | Подключение: логин `pos_migrate` + пароль из `DB_MIGRATOR_PASSWORD_FILE`, хост/порт/БД — из `DATABASE_URL(_FILE)`; без пароля — только `APP_ENV=dev` (пользователь `DATABASE_URL`, предупреждение) |
| `../migrate.ts` | Точка входа контейнера `migrate`: `node dist/migrate.js` (миграции), `--seed` (миграции + seed) |
| `schema/*.ts` | Drizzle-схема всех 64 таблиц и 45 enum-ов — **генерируется** из каталога PostgreSQL (`npx tsx test/db/codegen/gen-drizzle-schema.ts && npx prettier --write src/db/schema`); FK, CHECK, индексы, триггеры — только в SQL |
| `database.ts` | `createDatabase(pool)` → `PosDatabase` (Drizzle со схемой) |

Новая миграция: файл `migrations/NNNN_описание.sql` → перегенерировать `schema/*.ts` → `npx vitest run --config
test/db/vitest.config.ts` (сверка Drizzle ↔ БД, 0 изменений при повторе, `docs/erd/schema_v1.sql` —
`UPDATE_SCHEMA_DUMP=1`). Файл, которому нужен запуск вне транзакции (`CREATE INDEX CONCURRENTLY`), начинается
строкой `-- pos-migrate: no-transaction`.

Локаль БД должна давать Unicode-регистр (en_US.UTF-8, ru_RU.UTF-8 или builtin `C.UTF-8`): иначе `norm_search()`
не приводит кириллицу к нижнему регистру (мигратор пишет предупреждение).
