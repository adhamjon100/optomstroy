import type { PgBoss, ScheduleOptions } from 'pg-boss';
import type pg from 'pg';
import type { Logger } from 'pino';
import { SYNC_ENTITY_VALUES, type SyncEntity } from '../../common/enums.js';
import { QUEUES } from '../../common/jobs/contracts/queues.js';
import { queueSpecs } from './queue-specs.js';
import type { SchedulerConfig } from './scheduler.config.js';
import type { ResolvedSchedule, ScheduleResolver } from './schedule-resolver.js';
import {
  ENTITY_QUEUES,
  EXTENSION_POLLED_ENTITIES,
  IMAGES_GC_QUEUE,
  ONEC_EXCHANGE_NODE,
  scheduledEntities,
  type SyncJobPayload,
} from './sync-queues.js';

/** Периоды служебных задач outbox (06 §7.5, 07 §8.2: каждые 5 мин). */
export const OUTBOX_UNLOCK_CRON = '*/5 * * * *';
export const OUTBOX_RECONCILE_CRON = '*/5 * * * *';
/**
 * Очистка осиротевших файлов фото `images.gc` (EQ-IMG-10): раз в сутки после ночного прогона фото
 * (`SYNC_IMAGES_CRON` по умолчанию 02:30) и сверки `$count` (03:30). Отдельной env-переменной в 16 §4.3 нет.
 */
export const IMAGES_GC_CRON = '15 5 * * *';
const DEFAULT_KEY = 'default';

export interface DesiredSchedule {
  readonly queue: string;
  readonly key: string;
  readonly expression: string;
  readonly data: object;
  readonly singletonKey: string;
  readonly source: ResolvedSchedule['source'] | 'fixed';
  readonly entity?: SyncEntity;
  /**
   * Задание `onec.changes` (режим расширения): сущности плана обмена, инкремент и свежесть которых даёт этот цикл
   * (POSAPI-T1-01) — их `sync_state.schedule_cron`/`max_age_warning_sec` берутся из его расписания (ревью F4).
   */
  readonly planEntities?: readonly SyncEntity[];
}

/**
 * Планировщик синхронизации (D-29, 05 SYNC-021, SYNC-023; 06 §7.5). Расписания хранит pg-boss в PostgreSQL
 * (`schedule: true` только у worker, D-44), поэтому при нескольких экземплярах worker job создаётся один раз.
 * `apply()` вызывается при старте и затем периодически: изменение `app_settings.sync_interval.<entity>`
 * действует без перезапуска (на следующем пересчёте, ≤ `scheduleRefreshMs` + TTL кэша настроек).
 */
export class SyncScheduler {
  private timer: NodeJS.Timeout | undefined;
  private applying: Promise<void> | undefined;
  private readonly applied = new Map<string, string>();

  constructor(
    private readonly boss: PgBoss,
    private readonly db: Pick<pg.Pool, 'query'>,
    private readonly cfg: SchedulerConfig,
    private readonly resolver: ScheduleResolver,
    private readonly log: Logger,
  ) {}

  /** Создание/обновление очередей с параметрами singleton, retry, backoff и dead-letter. */
  async ensureQueues(): Promise<void> {
    for (const spec of queueSpecs(this.cfg)) {
      const existing = await this.boss.getQueue(spec.name);
      if (!existing) {
        await this.boss.createQueue(spec.name, spec.options);
        continue;
      }
      // policy и deadLetter у существующей очереди pg-boss не меняет; остальные параметры — обновляем.
      const { policy, deadLetter, ...mutable } = spec.options;
      if (existing.policy !== policy || (existing.deadLetter ?? undefined) !== deadLetter) {
        this.log.warn(
          { queue: spec.name, policy: existing.policy, wantPolicy: policy, deadLetter: existing.deadLetter },
          'scheduler.queue_policy_mismatch: политика/dead-letter существующей очереди не меняются без пересоздания',
        );
      }
      await this.boss.updateQueue(spec.name, mutable);
    }
  }

  /** Требуемый набор расписаний для текущего `ONEC_MODE` и настроек. */
  async desired(): Promise<DesiredSchedule[]> {
    const out: DesiredSchedule[] = [];
    for (const entity of scheduledEntities(this.cfg.onecMode, SYNC_ENTITY_VALUES)) {
      const r = await this.resolver.resolve(entity);
      const data: SyncJobPayload = { entity, mode: 'incremental', trigger: 'schedule' };
      out.push({
        queue: ENTITY_QUEUES[entity].queue,
        key: entity,
        expression: r.expression,
        data,
        singletonKey: entity,
        source: r.source,
        entity,
      });
    }
    if (this.cfg.onecMode === 'extension') {
      const plan = SYNC_ENTITY_VALUES.filter((e) => !EXTENSION_POLLED_ENTITIES.includes(e));
      const r = await this.resolver.resolveOnecChanges(plan);
      out.push({
        queue: QUEUES.onecChanges,
        key: ONEC_EXCHANGE_NODE,
        expression: r.expression,
        data: { node: ONEC_EXCHANGE_NODE },
        singletonKey: ONEC_EXCHANGE_NODE,
        source: r.source,
        planEntities: plan,
      });
    }
    const fixed = (queue: string, expression: string, data: object = {}): DesiredSchedule => ({
      queue,
      key: DEFAULT_KEY,
      expression,
      data,
      singletonKey: DEFAULT_KEY,
      source: 'fixed',
    });
    out.push(
      fixed(QUEUES.syncReconcile, this.cfg.cron.reconcile, { mode: 'reconcile', trigger: 'schedule' }),
      fixed(QUEUES.syncCountCheck, this.cfg.cron.countCheck),
      fixed(QUEUES.outboxUnlock, OUTBOX_UNLOCK_CRON),
      fixed(QUEUES.outboxReconcileAggregates, OUTBOX_RECONCILE_CRON),
      fixed(IMAGES_GC_QUEUE, IMAGES_GC_CRON),
    );
    return out;
  }

  /** Применение расписаний (upsert в pg-boss) и снятие лишних (смена `ONEC_MODE`). Повторный вызов безопасен. */
  apply(): Promise<void> {
    this.applying ??= this.doApply().finally(() => (this.applying = undefined));
    return this.applying;
  }

  /** Периодический пересчёт расписаний (настройки без перезапуска, D-29). */
  startRefresh(): void {
    this.timer = setInterval(() => {
      this.apply().catch((err: unknown) => this.log.error({ err }, 'scheduler.refresh_failed'));
    }, this.cfg.scheduleRefreshMs);
    this.timer.unref();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
  }

  private async doApply(): Promise<void> {
    const desired = await this.desired();
    const managedQueues = new Set([
      ...Object.values(ENTITY_QUEUES).map((d) => d.queue),
      QUEUES.onecChanges,
      QUEUES.syncReconcile,
      QUEUES.syncCountCheck,
      QUEUES.outboxUnlock,
      QUEUES.outboxReconcileAggregates,
      IMAGES_GC_QUEUE,
    ]);
    const wanted = new Set(desired.map((d) => `${d.queue}|${d.key}`));
    for (const s of await this.boss.getSchedules()) {
      if (managedQueues.has(s.name) && !wanted.has(`${s.name}|${s.key}`)) {
        await this.boss.unschedule(s.name, s.key);
        this.applied.delete(`${s.name}|${s.key}`);
        this.log.info({ queue: s.name, key: s.key }, 'scheduler.unscheduled');
      }
    }
    for (const d of desired) {
      const id = `${d.queue}|${d.key}`;
      const options: ScheduleOptions = { key: d.key, tz: this.cfg.timezone, singletonKey: d.singletonKey };
      if (this.applied.get(id) !== d.expression) {
        await this.boss.schedule(d.queue, d.expression, d.data, options);
        this.log.info(
          { queue: d.queue, key: d.key, expression: d.expression, source: d.source, tz: this.cfg.timezone },
          'scheduler.scheduled',
        );
        this.applied.set(id, d.expression);
      }
      if (d.entity) await this.syncState(d.entity, d.expression);
      if (d.planEntities) await this.planState(d.planEntities, d.expression);
    }
  }

  /** Строка `sync_state` сущности: актуальное расписание и порог «устарело» (DATA-151; 2 пропущенных периода). */
  private async syncState(entity: SyncEntity, expression: string): Promise<void> {
    await this.db.query(
      `INSERT INTO sync_state (entity, schedule_cron, max_age_warning_sec) VALUES ($1, $2, $3)
       ON CONFLICT (entity) DO UPDATE SET schedule_cron = EXCLUDED.schedule_cron,
              max_age_warning_sec = EXCLUDED.max_age_warning_sec, updated_at = now()
        WHERE sync_state.schedule_cron IS DISTINCT FROM EXCLUDED.schedule_cron
           OR sync_state.max_age_warning_sec IS DISTINCT FROM EXCLUDED.max_age_warning_sec`,
      [entity, expression, this.maxAgeWarningSec(expression)],
    );
  }

  /**
   * Сущности плана обмена (режим расширения): их «расписание» — цикл `onec.changes` (05 SYNC-011), порог 1 — два
   * его периода (05 §7.4: «> 2× интервала сущности»). Без этого у них оставались `SYNC_MASTER_CRON` и 3600 с из
   * умолчаний реестра прогонов, и при `sync_interval.*` ≥ 60 мин (период цикла ≥ порога) `overall` перед каждым
   * циклом становился `degraded` (ревью F4). Только существующие строки: строку создаёт первый прогон или загрузка —
   * сущность без строки в «устаревание» не входит (как и раньше).
   */
  private async planState(entities: readonly SyncEntity[], expression: string): Promise<void> {
    await this.db.query(
      `UPDATE sync_state SET schedule_cron = $2, max_age_warning_sec = $3, updated_at = now()
        WHERE entity::text = ANY($1::text[])
          AND (schedule_cron IS DISTINCT FROM $2 OR max_age_warning_sec IS DISTINCT FROM $3)`,
      [entities, expression, this.maxAgeWarningSec(expression)],
    );
  }

  /** Порог устаревания для UI: два периода расписания (оценка по двум ближайшим срабатываниям). */
  maxAgeWarningSec(expression: string): number {
    try {
      const [a, b] = this.boss.previewSchedule(expression, { tz: this.cfg.timezone, count: 2 });
      if (a && b) return Math.max(60, Math.round((2 * (b.getTime() - a.getTime())) / 1000));
    } catch (err) {
      this.log.warn({ err, expression }, 'scheduler.preview_failed');
    }
    return 3600;
  }
}
