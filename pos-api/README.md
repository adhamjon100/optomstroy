# pos-api — backend «Оптомстрой POS» (NestJS 12, Node 24, TypeScript strict, ESM)

Модульный монолит (D-45, 06 §7): один код для `pos-api` (HTTP, порт **3000**, наружу — только через pos-proxy)
и `pos-worker` (`WORKERS_ENABLED`, RM-C-007). Каркас — задача **RM-C-005** (+ backend-части RM-C-009, RM-C-010, RM-C-015).

## Команды

| Команда | Что делает |
|---|---|
| `npm ci` | установка зависимостей (владелец `package.json` — RM-C-005; другие задачи этапа C зависимости не меняют) |
| `npm run lint` | `tsc --noEmit` (src + test) → ESLint (typescript-eslint, type-aware; границы `common/** ↛ модули D-06`) → Prettier `--check` |
| `npm run build` | `tsc -p tsconfig.build.json` → `dist/` |
| `npm test` | unit-тесты Vitest (`src/**/*.spec.ts`), БД не нужна |
| `npm run test:e2e` | e2e (`test/e2e/**/*.e2e-spec.ts`) на одноразовом PostgreSQL 17 (`embedded-postgres`, без Docker); фильтр: `npm run test:e2e -- health` |
| `npm run test:integrations` | изолированный тестовый режим RM-C-008 (`test/integrations/**/*.spec.ts`: FakeSms/FakeOnec/платёжные провайдеры, prod-guard, `issue_test_jwt`) |
| `npm run test:worker` | worker и планировщик RM-C-007 (`test/worker/**/*.spec.ts`, embedded PostgreSQL 17) |
| `npm run test:db` | миграции/seed/Drizzle-сверка RM-C-006 и поведенческие проверки DDL `test/sql/check_ddl_behavior.sql` (`test/db/**/*.db-spec.ts`) |
| `npm run test:all` | все наборы подряд: unit → integrations → worker → db → e2e |
| `node scripts/local-stack.mjs smoke` | e2e smoke **настоящих процессов** без Docker: embedded PostgreSQL 17 → `dist/migrate.js` → `--seed` (дважды) → `dist/main.js` (`ONEC_MODE=fixtures`, `SMS_PROVIDER=fake`): `/health`, `/health/ready`, 426, `APP_READ_ONLY` (нужен `npm run build`) |
| `node scripts/local-stack.mjs serve [--ttl <сек>]` | тот же стек, API держится на `http://127.0.0.1:3000` — для `pos-app/integration_test/boot_test.dart` (RM-C-014) и ручной проверки |
| `npm run madge` | `madge --circular src` (настройки — `.madgerc`: расширение `ts`, `tsconfig.json`) — 0 циклов (RM-B-010) |
| `npm start` | `node dist/main.js` |
| `npm run migrate` / `npm run seed` | `node dist/migrate.js` / `node dist/migrate.js --seed` — точка входа создаёт RM-C-006 (`src/migrate.ts`) |
| `npm run worker` | `node dist/worker.js` — точка входа создаёт RM-C-007 (`src/worker.ts`) |
| `npm run gen:enums` | `scripts/gen_enums.py` (RM-B-009) → `src/common/enums.ts` |
| `npm run gen:permissions` / `check:permissions` | `contracts/rbac/permissions.yaml` → `src/common/rbac/permissions.generated.ts` / проверка актуальности |

**Память при регрессе (ревью G-fresh-run-1, G-fresh-run-2).** Наборы на embedded PostgreSQL (`test:cart`, `test:all`,
`test:cov:*`) поднимают по экземпляру PostgreSQL на файл и параллельно запускают воркеры Vitest. При нехватке памяти
(Windows: файл подкачки не может вырасти — `could not create shared memory segment: error code 1455`, «JavaScript heap
out of memory», `Worker exited unexpectedly`) падение — окружение, а не код: регресс запускают на свободной памяти, не
параллельно с другими тяжёлыми прогонами (например, `flutter test --coverage`), и при необходимости ограничивают число
воркеров: `npx vitest run --config ./test/cart/vitest.config.ts --maxWorkers=1`,
`npx vitest run --coverage --config ./vitest.config.cov-g.ts --maxWorkers=2`. `TEMP`/`TMP` — на диске с местом
(`export TEMP=D:/optomstroy/.tmp TMP=D:/optomstroy/.tmp`). Покрытие при неполном прогоне (упавшие воркеры) не
сравнивается с порогами — прогон повторяют.

Минимальный запуск (dev): `APP_ENV=dev MIN_APP_VERSION=android=1.0.0,windows=1.0.0 DATABASE_URL=postgres://… node dist/main.js`
— `GET /health` отвечает 200 и без БД; `GET /health/ready` → 503 `{status: failed}`, пока недоступны БД или pg-boss.

## Структура `src/`

| Путь | Назначение |
|---|---|
| `main.ts`, `bootstrap/create-app.ts`, `app.module.ts` | bootstrap, глобальные guard/interceptor/filter/pipe, префикс `/api/v1` (кроме `/health*`, `/openapi.json`) |
| `auth`, `registration`, `profile`, `catalog`, `cart`, `orders`, `payments`, `customers`, `transactions`, `returns`, `sync`, `admin`, `notifications` | модули D-06 — пока пустые (06 §7.4) |
| `health/` | `GET /health`, `GET /health/ready` (БД, pg-boss; возраст синхронизации — заглушка `SYNC_FRESHNESS_PROBE`), `GET /openapi.json` |
| `common/config/` | zod-схема env (имена — только 16 §4.3), конвенция `*_FILE` |
| `common/problem-details/` | RFC 9457, `ProblemException(code)` — `code` только из `common/enums.ts` (08 §2.4) |
| `common/rbac/` | `@Public()`, `@RequirePermission()`, `@RequireAnyPermission()`, `RbacGuard` (deny by default) |
| `common/read-only/` | `ReadOnlyGuard` (`APP_READ_ONLY`), перечень ADR-083 |
| `common/idempotency/` | `@Idempotent()`, `IdempotencyInterceptor`, `IdempotencyService`, `PgIdempotencyStore` (`idempotency_keys`) |
| `common/app-version/` | `X-App-Version`/`X-Platform` → 426, заголовки `X-Min-App-Version`/`X-Recommended-App-Version` |
| `common/logging/` | pino/nestjs-pino, requestId (`X-Request-Id`), redaction ПДн/секретов |
| `common/money/` | `Money`/`Quantity` на decimal.js (NUMERIC-строки) |
| `common/db/`, `common/settings/`, `common/jobs/` | пул pg + Drizzle, `SettingsReader` (`app_settings`), pg-boss и контракты очередей (B-AR-12) |

Субъект запроса (`req.principal`) заполняет `common/auth-context` этапа D; до этого RBAC отвечает 401 на все защищённые маршруты.
