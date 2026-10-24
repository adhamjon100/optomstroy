import type { AppConfig } from '../../common/config/app-config.js';

/**
 * Параметры планировщика и worker'а (RM-C-007). Значения по умолчанию — из канонических env (16 §4.3) и
 * констант ТЗ; тесты переопределяют интервалы через `overrides` (без новых переменных окружения:
 * график повторов outbox по 16 §4.3 п. (6) — константа, переменной для него нет).
 */
export interface SyncRetryOptions {
  /**
   * Число повторов job pg-boss после первой попытки. 05 SYNC-029 (владелец протокола pull-синхронизации; в 06 §7.5
   * `retryLimit=5` — расхождение, E_spec_questions FIX-E-01): не более 3 попыток внутри прогона → `retryLimit=2`.
   */
  readonly retryLimit: number;
  /** Задержка повтора, секунды (база экспоненты при `retryBackoff`). */
  readonly retryDelay: number;
  readonly retryBackoff: boolean;
  /** Потолок задержки при backoff, секунды. */
  readonly retryDelayMax: number;
  /** Сколько job может быть `active` до признания зависшей (06 §7.5: `expireInMinutes=30`). */
  readonly expireInSeconds: number;
}

export interface SchedulerConfig {
  /** Часовой пояс расписаний cron (06 §7.5: время Asia/Bishkek). */
  readonly timezone: string;
  readonly onecMode: AppConfig['ONEC_MODE'];
  /** Канонические cron по умолчанию (env `SYNC_*_CRON`, 16 §4.3). */
  readonly cron: {
    readonly stock: string;
    readonly prices: string;
    readonly orderStatus: string;
    readonly master: string;
    readonly images: string;
    readonly reconcile: string;
    readonly countCheck: string;
  };
  readonly sync: SyncRetryOptions;
  /** Прогон в `queued`/`running` без обновления дольше этого порога считается потерянным (процесс упал). */
  readonly staleRunSeconds: number;
  /** Период перечитывания `app_settings.sync_interval.<entity>` (изменение без перезапуска, D-29). */
  readonly scheduleRefreshMs: number;
  /** Интервал опроса очередей pg-boss, секунды (≥ 0.5). */
  readonly pollingIntervalSeconds: number;
  readonly outbox: OutboxConfig;
}

export interface OutboxConfig {
  /** `OUTBOX_MAX_ATTEMPTS` (ядро §22.1; по умолчанию 20). */
  readonly maxAttempts: number;
  /** `OUTBOX_MAX_AGE_HOURS` в миллисекундах (ядро §22.1; по умолчанию 24 ч). */
  readonly maxAgeMs: number;
  /** График повторов после 1-й, 2-й, … неудачной попытки, мс (ядро §22.1, §22.13 п. 7: 1, 2, 5, 15, 60 мин). */
  readonly backoffMs: readonly number[];
  /** Интервал после исчерпания графика, мс (далее каждые 60 мин). */
  readonly backoffTailMs: number;
  /** Аренда строки `sending` (07 §8.2: 10 мин). */
  readonly leaseMs: number;
  /** Пачка захвата (07 §8.2: LIMIT 20). */
  readonly batchSize: number;
  /** Период тикера `outbox.dispatch` (07 §8.2: 10 с; K-24 — единое значение задаёт 05 §8). */
  readonly tickMs: number;
}

const MIN = 60_000;

/** График повторов outbox — константа ТЗ (ядро §22.1, §22.13 п. 7; 07 §6.5, §8.2; 16 §4.3 п. (6)). */
export const OUTBOX_BACKOFF_MINUTES = [1, 2, 5, 15, 60] as const;
export const OUTBOX_BACKOFF_TAIL_MINUTES = 60;

export function schedulerConfigFromEnv(
  env: Pick<
    AppConfig,
    | 'TZ'
    | 'ONEC_MODE'
    | 'SYNC_STOCK_CRON'
    | 'SYNC_PRICES_CRON'
    | 'SYNC_ORDER_STATUS_CRON'
    | 'SYNC_MASTER_CRON'
    | 'SYNC_IMAGES_CRON'
    | 'SYNC_RECONCILE_CRON'
    | 'SYNC_COUNT_CHECK_CRON'
    | 'OUTBOX_MAX_ATTEMPTS'
    | 'OUTBOX_MAX_AGE_HOURS'
  >,
  overrides: SchedulerConfigOverrides = {},
): SchedulerConfig {
  const base: SchedulerConfig = {
    timezone: env.TZ && env.TZ.trim() !== '' ? env.TZ : 'Asia/Bishkek',
    onecMode: env.ONEC_MODE,
    cron: {
      stock: env.SYNC_STOCK_CRON,
      prices: env.SYNC_PRICES_CRON,
      orderStatus: env.SYNC_ORDER_STATUS_CRON,
      master: env.SYNC_MASTER_CRON,
      images: env.SYNC_IMAGES_CRON,
      reconcile: env.SYNC_RECONCILE_CRON,
      countCheck: env.SYNC_COUNT_CHECK_CRON,
    },
    // 05 SYNC-029 (а): 3 попытки, повторы через 1 и 2 мин от начала (пауза 60 с без экспоненты; pg-boss при
    // retryBackoff добавляет случайную составляющую и не даёт ровных пауз); (б) `consecutive_errors` — за прогон.
    sync: { retryLimit: 2, retryDelay: 60, retryBackoff: false, retryDelayMax: 120, expireInSeconds: 30 * 60 },
    staleRunSeconds: 60 * 60,
    scheduleRefreshMs: 60_000,
    pollingIntervalSeconds: 2,
    outbox: {
      maxAttempts: env.OUTBOX_MAX_ATTEMPTS,
      maxAgeMs: env.OUTBOX_MAX_AGE_HOURS * 60 * MIN,
      backoffMs: OUTBOX_BACKOFF_MINUTES.map((m) => m * MIN),
      backoffTailMs: OUTBOX_BACKOFF_TAIL_MINUTES * MIN,
      leaseMs: 10 * MIN,
      batchSize: 20,
      tickMs: 10_000,
    },
  };
  return {
    ...base,
    ...overrides,
    cron: { ...base.cron, ...overrides.cron },
    sync: { ...base.sync, ...overrides.sync },
    outbox: { ...base.outbox, ...overrides.outbox },
  };
}

export type SchedulerConfigOverrides = Partial<Omit<SchedulerConfig, 'cron' | 'sync' | 'outbox'>> & {
  readonly cron?: Partial<SchedulerConfig['cron']>;
  readonly sync?: Partial<SyncRetryOptions>;
  readonly outbox?: Partial<OutboxConfig>;
};
