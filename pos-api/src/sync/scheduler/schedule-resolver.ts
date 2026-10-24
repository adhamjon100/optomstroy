import type { SyncEntity } from '../../common/enums.js';
import type { SchedulerConfig } from './scheduler.config.js';
import { ENTITY_QUEUES } from './sync-queues.js';

/** Границы `sync_interval.<entity>` в минутах (05 SYNC-021: минимум 2 мин, максимум 24 ч). */
export const SYNC_INTERVAL_MIN_MINUTES = 2;
export const SYNC_INTERVAL_MAX_MINUTES = 1440;
/** Период `onec.changes` по умолчанию (05 SYNC-011: 5 мин). */
export const ONEC_CHANGES_DEFAULT_MINUTES = 5;

export const syncIntervalKey = (entity: SyncEntity): string => `sync_interval.${entity}`;

export interface ResolvedSchedule {
  /** cron-выражение (env) или правило RFC 5545 (`FREQ=MINUTELY;INTERVAL=N`, переопределение в минутах). */
  readonly expression: string;
  readonly source: 'app_settings' | 'env';
  /** Интервал в минутах, если задан `app_settings`. */
  readonly minutes?: number;
}

/** Источник значений `app_settings` (common/settings SettingsReader). */
export interface SettingsSource {
  get(key: string): Promise<unknown>;
}

export interface InvalidSettingReport {
  readonly key: string;
  readonly reason: string;
}

/**
 * Разбор значения `app_settings.sync_interval.<entity>`: целое число минут 2…1440 (05 SYNC-021, 02 UI-46-009).
 * Допускаются JSON-число, строка с числом и объект `{minutes}`. Иначе — `undefined` (fallback на env).
 */
export function parseIntervalMinutes(value: unknown): number | undefined | 'invalid' {
  if (value === undefined || value === null) return undefined;
  let raw: unknown = value;
  if (typeof raw === 'object' && raw !== null && 'minutes' in raw) raw = raw.minutes;
  const n = typeof raw === 'number' ? raw : typeof raw === 'string' && raw.trim() !== '' ? Number(raw) : NaN;
  if (!Number.isInteger(n) || n < SYNC_INTERVAL_MIN_MINUTES || n > SYNC_INTERVAL_MAX_MINUTES) return 'invalid';
  return n;
}

/** Интервал в минутах → правило pg-boss (RFC 5545; якорь — эпоха, фаза одинакова во всех процессах). */
export function minutesToRule(minutes: number): string {
  return `FREQ=MINUTELY;INTERVAL=${minutes}`;
}

/**
 * Расписание сущности: приоритет `app_settings.sync_interval.<entity>` → env `SYNC_*_CRON` (05 SYNC-021, D-29).
 * Значение читается при каждом пересчёте (кэш SettingsReader — 10 с), поэтому изменение действует без перезапуска.
 */
export class ScheduleResolver {
  constructor(
    private readonly cfg: Pick<SchedulerConfig, 'cron'>,
    private readonly settings: SettingsSource,
    private readonly onInvalid: (r: InvalidSettingReport) => void = () => undefined,
  ) {}

  envCron(entity: SyncEntity): string {
    return this.cfg.cron[ENTITY_QUEUES[entity].cron];
  }

  async overrideMinutes(entity: SyncEntity): Promise<number | undefined> {
    const key = syncIntervalKey(entity);
    let value: unknown;
    try {
      value = await this.settings.get(key);
    } catch {
      return undefined;
    }
    const parsed = parseIntervalMinutes(value);
    if (parsed === 'invalid') {
      this.onInvalid({
        key,
        reason: `ожидается целое число минут ${SYNC_INTERVAL_MIN_MINUTES}…${SYNC_INTERVAL_MAX_MINUTES}`,
      });
      return undefined;
    }
    return parsed;
  }

  async resolve(entity: SyncEntity): Promise<ResolvedSchedule> {
    const minutes = await this.overrideMinutes(entity);
    if (minutes !== undefined) return { expression: minutesToRule(minutes), source: 'app_settings', minutes };
    return { expression: this.envCron(entity), source: 'env' };
  }

  /**
   * Период `onec.changes` (05 SYNC-011): минимальный `sync_interval.<entity>` сущностей плана обмена
   * (все, кроме опрашиваемых отдельно срезов), по умолчанию 5 мин.
   */
  async resolveOnecChanges(planEntities: readonly SyncEntity[]): Promise<ResolvedSchedule> {
    const overrides: number[] = [];
    for (const e of planEntities) {
      const m = await this.overrideMinutes(e);
      if (m !== undefined) overrides.push(m);
    }
    if (overrides.length === 0) {
      return {
        expression: minutesToRule(ONEC_CHANGES_DEFAULT_MINUTES),
        source: 'env',
        minutes: ONEC_CHANGES_DEFAULT_MINUTES,
      };
    }
    const minutes = Math.min(...overrides);
    return { expression: minutesToRule(minutes), source: 'app_settings', minutes };
  }
}
