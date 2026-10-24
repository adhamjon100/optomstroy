import { dirname, join } from 'node:path';
import { Inject, Injectable, Logger, type OnApplicationBootstrap, Optional } from '@nestjs/common';
import type { PgBoss } from 'pg-boss';
import { sql } from 'drizzle-orm';
import { AUDIT_ANCHOR_TIME_ZONE, AuditAnchorService } from '../../common/audit/audit-anchor.service.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import { QUEUES } from '../../common/jobs/contracts/queues.js';
import { PgBossService } from '../../common/jobs/pg-boss.service.js';

/** Расписания (06 §7.5; 11 SEC-081): якорь — ежедневно 03:30, проверка — еженедельно в ночь на воскресенье 03:45. */
export const AUDIT_ANCHOR_CRON = '30 3 * * *';
export const AUDIT_VERIFY_CRON = '45 3 * * 0';
/** Окно проверки цепочки `audit.verify` (06 §7.5: «проверка цепочки за 7 суток»). */
export const AUDIT_VERIFY_DAYS = 7;

const DAY_MS = 86_400_000;
const BISHKEK_OFFSET_MS = 6 * 3_600_000;

/** Прошедшие сутки Asia/Bishkek (`YYYY-MM-DD`) относительно `now` — якорь не зависит от времени запуска (07 §9.3). */
export function previousBishkekDate(now: Date): string {
  return new Date(now.getTime() + BISHKEK_OFFSET_MS - DAY_MS).toISOString().slice(0, 10);
}

/** Каталог файла якоря (07 §9.3: `MEDIA_DIR/../audit-anchors/YYYY-MM-DD.txt`, попадает в бэкап и внешнее хранилище). */
export function auditAnchorExportDir(mediaDir: string): string {
  return join(dirname(mediaDir), 'audit-anchors');
}

export interface AuditJobsLog {
  log(obj: object, msg?: string): void;
  error(obj: object, msg?: string): void;
}

/**
 * Задачи `audit.anchor` и `audit.verify` (06 §7.5; 07 §9.3; 11 SEC-080, SEC-081; 13 RM-G-006 критерий 2; ревью
 * G-security-1): при `WORKERS_ENABLED=true` (pos-worker) регистрирует в pg-boss обработчики и расписания —
 * ежедневный якорь хэш-цепочки за прошедшие сутки (`audit_anchors` + файл якоря вне таблицы, лог
 * `audit.anchor.written`) и еженедельную проверку цепочки за 7 суток со сверкой якорей (`verify_result`, лог
 * `audit.chain.verified` / `audit.chain.broken` — события структурного лога, не `audit_logs`, 11 §7.2). Без pg-boss
 * (тесты `jobs: false`) — ничего не делает; операции доступны вызовом `anchor()` / `verify()`.
 */
@Injectable()
export class AuditJobsBridge implements OnApplicationBootstrap {
  private readonly logger: AuditJobsLog = new Logger('audit.jobs');
  /** Источник времени (подмена — тесты). */
  now: () => Date = () => new Date();

  constructor(
    @Inject(APP_CONFIG) private readonly config: Pick<AppConfig, 'WORKERS_ENABLED' | 'MEDIA_DIR'>,
    private readonly anchors: AuditAnchorService,
    @Inject(DRIZZLE) private readonly db: DbExecutor,
    @Optional() private readonly boss?: PgBossService,
  ) {}

  onApplicationBootstrap(): void {
    if (!this.boss || !this.config.WORKERS_ENABLED) return;
    void this.boss
      .start()
      .then(async () => {
        const boss = this.boss?.instance;
        if (boss) await this.register(boss);
      })
      .catch((err: unknown) => this.logger.error({ err }, 'audit.jobs.register_failed'));
  }

  /** Регистрация очередей, обработчиков и расписаний (часовой пояс — Asia/Bishkek). */
  async register(boss: PgBoss): Promise<void> {
    const options = { policy: 'singleton', retryLimit: 3, retryDelay: 300, expireInSeconds: 3600 } as const;
    for (const name of [QUEUES.auditAnchor, QUEUES.auditVerify]) {
      if (!(await boss.getQueue(name))) {
        try {
          await boss.createQueue(name, options);
        } catch (e) {
          // Гонка двух процессов — не ошибка.
          if (!(await boss.getQueue(name))) throw e;
        }
      }
    }
    const work = { pollingIntervalSeconds: 30, batchSize: 1 }; // money-double: allow — секунды опроса
    await boss.work(QUEUES.auditAnchor, work, async () => this.anchor());
    await boss.work(QUEUES.auditVerify, work, async () => this.verify());
    const tz = { tz: AUDIT_ANCHOR_TIME_ZONE } as const;
    await boss.schedule(QUEUES.auditAnchor, AUDIT_ANCHOR_CRON, {}, { ...tz, singletonKey: QUEUES.auditAnchor });
    await boss.schedule(QUEUES.auditVerify, AUDIT_VERIFY_CRON, {}, { ...tz, singletonKey: QUEUES.auditVerify });
    this.logger.log({ queues: [QUEUES.auditAnchor, QUEUES.auditVerify] }, 'audit.jobs.registered');
  }

  /** `audit.anchor`: якорь прошедших суток Asia/Bishkek с экспортом файла (идемпотентно — повтор не создаёт второй). */
  async anchor(): Promise<{ anchorDate: string; created: boolean; exportPath: string | null } | null> {
    const anchorDate = previousBishkekDate(this.now());
    const a = await this.anchors.writeDailyAnchor(anchorDate, {
      exportDir: auditAnchorExportDir(this.config.MEDIA_DIR),
    });
    if (!a) {
      this.logger.log({ event: 'audit.anchor.skipped', anchorDate }, 'audit.anchor: журнал аудита пуст');
      return null;
    }
    this.logger.log(
      {
        event: 'audit.anchor.written',
        anchorDate,
        lastChainSeq: a.lastChainSeq,
        rows: a.rowsCount,
        created: a.created,
      },
      'audit.anchor.written',
    );
    return { anchorDate, created: a.created, exportPath: a.exportPath ?? null };
  }

  /** `audit.verify`: цепочка за 7 суток и сверка всех якорей (`audit_anchors.verify_result`). */
  async verify(): Promise<{ chainOk: boolean; brokenAtChainSeq: number | null; anchorsBroken: string[] }> {
    const since = new Date(this.now().getTime() - AUDIT_VERIFY_DAYS * DAY_MS);
    const r = await this.db.execute<{ s: string | null }>(
      sql`SELECT min(chain_seq)::text AS s FROM audit_logs WHERE occurred_at >= ${since.toISOString()}::timestamptz`,
    );
    const from = r.rows[0]?.s;
    const chain =
      from === null || from === undefined
        ? { ok: true, brokenAtChainSeq: null }
        : await this.anchors.verifyChain(Number(from));
    const anchors = await this.anchors.verifyAnchors();
    const anchorsBroken = anchors.filter((a) => !a.ok).map((a) => a.anchorDate);
    const ok = chain.ok && anchorsBroken.length === 0;
    const event = ok ? 'audit.chain.verified' : 'audit.chain.broken';
    const fields = { event, brokenAtChainSeq: chain.brokenAtChainSeq, anchorsBroken, anchorsChecked: anchors.length };
    if (ok) this.logger.log(fields, event);
    else this.logger.error(fields, event);
    return { chainOk: chain.ok, brokenAtChainSeq: chain.brokenAtChainSeq, anchorsBroken };
  }
}
