import { Inject, Injectable, Logger } from '@nestjs/common';
import type pg from 'pg';
import { PG_POOL } from '../db/database.module.js';

/**
 * Чтение `app_settings` для всех модулей (06 §7.4 п. (е), `common/settings`): кэш на ключ с TTL, чтобы
 * изменение настройки действовало без перезапуска API (RM-C-015 п. 2). Запись — только модуль admin.
 * Ошибка БД не роняет запрос: возвращается последнее известное значение (или `undefined` → fallback на env).
 */
export const SETTINGS_CACHE_TTL_MS = 10_000;

interface Entry {
  value: unknown;
  loadedAt: number;
}

@Injectable()
export class SettingsReader {
  private readonly logger = new Logger('SettingsReader');
  private readonly cache = new Map<string, Entry>();
  private readonly inflight = new Map<string, Promise<unknown>>();
  private lastErrorLogAt = 0;

  constructor(
    @Inject(PG_POOL) private readonly pool: Pick<pg.Pool, 'query'>,
    private readonly now: () => number = Date.now,
  ) {}

  /** Значение из кэша без ожидания; устаревшее значение обновляется в фоне. */
  peek(key: string): unknown {
    const entry = this.cache.get(key);
    if (!entry || this.now() - entry.loadedAt >= SETTINGS_CACHE_TTL_MS) void this.get(key);
    return entry?.value;
  }

  /** Значение с ожиданием загрузки (если кэш устарел). */
  async get(key: string): Promise<unknown> {
    const entry = this.cache.get(key);
    if (entry && this.now() - entry.loadedAt < SETTINGS_CACHE_TTL_MS) return entry.value;
    const pending = this.inflight.get(key);
    if (pending) return pending;
    const p = this.load(key).finally(() => this.inflight.delete(key));
    this.inflight.set(key, p);
    return p;
  }

  invalidate(key?: string): void {
    if (key === undefined) this.cache.clear();
    else this.cache.delete(key);
  }

  private async load(key: string): Promise<unknown> {
    try {
      const res = await this.pool.query<{ value: unknown }>('SELECT value FROM app_settings WHERE key = $1', [key]);
      const value = res.rows[0]?.value;
      this.cache.set(key, { value, loadedAt: this.now() });
      return value;
    } catch (e) {
      const t = this.now();
      if (t - this.lastErrorLogAt > 60_000) {
        this.lastErrorLogAt = t;
        this.logger.warn({ err: e, key }, 'app_settings unavailable, using cached/env fallback');
      }
      const stale = this.cache.get(key);
      // Повторная попытка не раньше чем через TTL: значение остаётся прежним.
      this.cache.set(key, { value: stale?.value, loadedAt: t });
      return stale?.value;
    }
  }
}
