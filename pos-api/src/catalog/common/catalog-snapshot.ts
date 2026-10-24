import { Inject, Injectable } from '@nestjs/common';
import type pg from 'pg';
import { PG_POOL } from '../../common/db/database.module.js';
import { latest } from './catalog-format.js';

/**
 * Моменты снимков реплики 1С для `X-Data-As-Of` и `asOf` (08 §2.3, §3.6). Время среза цен/остатков — последний
 * успешный прогон сущности (`sync_state.last_success_at`, EQ-ONEC-03: неизменённые строки при срезе не
 * переписываются), иначе — наибольшая отметка синхронизации строк реплики (индексы `*_synced_idx`).
 */
export interface CatalogSnapshot {
  readonly stockAsOf?: Date;
  readonly pricesAsOf?: Date;
  readonly catalogAsOf?: Date;
  /** Наибольшая из меток — заголовок `X-Data-As-Of` экранов каталога. */
  readonly dataAsOf?: Date;
}

@Injectable()
export class CatalogSnapshotService {
  constructor(@Inject(PG_POOL) private readonly pool: pg.Pool) {}

  async read(): Promise<CatalogSnapshot> {
    const res = await this.pool.query<{
      stock_ok: Date | null;
      prices_ok: Date | null;
      catalog_ok: Date | null;
      stock_rows: Date | null;
      prices_rows: Date | null;
      products_rows: Date | null;
    }>(
      `SELECT (SELECT last_success_at FROM sync_state WHERE entity = 'stock') AS stock_ok,
              (SELECT last_success_at FROM sync_state WHERE entity = 'prices') AS prices_ok,
              (SELECT max(last_success_at) FROM sync_state WHERE entity IN ('products','categories','variants')) AS catalog_ok,
              (SELECT max(synced_at) FROM stock_balances) AS stock_rows,
              (SELECT max(synced_at) FROM prices) AS prices_rows,
              (SELECT max(updated_at) FROM products) AS products_rows`,
    );
    const r = res.rows[0];
    const stockAsOf = latest(r?.stock_ok, r?.stock_rows);
    const pricesAsOf = latest(r?.prices_ok, r?.prices_rows);
    const catalogAsOf = latest(r?.catalog_ok, r?.products_rows);
    return { stockAsOf, pricesAsOf, catalogAsOf, dataAsOf: latest(stockAsOf, pricesAsOf, catalogAsOf) };
  }
}
