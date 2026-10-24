import { outboxBackoffMs, outboxDeadReason } from '../../src/sync/scheduler/outbox-backoff.js';
import { schedulerConfigFromEnv } from '../../src/sync/scheduler/scheduler.config.js';
import {
  minutesToRule,
  parseIntervalMinutes,
  ScheduleResolver,
  syncIntervalKey,
} from '../../src/sync/scheduler/schedule-resolver.js';
import { ENTITY_QUEUES, scheduledEntities } from '../../src/sync/scheduler/sync-queues.js';
import { queueSpecs } from '../../src/sync/scheduler/queue-specs.js';
import { SYNC_ENTITY_VALUES } from '../../src/common/enums.js';
import { testConfig } from '../support/test-app.js';

/** Unit: политика повторов outbox, расписания sync.*, параметры очередей (без БД). */
describe('RM-C-007 unit: backoff outbox, расписания, очереди', () => {
  const env = testConfig();
  const cfg = schedulerConfigFromEnv(env);
  const MIN = 60_000;

  it('backoff outbox: 1, 2, 5, 15, 60 мин, далее каждые 60 мин (ядро §22.1)', () => {
    const delays = Array.from({ length: 8 }, (_, i) => outboxBackoffMs(i + 1, cfg.outbox) / MIN);
    expect(delays).toEqual([1, 2, 5, 15, 60, 60, 60, 60]);
  });

  it('dead: OUTBOX_MAX_ATTEMPTS (20) или OUTBOX_MAX_AGE_HOURS (24 ч) из env', () => {
    expect(cfg.outbox.maxAttempts).toBe(20);
    expect(cfg.outbox.maxAgeMs).toBe(24 * 60 * MIN);
    expect(outboxDeadReason(19, 1000, cfg.outbox)).toBeNull();
    expect(outboxDeadReason(20, 1000, cfg.outbox)).toBe('max_attempts');
    expect(outboxDeadReason(3, 24 * 60 * MIN + 1, cfg.outbox)).toBe('max_age');
    const custom = schedulerConfigFromEnv(testConfig({ OUTBOX_MAX_ATTEMPTS: '7', OUTBOX_MAX_AGE_HOURS: '2' }));
    expect(outboxDeadReason(7, 0, custom.outbox)).toBe('max_attempts');
    expect(outboxDeadReason(1, 2 * 60 * MIN + 1, custom.outbox)).toBe('max_age');
  });

  // 12 T-SYNC-020
  it('cron по умолчанию — env SYNC_*_CRON (16 §4.3); 17 сущностей sync_entity распределены по очередям 06 §7.5', () => {
    expect(cfg.cron).toEqual({
      stock: '*/10 * * * *',
      prices: '*/15 * * * *',
      orderStatus: '*/5 * * * *',
      master: '*/30 * * * *',
      images: '30 2 * * *',
      reconcile: '0 4 * * 0',
      countCheck: '30 3 * * *',
    });
    expect(Object.keys(ENTITY_QUEUES).sort()).toEqual([...SYNC_ENTITY_VALUES].sort());
    expect(ENTITY_QUEUES.products.queue).toBe('sync.master');
    expect(ENTITY_QUEUES.stock.queue).toBe('sync.stock');
    expect(cfg.timezone).toBe('Asia/Bishkek');
  });

  it('ONEC_MODE=extension: по расписанию только срезы, статусы и фото (05 SYNC-011); иначе — все сущности', () => {
    expect(scheduledEntities('extension', SYNC_ENTITY_VALUES).sort()).toEqual(
      ['images', 'order_status', 'prices', 'receivables', 'stock'].sort(),
    );
    expect(scheduledEntities('odata_only', SYNC_ENTITY_VALUES)).toHaveLength(17);
  });

  it('app_settings.sync_interval.<entity> (минуты 2…1440) переопределяет env; неверное значение игнорируется', async () => {
    expect(parseIntervalMinutes(5)).toBe(5);
    expect(parseIntervalMinutes('15')).toBe(15);
    expect(parseIntervalMinutes({ minutes: 30 })).toBe(30);
    expect(parseIntervalMinutes(undefined)).toBeUndefined();
    expect(parseIntervalMinutes(1)).toBe('invalid');
    expect(parseIntervalMinutes(1441)).toBe('invalid');
    expect(parseIntervalMinutes(2.5)).toBe('invalid');
    const values: Record<string, unknown> = { [syncIntervalKey('stock')]: 5, [syncIntervalKey('prices')]: 1 };
    const invalid: string[] = [];
    const r = new ScheduleResolver(cfg, { get: (k) => Promise.resolve(values[k]) }, (x) => invalid.push(x.key));
    expect(await r.resolve('stock')).toEqual({ expression: minutesToRule(5), source: 'app_settings', minutes: 5 });
    expect(await r.resolve('prices')).toEqual({ expression: '*/15 * * * *', source: 'env' });
    expect(invalid).toEqual(['sync_interval.prices']);
    expect(await r.resolve('products')).toEqual({ expression: '*/30 * * * *', source: 'env' });
    // onec.changes: минимум интервалов сущностей плана обмена, по умолчанию 5 мин
    expect((await r.resolveOnecChanges(['products', 'customers'])).expression).toBe('FREQ=MINUTELY;INTERVAL=5');
    values[syncIntervalKey('customers')] = 3;
    expect((await r.resolveOnecChanges(['products', 'customers'])).expression).toBe('FREQ=MINUTELY;INTERVAL=3');
  });

  it('очереди: sync.* — stately + dead-letter + retry/backoff; outbox.dispatch — без собственных повторов', () => {
    const specs = new Map(queueSpecs(cfg).map((s) => [s.name, s.options]));
    expect(queueSpecs(cfg)[0]?.name).toBe('sync.dead_letter');
    expect(specs.get('sync.stock')).toMatchObject({
      policy: 'stately',
      deadLetter: 'sync.dead_letter',
      // 05 SYNC-029: ровно 3 попытки (retryLimit=2), повторы через 60 с без экспоненты.
      retryLimit: 2,
      retryDelay: 60,
      retryBackoff: false,
      expireInSeconds: 1800,
    });
    expect(specs.get('outbox.dispatch')).toMatchObject({ policy: 'exclusive', retryLimit: 0 });
    expect(specs.get('onec.changes')).toMatchObject({ policy: 'exclusive' });
    expect(specs.get('orders.onec-confirmed')).toMatchObject({ retryLimit: 1000, retryDelayMax: 3600 });
    for (const q of ['sync.manual', 'sync.master', 'sync.payment_docs', 'sync.return_docs', 'sync.reconcile']) {
      expect(specs.get(q)?.deadLetter).toBe('sync.dead_letter');
    }
  });
});
