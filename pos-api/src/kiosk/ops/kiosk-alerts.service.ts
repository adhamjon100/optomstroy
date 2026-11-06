import { Inject, Injectable, Logger, type OnApplicationBootstrap, Optional } from '@nestjs/common';
import { type SQL, sql } from 'drizzle-orm';
import type { PgBoss } from 'pg-boss';
import { AppVersionPolicy } from '../../common/app-version/app-version.policy.js';
import { compareSemVer, isClientPlatform, parseSemVer } from '../../common/app-version/version-policy.js';
import type { AuditContext } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { APP_CONFIG, type AppConfig } from '../../common/config/app-config.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import { QUEUES } from '../../common/jobs/contracts/queues.js';
import { PgBossService } from '../../common/jobs/pg-boss.service.js';
import { NOTIFICATIONS_PORT, type NotificationsPort } from '../../common/ports/index.js';
import { SettingsReader } from '../../common/settings/settings-reader.js';
import {
  kioskIntegerSetting,
  type KioskWorkingInterval,
  parseKioskWorkingHours,
} from '../../settings/public-settings.map.js';

/** Отметка связи планшета — не чаще раза в 60 с (08 §2.3, §4.25 «Порядок проверок» п. (4); 07 §5.65). */
export const KIOSK_SEEN_THROTTLE_MS = 60_000;
/** Алерт «всплеск кодов»: ≥ 10 кодов `kiosk_order` с одного планшета за 10 мин (11 §6.2 п. (1)). */
export const KIOSK_OTP_BURST_THRESHOLD = 10;
export const KIOSK_OTP_BURST_WINDOW_MS = 10 * 60_000;
/** Алерт «не на связи»: дольше 15 мин в часы работы магазина (11 §6.2 п. (4)). */
export const KIOSK_OFFLINE_ALERT_MS = 15 * 60_000;
/** Напоминание о конце подключения: меньше 30 дней (11 §6.2 п. (5); Р-22 (а)). */
export const KIOSK_SESSION_REMINDER_DAYS = 30;
/** Повтор алерта «вне сети магазина» по одному планшету — не чаще раза в 10 мин. */
export const KIOSK_NETWORK_ALERT_DEDUPE_MS = 10 * 60_000;
/** Расписание проверки алертов (`kiosk.alerts`, Asia/Bishkek): раз в 5 мин — срок доставки алерта SEC-068. */
export const KIOSK_ALERTS_CRON = '*/5 * * * *';
export const KIOSK_ALERTS_TIME_ZONE = 'Asia/Bishkek';

const DAY_MS = 86_400_000;
/** Asia/Bishkek — UTC+6 без перехода на летнее время (как `audit-jobs.bridge.ts`). */
const BISHKEK_OFFSET_MS = 6 * 3_600_000;
/** Предел памяти процесса для подавления повторов (планшетов единицы — предел не достигается). */
const MEMORY_LIMIT = 10_000;

/**
 * Коды алертов планшета магазина (11 §6.2 «Алерты планшета магазина» п. (1)–(6); канал — SEC-068, содержимое —
 * SEC-132): имена событий аудита там, где событие есть (`kiosk.limit_reached`, `kiosk.network_denied`), иначе — коды
 * структурного лога `security.alert` (в словарь аудита 11 §7.2 не входят).
 */
export type KioskAlertCode =
  | 'kiosk.otp_burst'
  | 'kiosk.limit_reached'
  | 'kiosk.network_denied'
  | 'kiosk.offline'
  | 'kiosk.session_expiring'
  | 'kiosk.app_outdated';

/** Сигналы планшета из заголовков запроса (08 §2.3): `null` — заголовка нет или значение не принято — не менять. */
export interface KioskSignal {
  /** `X-App-Version` (SemVer, например `1.4.2+87`) → `store_tablets.last_app_version`. */
  readonly appVersion: string | null;
  /** `X-Kiosk-Lock`: `on` → `true`, `off` → `false` → `store_tablets.lock_task_enabled` (ADR-115 п. 26). */
  readonly lockTaskEnabled: boolean | null;
}

/** Алерт, найденный проверкой (для отчёта задачи и тестов): `raised=false` — повтор того же ключа подавлен. */
export interface KioskAlertFiring {
  readonly alert: KioskAlertCode;
  readonly tabletId: string | null;
  readonly raised: boolean;
}

interface KioskAlert {
  readonly alert: KioskAlertCode;
  readonly tabletId: string | null;
  /** Поля структурного лога — только коды, счётчики, пороги, версии и шаблон маршрута (SEC-132). */
  readonly details: Readonly<Record<string, string | number | null>>;
  readonly title: string;
  /** Текст уведомления администратору: имя планшета (не ПДн, 16 §9), без телефонов и IP. */
  readonly body: string;
  /** Ключ подавления повторов: лог — память процесса, уведомление — `UNIQUE (user_id, dedupe_key)`. */
  readonly dedupeKey: string;
}

interface ActiveTabletRow {
  readonly id: string;
  readonly name: string | null;
  readonly last_seen_at: Date | null;
  /** С какого момента планшет мог выйти на связь: подключение заново или подключение. */
  readonly connected_at: Date;
  readonly last_app_version: string | null;
  readonly platform: string;
  readonly session_expires_at: Date | null;
}

async function rowsOf<T>(ex: DbExecutor, query: SQL): Promise<T[]> {
  const res = await ex.execute(query);
  return res.rows as T[];
}

function asDate(v: Date | string): Date {
  return v instanceof Date ? v : new Date(v);
}

function tabletLabel(name: string | null | undefined): string {
  const n = name?.trim();
  return n ? `«${n}»` : 'без имени';
}

/**
 * Отметка связи планшета магазина (08 §2.3, §3.17 `StoreTablet.lastSeenAt`, §4.25 «Порядок проверок» п. (4);
 * 07 §5.65; ADR-115 п. 21, п. 26): `last_seen_at`, `last_app_version` (`X-App-Version`) и `lock_task_enabled`
 * (`X-Kiosk-Lock`) одним условным UPDATE не чаще раза в 60 с на планшет — счётчик в памяти процесса отсекает лишние
 * обращения к БД, условие `last_seen_at <= now - 60 с` — лишние записи от нескольких процессов. Нет заголовка — поле
 * не меняется. Вызывает `KioskAccessGuard` для каждого прошедшего запроса с токеном планшета (в том числе
 * `GET /settings/public` — отметка связи простаивающего планшета). Ошибка записи запрос не отклоняет.
 *
 * Первый сигнал `X-Kiosk-Lock` после подключения и подключения заново (там `lock_task_enabled = NULL` — 08 §2.3,
 * 07 §5.65) пишется сразу, даже если прежняя сессия планшета отметилась меньше 60 с назад: счётчик в памяти ведётся по
 * сессии (подключение заново выдаёт новую), а условие UPDATE пропускает запись при `lock_task_enabled IS NULL` и
 * заголовке в запросе. Иначе SCR-54 до минуты показывал бы «Закрепление не включено» у закреплённого планшета.
 */
@Injectable()
export class KioskPresenceService {
  private readonly logger = new Logger('kiosk');
  private readonly lastWrite = new Map<string, number>();

  constructor(
    @Inject(DRIZZLE) private readonly db: DbExecutor,
    @Inject(CLOCK) private readonly clock: Clock,
  ) {}

  /**
   * `true` — строка обновлена; `false` — отсечено ограничением частоты или планшет не `active`. `sessionId` — сессия
   * запроса (`sid` токена планшета): ключ счётчика в памяти вместе с планшетом.
   */
  async mark(tabletId: string, signal: KioskSignal, sessionId?: string | null): Promise<boolean> {
    const now = this.clock.now();
    const t = now.getTime();
    const key = `${tabletId}:${sessionId ?? ''}`;
    const prev = this.lastWrite.get(key);
    if (prev !== undefined && t >= prev && t - prev < KIOSK_SEEN_THROTTLE_MS) return false;
    if (this.lastWrite.size >= MEMORY_LIMIT) this.lastWrite.clear();
    this.lastWrite.set(key, t);
    const notAfter = new Date(t - KIOSK_SEEN_THROTTLE_MS);
    try {
      const res = await this.db.execute(sql`
        UPDATE store_tablets
           SET last_seen_at = ${now}::timestamptz,
               last_app_version = COALESCE(${signal.appVersion}::text, last_app_version),
               lock_task_enabled = COALESCE(${signal.lockTaskEnabled}::boolean, lock_task_enabled)
         WHERE id = ${tabletId}::uuid AND status = 'active'
           AND (last_seen_at IS NULL OR last_seen_at <= ${notAfter}::timestamptz
                OR (lock_task_enabled IS NULL AND ${signal.lockTaskEnabled}::boolean IS NOT NULL))`);
      return (res.rowCount ?? 0) > 0;
    } catch (err: unknown) {
      this.logger.error({ event: 'kiosk.last_seen_failed', err }, 'kiosk.last_seen_failed');
      return false;
    }
  }
}

/**
 * Сигналы администратору о планшетах магазина (11 §6.2 «Алерты планшета магазина»; 10 KIOSK-026; 16 §9; P-002
 * §14.6). Канал — существующий механизм SEC-068 кода: структурный лог `security.alert` (как `kiosk.limit_reached`,
 * `authz.denied`) и in-app уведомление `system` всем активным `admin` (`NOTIFICATIONS_PORT.notifyRole`, без цели
 * перехода); содержимое — SEC-132: только код алерта, `id` (в логе) или имя (в уведомлении) планшета, счётчики, пороги,
 * версии, шаблон маршрута — без телефонов, IP и `userId`. Повторы одного ключа подавляются.
 *
 * - сразу (pos-api, `KioskAccessGuard`): запрос с токеном планшета вне `KIOSK_ALLOWED_CIDRS` — аудит
 *   `kiosk.network_denied` (актор — система, адрес — только `audit_logs.ip`; 11 §7.2.1, SEC-143) и алерт;
 * - по расписанию `kiosk.alerts` (pos-worker, раз в 5 мин; при `KIOSK_MODE=false` — ничего): (1) ≥ 10 кодов
 *   `kiosk_order` с планшета за 10 мин; (2) исчерпан лимит кодов планшета за час или за сутки (`kiosk_otp_per_hour`,
 *   `kiosk_otp_per_day`; отказ 429 уже пишет аудит и лог — WP-S3); (4) планшет не на связи дольше 15 мин в часы
 *   `kiosk_working_hours` (Asia/Bishkek; пустая настройка — алерт выключен, Q-341; отсчёт — не раньше начала текущего
 *   интервала часов работы); (5) до конца подключения (абсолютный срок сессии планшета) меньше 30 дней; (6) версия
 *   приложения (`last_app_version`) ниже рекомендуемой для платформы устройства (`recommended_app_version`, иначе env).
 */
@Injectable()
export class KioskAlertsService implements OnApplicationBootstrap {
  private readonly logger = new Logger('kiosk');
  private readonly raisedKeys = new Set<string>();
  private warnedHours = false;

  constructor(
    @Inject(DRIZZLE) private readonly db: DbExecutor,
    @Inject(CLOCK) private readonly clock: Clock,
    @Inject(APP_CONFIG) private readonly config: Pick<AppConfig, 'KIOSK_MODE' | 'WORKERS_ENABLED'>,
    private readonly audit: AuditService,
    private readonly settings: SettingsReader,
    private readonly versions: AppVersionPolicy,
    @Inject(NOTIFICATIONS_PORT) private readonly notifications: NotificationsPort,
    @Optional() private readonly boss?: PgBossService,
  ) {}

  // ------------------------------------------------------------------------------------------- регистрация задачи

  /** pos-worker (`WORKERS_ENABLED=true`): очередь, обработчик и расписание `kiosk.alerts`; в pos-api — ничего. */
  onApplicationBootstrap(): void {
    if (!this.boss || !this.config.WORKERS_ENABLED) return;
    void this.boss
      .start()
      .then(async () => {
        const boss = this.boss?.instance;
        if (boss) await this.register(boss);
      })
      .catch((err: unknown) => this.logger.error({ err }, 'kiosk.jobs.register_failed'));
  }

  async register(boss: PgBoss): Promise<void> {
    const name = QUEUES.kioskAlerts;
    if (!(await boss.getQueue(name))) {
      try {
        await boss.createQueue(name, { policy: 'singleton', retryLimit: 1, expireInSeconds: 240 });
      } catch (e) {
        // Гонка двух процессов — не ошибка.
        if (!(await boss.getQueue(name))) throw e;
      }
    }
    await boss.work(name, { pollingIntervalSeconds: 30, batchSize: 1 }, async () => {
      const found = await this.runChecks();
      return { alerts: found.length, raised: found.filter((f) => f.raised).length };
    });
    await boss.schedule(name, KIOSK_ALERTS_CRON, {}, { tz: KIOSK_ALERTS_TIME_ZONE, singletonKey: name });
    this.logger.log({ queues: [name] }, 'kiosk.jobs.registered');
  }

  // ------------------------------------------------------------------------------------------- сразу: сеть магазина

  /**
   * Запрос с токеном планшета с адреса вне `KIOSK_ALLOWED_CIDRS` (08 §2.4 `KIOSK_NETWORK_DENIED`; 11 SEC-143, §6.2
   * п. (3), §7.2.1): аудит `kiosk.network_denied` (`store_tablets.id`, шаблон маршрута; актор — система, адрес — только
   * `audit_logs.ip` из контекста запроса) и алерт без IP. Сессия не отзывается. Ошибки записи ответ 403 не меняют.
   */
  async networkDenied(input: {
    readonly ctx: AuditContext;
    readonly tablet: { readonly tabletId: string; readonly name: string } | null;
    readonly route: string | null;
  }): Promise<void> {
    const tabletId = input.tablet?.tabletId ?? null;
    await this.audit
      .write(
        { ...input.ctx, actorUserId: null, actorRole: null },
        {
          action: 'kiosk.network_denied',
          entityType: 'store_tablet',
          entityId: tabletId,
          result: 'denied',
          after: { kioskId: tabletId, route: input.route },
        },
      )
      .catch((err: unknown) =>
        this.logger.error({ event: 'audit.write_failed', action: 'kiosk.network_denied', err }, 'audit failed'),
      );
    const bucket = Math.floor(this.clock.now().getTime() / KIOSK_NETWORK_ALERT_DEDUPE_MS);
    await this.raise({
      alert: 'kiosk.network_denied',
      tabletId,
      details: { route: input.route },
      title: 'Планшет магазина вне сети магазина',
      body:
        `Планшет ${tabletLabel(input.tablet?.name)}: запрос пришёл не из сети магазина и отклонён. ` +
        'Если планшет вынесли из зала, отключите его в разделе «Планшеты магазина».',
      dedupeKey: `kiosk.network_denied:${tabletId ?? 'unknown'}:${bucket}`,
    });
  }

  // ------------------------------------------------------------------------------------------- по расписанию

  /** Проверки задачи `kiosk.alerts`; каждая — отдельно (сбой одной не останавливает остальные). */
  async runChecks(): Promise<readonly KioskAlertFiring[]> {
    if (!this.config.KIOSK_MODE) return [];
    const now = this.clock.now();
    const tablets = await this.activeTablets(now);
    const byId = new Map(tablets.map((t) => [t.id, t]));
    const checks: readonly (readonly [string, () => Promise<KioskAlert[]>])[] = [
      ['otp_burst', () => this.otpBurst(now, byId)],
      ['limit_reached', () => this.limitReached(now, byId)],
      ['offline', () => this.offline(now, tablets)],
      ['session_expiring', () => Promise.resolve(this.sessionExpiring(now, tablets))],
      ['app_outdated', () => this.appOutdated(tablets)],
    ];
    const out: KioskAlertFiring[] = [];
    for (const [check, run] of checks) {
      try {
        for (const a of await run()) out.push({ alert: a.alert, tabletId: a.tabletId, raised: await this.raise(a) });
      } catch (err: unknown) {
        this.logger.error({ event: 'kiosk.alerts.check_failed', check, err }, 'kiosk.alerts.check_failed');
      }
    }
    return out;
  }

  /** Действующие планшеты: имя, отметка связи, версия, платформа устройства, абсолютный срок действующей сессии. */
  private activeTablets(now: Date): Promise<ActiveTabletRow[]> {
    return rowsOf<ActiveTabletRow>(
      this.db,
      sql`SELECT st.id, p.full_name AS name, st.last_seen_at, COALESCE(st.reconnected_at, st.enrolled_at) AS connected_at,
                 st.last_app_version, d.platform::text AS platform,
                 (SELECT max(s.expires_at) FROM sessions s
                   WHERE s.user_id = st.user_id AND s.revoked_at IS NULL
                     AND s.expires_at > ${now}::timestamptz) AS session_expires_at
            FROM store_tablets st
            JOIN devices d ON d.id = st.device_id
            LEFT JOIN user_profiles p ON p.user_id = st.user_id
           WHERE st.status = 'active'
           ORDER BY st.id`,
    );
  }

  /** (1) ≥ 10 кодов с одного планшета за 10 мин (индекс `otp_challenges_kiosk_created_idx`); коды выдаются дальше. */
  private async otpBurst(now: Date, byId: ReadonlyMap<string, ActiveTabletRow>): Promise<KioskAlert[]> {
    const from = new Date(now.getTime() - KIOSK_OTP_BURST_WINDOW_MS);
    const found = await rowsOf<{ id: string; n: number }>(
      this.db,
      sql`SELECT kiosk_tablet_id AS id, count(*)::int AS n FROM otp_challenges
           WHERE purpose = 'kiosk_order' AND kiosk_tablet_id IS NOT NULL
             AND created_at > ${from}::timestamptz AND created_at <= ${now}::timestamptz
           GROUP BY kiosk_tablet_id HAVING count(*) >= ${KIOSK_OTP_BURST_THRESHOLD}`,
    );
    const bucket = Math.floor(now.getTime() / KIOSK_OTP_BURST_WINDOW_MS);
    return found.map((r) => ({
      alert: 'kiosk.otp_burst' as const,
      tabletId: r.id,
      details: { count: r.n, threshold: KIOSK_OTP_BURST_THRESHOLD, windowMinutes: KIOSK_OTP_BURST_WINDOW_MS / 60_000 },
      title: 'Планшет магазина: много запросов кода',
      body:
        `Планшет ${tabletLabel(byId.get(r.id)?.name)}: ${r.n} запросов кода за 10 мин ` +
        `(порог ${KIOSK_OTP_BURST_THRESHOLD}). Проверьте планшет в разделе «Планшеты магазина».`,
      dedupeKey: `kiosk.otp_burst:${r.id}:${bucket}`,
    }));
  }

  /** (2) Исчерпан лимит кодов планшета за час или за сутки (счётчики RL-OTP-KIOSK — `rate_limit_counters`). */
  private async limitReached(now: Date, byId: ReadonlyMap<string, ActiveTabletRow>): Promise<KioskAlert[]> {
    const perHour = kioskIntegerSetting('kiosk_otp_per_hour', await this.settings.get('kiosk_otp_per_hour'));
    const perDay = kioskIntegerSetting('kiosk_otp_per_day', await this.settings.get('kiosk_otp_per_day'));
    const found = await rowsOf<{ id: string; scope: string; n: number; window_start: Date | string }>(
      this.db,
      sql`SELECT c.subject AS id, c.scope, c.count AS n, c.window_start FROM rate_limit_counters c
           WHERE ((c.scope = 'otp_kiosk_tablet_1h' AND c.count >= ${perHour})
                  OR (c.scope = 'otp_kiosk_tablet_24h' AND c.count >= ${perDay}))
             AND c.window_start <= ${now}::timestamptz AND c.window_end > ${now}::timestamptz
           ORDER BY c.subject, c.scope`,
    );
    return found
      .filter((r) => byId.has(r.id))
      .map((r) => {
        const daily = r.scope === 'otp_kiosk_tablet_24h';
        const limit = daily ? perDay : perHour;
        return {
          alert: 'kiosk.limit_reached' as const,
          tabletId: r.id,
          details: { scope: r.scope, limit },
          title: 'Планшет магазина: лимит кодов исчерпан',
          body:
            `Планшет ${tabletLabel(byId.get(r.id)?.name)}: исчерпан лимит кодов за ${daily ? 'сутки' : 'час'} ` +
            `(${limit}). Коды с планшета не отправляются до конца окна.`,
          dedupeKey: `kiosk.limit_reached:${r.id}:${r.scope}:${asDate(r.window_start).toISOString()}`,
        };
      });
  }

  /** (4) Не на связи дольше 15 мин в часы работы магазина; пустая или неверная `kiosk_working_hours` — выключено. */
  private async offline(now: Date, tablets: readonly ActiveTabletRow[]): Promise<KioskAlert[]> {
    const raw = await this.settings.get('kiosk_working_hours');
    const hours = typeof raw === 'string' ? parseKioskWorkingHours(raw) : raw === undefined || raw === null ? [] : null;
    if (hours === null) {
      if (!this.warnedHours) {
        this.warnedHours = true;
        this.logger.warn({ key: 'kiosk_working_hours' }, 'invalid app_settings value, offline alert off');
      }
      return [];
    }
    const start = workingIntervalStart(hours, now);
    if (start === null) return [];
    const out: KioskAlert[] = [];
    for (const t of tablets) {
      const since = asDate(t.last_seen_at ?? t.connected_at);
      const from = Math.max(since.getTime(), start.getTime());
      const offlineMs = now.getTime() - from;
      if (offlineMs < KIOSK_OFFLINE_ALERT_MS) continue;
      const minutes = Math.floor(offlineMs / 60_000);
      out.push({
        alert: 'kiosk.offline',
        tabletId: t.id,
        details: { minutes, thresholdMinutes: KIOSK_OFFLINE_ALERT_MS / 60_000 },
        title: 'Планшет магазина не на связи',
        body: `Планшет ${tabletLabel(t.name)} не на связи ${minutes} мин в часы работы магазина.`,
        dedupeKey: `kiosk.offline:${t.id}:${since.toISOString()}:${bishkekDate(now)}`,
      });
    }
    return out;
  }

  /** (5) До конца подключения (абсолютный срок сессии планшета, 180 дней) меньше 30 дней — один раз на подключение. */
  private sessionExpiring(now: Date, tablets: readonly ActiveTabletRow[]): KioskAlert[] {
    const out: KioskAlert[] = [];
    for (const t of tablets) {
      if (t.session_expires_at === null) continue;
      const end = asDate(t.session_expires_at);
      const left = end.getTime() - now.getTime();
      if (left <= 0 || left >= KIOSK_SESSION_REMINDER_DAYS * DAY_MS) continue;
      const daysLeft = Math.ceil(left / DAY_MS);
      out.push({
        alert: 'kiosk.session_expiring',
        tabletId: t.id,
        details: { daysLeft, thresholdDays: KIOSK_SESSION_REMINDER_DAYS },
        title: 'Подключение планшета скоро закончится',
        body: `Планшет ${tabletLabel(t.name)}: до конца подключения ${daysLeft} дн. Подключите планшет заново.`,
        dedupeKey: `kiosk.session_expiring:${t.id}:${end.toISOString()}`,
      });
    }
    return out;
  }

  /** (6) Версия приложения планшета ниже рекомендуемой для платформы его устройства (08 §2.11). */
  private async appOutdated(tablets: readonly ActiveTabletRow[]): Promise<KioskAlert[]> {
    const recommended = (await this.versions.refresh()).recommended;
    const out: KioskAlert[] = [];
    for (const t of tablets) {
      if (t.last_app_version === null || !isClientPlatform(t.platform)) continue;
      const target = recommended[t.platform];
      const have = parseSemVer(t.last_app_version);
      const want = target === undefined ? null : parseSemVer(target);
      if (target === undefined || have === null || want === null || compareSemVer(have, want) >= 0) continue;
      out.push({
        alert: 'kiosk.app_outdated',
        tabletId: t.id,
        details: { version: t.last_app_version, recommended: target, platform: t.platform },
        title: 'Планшет магазина: старая версия приложения',
        body:
          `Планшет ${tabletLabel(t.name)}: версия приложения ${t.last_app_version} ниже рекомендуемой ${target}. ` +
          'Обновите приложение на планшете.',
        dedupeKey: `kiosk.app_outdated:${t.id}:${t.last_app_version}:${target}`,
      });
    }
    return out;
  }

  // ------------------------------------------------------------------------------------------- канал алерта

  /** Лог `security.alert` и уведомление администраторам; повтор ключа — `false` (лог и уведомление не повторяются). */
  private async raise(a: KioskAlert): Promise<boolean> {
    if (this.raisedKeys.has(a.dedupeKey)) return false;
    if (this.raisedKeys.size >= MEMORY_LIMIT) this.raisedKeys.clear();
    this.raisedKeys.add(a.dedupeKey);
    this.logger.warn({ event: 'security.alert', alert: a.alert, kioskId: a.tabletId, ...a.details }, 'security.alert');
    try {
      await this.notifications.notifyRole(null, 'admin', {
        kind: 'system',
        severity: 'warning',
        title: a.title,
        body: a.body,
        payload: { target: null, alert: a.alert, kioskId: a.tabletId },
        dedupeKey: a.dedupeKey,
      });
    } catch (err: unknown) {
      this.logger.error({ event: 'kiosk.alert_notify_failed', alert: a.alert, err }, 'kiosk.alert_notify_failed');
    }
    return true;
  }
}

/** Дата Asia/Bishkek `YYYY-MM-DD`. */
function bishkekDate(now: Date): string {
  return new Date(now.getTime() + BISHKEK_OFFSET_MS).toISOString().slice(0, 10);
}

/**
 * Начало текущего интервала часов работы магазина (Asia/Bishkek; `kiosk_working_hours`, 07 §5.59) или `null`, если
 * сейчас магазин закрыт. Интервал — `[ЧЧ:ММ начала, ЧЧ:ММ конца)` в один из дней интервала.
 */
export function workingIntervalStart(hours: readonly KioskWorkingInterval[], now: Date): Date | null {
  const local = new Date(now.getTime() + BISHKEK_OFFSET_MS);
  const weekday = (local.getUTCDay() + 6) % 7; // понедельник — 0 (KIOSK_WEEKDAYS)
  const minutes = local.getUTCHours() * 60 + local.getUTCMinutes();
  const dayStartUtc = Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate()) - BISHKEK_OFFSET_MS;
  let best: number | null = null;
  for (const h of hours) {
    if (!h.days.includes(weekday) || minutes < h.fromMinutes || minutes >= h.toMinutes) continue;
    const start = dayStartUtc + h.fromMinutes * 60_000;
    if (best === null || start < best) best = start;
  }
  return best === null ? null : new Date(best);
}
