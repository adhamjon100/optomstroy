import { Inject, Injectable, Logger } from '@nestjs/common';
import type pg from 'pg';
import { PG_POOL } from '../common/db/database.module.js';
import { PgBossService } from '../common/jobs/pg-boss.service.js';
import { SYNC_FRESHNESS_PROBE, type SyncFreshness, type SyncFreshnessProbe } from './sync-freshness.probe.js';

export const API_VERSION = '1.0';
const CHECK_TIMEOUT_MS = 2_000;

export type ReadinessResult =
  | {
      readonly status: 'ok' | 'degraded';
      readonly checks: { db: 'ok'; worker: 'ok'; sync: { stockAgeSec?: number; stale: boolean } };
    }
  | { readonly status: 'failed' };

@Injectable()
export class HealthService {
  private readonly logger = new Logger('health');

  constructor(
    @Inject(PG_POOL) private readonly pool: Pick<pg.Pool, 'query'>,
    private readonly boss: PgBossService,
    @Inject(SYNC_FRESHNESS_PROBE) private readonly sync: SyncFreshnessProbe,
  ) {}

  liveness(now: Date = new Date()): { status: 'ok'; apiVersion: string; serverTime: string } {
    return { status: 'ok', apiVersion: API_VERSION, serverTime: now.toISOString() };
  }

  /** Готовность (08 §4.19.1): БД и pg-boss обязательны (иначе failed → 503); устаревшая синхронизация → degraded. */
  async readiness(): Promise<ReadinessResult> {
    const [db, worker, sync] = await Promise.all([
      withTimeout(
        this.pool.query('SELECT 1').then(() => true),
        CHECK_TIMEOUT_MS,
      ).catch((err: unknown) => {
        this.logger.warn({ err, check: 'db' }, 'readiness check failed');
        return false;
      }),
      withTimeout(this.boss.isReady(), CHECK_TIMEOUT_MS).catch(() => false),
      this.sync.check().catch((): SyncFreshness => ({ stale: true, implemented: true })),
    ]);
    if (!db || !worker) return { status: 'failed' };
    const syncCheck =
      sync.stockAgeSec === undefined ? { stale: sync.stale } : { stockAgeSec: sync.stockAgeSec, stale: sync.stale };
    return { status: sync.stale ? 'degraded' : 'ok', checks: { db: 'ok', worker: 'ok', sync: syncCheck } };
  }
}

function withTimeout<T>(p: Promise<T>, ms: number): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const t = setTimeout(() => reject(new Error(`timeout ${ms}ms`)), ms);
    p.then(
      (v) => {
        clearTimeout(t);
        resolve(v);
      },
      (e: unknown) => {
        clearTimeout(t);
        reject(e instanceof Error ? e : new Error(String(e)));
      },
    );
  });
}
