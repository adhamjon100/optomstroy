import { readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import pino, { type Logger } from 'pino';
import { FakeOnecGateway } from '../../src/integrations/onec/fake-onec.gateway.js';
import type {
  SyntheticCatalog,
  SyntheticCatalogOptions,
  SyntheticCatalogStats,
} from '../../src/integrations/onec/synthetic-catalog.js';
import { SYNTHETIC_ANCHORS } from '../../src/integrations/onec/synthetic-catalog.js';
import type { CatalogLoadResult } from '../../src/sync/apply/catalog-full-load.service.js';
import { loadSyntheticCatalog } from '../../src/sync/apply/synthetic-load.js';
import { EmbeddedPg } from './embedded-pg.js';

/**
 * Тестовый каталог для агентов этапа E (RM-E-004…RM-E-017): одноразовый PostgreSQL 17 (embedded) со всеми
 * миграциями `pos-api/migrations/*.sql` и каталогом, загруженным **через конвейер применения 1С** (тот же код, что
 * в проде) из `FakeOnecGateway` в режиме синтетического каталога. **Тестовые данные** (фикстуры 1С + синтетика).
 *
 * ```ts
 * const cat = await startCatalogFixture({ skuCount: 500 });
 * // cat.pool — pg.Pool к БД; cat.refs — onec_ref якорных товаров/складов/видов цен; cat.gateway — фейк 1С
 * await cat.stop();
 * ```
 */
export interface CatalogFixtureOptions {
  /** Число синтетических SKU (по умолчанию 200). */
  readonly skuCount?: number;
  /** Зерно генератора (по умолчанию 1). */
  readonly seed?: number;
  /** Прочие параметры генератора (склады, виды цен, доли вариантов/упаковок/удалённых). */
  readonly catalog?: Omit<SyntheticCatalogOptions, 'skuCount' | 'seed'>;
  /** Добавить справочники и срезы фикстур `contracts/onec/fixtures` (по умолчанию `true`). */
  readonly includeFixtures?: boolean;
  /** Имя БД (по умолчанию `pos_catalog`). */
  readonly database?: string;
  /** Файлы миграций (по умолчанию — все `migrations/*.sql` по имени). */
  readonly migrations?: readonly string[];
  /** Уже запущенный кластер (несколько БД в одном наборе тестов); иначе — свой, останавливается в `stop()`. */
  readonly pg?: EmbeddedPg;
  /** Не загружать каталог (только миграции и фейк 1С). */
  readonly skipLoad?: boolean;
  readonly log?: Logger;
}

export interface CatalogFixture {
  readonly pg: EmbeddedPg;
  readonly database: string;
  /** Строка подключения суперпользователя к тестовой БД. */
  readonly url: string;
  readonly pool: pg.Pool;
  /** Фейк 1С: режим синтетического каталога, план обмена пуст (полная загрузка уже применена). */
  readonly gateway: FakeOnecGateway;
  readonly catalog: SyntheticCatalog;
  readonly stats: SyntheticCatalogStats;
  readonly loadResults: readonly CatalogLoadResult[];
  readonly loadMs: number;
  /** Ссылки 1С (`onec_ref`) для тестов. */
  readonly refs: {
    /** Якорные товары (одинаковы при любом seed): `F4252`, `F3241`, `G1017-8`, `SB-1WH`, `VTP-20`. */
    readonly anchors: Readonly<Record<string, string>>;
    readonly warehouses: readonly string[];
    readonly priceLists: readonly string[];
    /** Товар фикстуры `catalog-card.200` (KX-1245), если `includeFixtures`. */
    readonly fixtureProduct?: string;
  };
  stop(): Promise<void>;
}

export const MIGRATIONS_DIR = fileURLToPath(new URL('../../migrations/', import.meta.url));

/** Все SQL-миграции по имени (forward-only). */
export function allMigrations(): string[] {
  return readdirSync(MIGRATIONS_DIR)
    .filter((f) => /^\d{4}_.+\.sql$/.test(f))
    .sort();
}

export async function startCatalogFixture(options: CatalogFixtureOptions = {}): Promise<CatalogFixture> {
  const ownPg = !options.pg;
  const server = options.pg ?? new EmbeddedPg();
  if (ownPg) await server.start();
  const database = options.database ?? 'pos_catalog';
  let pool: pg.Pool | undefined;
  try {
    await server.createDatabase(database);
    await server.migrate(database, options.migrations ?? allMigrations());
    pool = new pg.Pool({ connectionString: server.url(database), max: 6 });
    const gateway = new FakeOnecGateway({
      catalog: { skuCount: options.skuCount ?? 200, seed: options.seed ?? 1, ...options.catalog },
      includeFixtureCatalog: options.includeFixtures !== false,
      registerAll: false,
    });
    const catalog = gateway.catalog!;
    const loaded = options.skipLoad
      ? undefined
      : await loadSyntheticCatalog(pool, { catalog, log: options.log ?? pino({ level: 'silent' }) });
    const anchors: Record<string, string> = {};
    for (const p of catalog.productItems()) {
      if (p.sku && SYNTHETIC_ANCHORS.some((a) => a.sku === p.sku && a.name === p.description)) anchors[p.sku] = p.ref;
    }
    const fixtureProduct = catalog.productItems().find((p) => p.sku === 'KX-1245')?.ref;
    const p = pool;
    return {
      pg: server,
      database,
      url: server.url(database),
      pool: p,
      gateway,
      catalog,
      stats: catalog.stats(),
      loadResults: loaded?.results ?? [],
      loadMs: loaded?.loadMs ?? 0,
      refs: {
        anchors,
        warehouses: catalog.warehouses.map((w) => w.ref),
        priceLists: catalog.priceLists.map((l) => l.ref),
        ...(fixtureProduct ? { fixtureProduct } : {}),
      },
      stop: async () => {
        await p.end().catch(() => undefined);
        if (ownPg) await server.stop();
      },
    };
  } catch (e) {
    await pool?.end().catch(() => undefined);
    if (ownPg) await server.stop();
    throw e;
  }
}
