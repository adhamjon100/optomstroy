import { Inject, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import type { DbExecutor } from '../audit/db-executor.js';
// Путь через `../../common/` — правило no-restricted-imports (eslint.config.mjs, MOD-022) по шаблону `../auth/*`
// предназначено для модуля D-06 src/auth и ложно срабатывает на common/auth.
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { DRIZZLE } from '../db/database.module.js';

/**
 * Области лимитов — ровно перечень CHECK `rate_limit_counters_scope_chk` (07 §5.12; миграции 0001 и 0003 — DQ-01) с
 * длиной фиксированного окна. Лимиты (числа) задаёт вызывающий из env/`app_settings` (09 §5.4; 08 §2.6, §2.9).
 */
export const RATE_LIMIT_WINDOWS = {
  otp_phone_15m: 15 * 60,
  otp_phone_24h: 24 * 3600,
  otp_ip_1h: 3600,
  otp_device_24h: 24 * 3600,
  login_ip_1h: 3600,
  step_up_user_1h: 3600,
  webhook_ip_1m: 60,
  // 0003_auth_refinements.sql: RL-OTP-SEND-IP / -DEV, RL-OTP-GLOBAL, RL-OTP-VERIFY (IP), RL-PIN, RL-ADMIN (08 §2.9).
  otp_ip_10m: 10 * 60,
  otp_ip_24h: 24 * 3600,
  otp_device_10m: 10 * 60,
  otp_global_1m: 60,
  otp_verify_ip_10m: 10 * 60,
  pin_user_device_10m: 10 * 60,
  admin_user_1m: 60,
} as const satisfies Record<string, number>;

export type RateLimitScope = keyof typeof RATE_LIMIT_WINDOWS;
export const RATE_LIMIT_SCOPES = Object.keys(RATE_LIMIT_WINDOWS) as readonly RateLimitScope[];

/** Хранение счётчиков после окончания окна (07 §5.12 «Физически после window_end + 1 день»). */
export const RATE_LIMIT_RETENTION_MS = 24 * 3600 * 1000;
const MAX_SUBJECT_LENGTH = 200;

/**
 * Сырой номер КР в subject (07 §5.12): E.164 `+996XXXXXXXXX` в любом месте строки или весь subject — те же 12 цифр
 * без `+`. Прежний шаблон `\+?996\d{9}` без `+` и без границ совпадал с hex-псевдонимом номера (64 hex-символа,
 * ≈ 1.7e-4 номеров при случайном секрете) — `RangeError` → 500 на `POST /auth/otp/request` (known_issues G-KI-16,
 * R1-N-01, F-KI-16). В hex-псевдониме, UUID и IP знака `+` нет, а 12 цифр целиком они не составляют.
 */
const RAW_PHONE_IN_SUBJECT = /\+996\d{9}|^996\d{9}$/;

export interface RateLimitRule {
  readonly scope: RateLimitScope;
  /**
   * Субъект: IP, `device_key`, `user_id`; телефон — **только псевдоним** `OtpHmacService.pseudonym('phone', e164)`
   * (07 §5.12: «Телефон в subject хранится как HMAC»). Сырой номер `+996…` отвергается.
   */
  readonly subject: string;
  /** Максимум событий в окне (≥ 1). */
  readonly limit: number;
}

export interface RateLimitDecision {
  readonly scope: RateLimitScope;
  readonly allowed: boolean;
  /** Значение счётчика после операции (при отказе — текущее). */
  readonly count: number;
  readonly limit: number;
  readonly remaining: number;
  readonly windowStart: Date;
  readonly windowEnd: Date;
  /** Секунд до конца окна (для `Retry-After`, 08 §2.6); 0 — если разрешено. */
  readonly retryAfterSec: number;
}

export interface RateLimitResult {
  readonly allowed: boolean;
  readonly decisions: readonly RateLimitDecision[];
  /** Максимальный `retryAfterSec` среди отказавших правил. */
  readonly retryAfterSec: number;
  /** Первое отказавшее правило (для метрики/аудита `auth.otp.rate_limited`). */
  readonly deniedScope?: RateLimitScope;
}

function windowOf(scope: RateLimitScope, now: Date): { start: Date; end: Date } {
  const lenMs = RATE_LIMIT_WINDOWS[scope] * 1000;
  const start = Math.floor(now.getTime() / lenMs) * lenMs;
  return { start: new Date(start), end: new Date(start + lenMs) };
}

function checkRule(r: RateLimitRule): void {
  if (!Object.hasOwn(RATE_LIMIT_WINDOWS, r.scope))
    throw new RangeError(`rate-limit: неизвестная область ${String(r.scope)}`);
  if (!Number.isInteger(r.limit) || r.limit < 1) throw new RangeError('rate-limit: limit — целое ≥ 1');
  if (typeof r.subject !== 'string' || r.subject.length === 0 || r.subject.length > MAX_SUBJECT_LENGTH) {
    throw new RangeError('rate-limit: subject — непустая строка до 200 символов');
  }
  if (RAW_PHONE_IN_SUBJECT.test(r.subject)) {
    throw new RangeError('rate-limit: телефон в subject — только HMAC-псевдоним (07 §5.12)');
  }
}

/**
 * Счётчики фиксированных окон в PostgreSQL `rate_limit_counters` (без Redis — D-44; 07 §5.12). Атомарность —
 * строчные блокировки PostgreSQL: `consume` либо увеличивает **все** счётчики набора, либо (если хотя бы один
 * упёрся в лимит) не меняет ни одного — отказ не «съедает» попытку (09 §5.4: отправка не состоялась).
 */
@Injectable()
export class RateLimitService {
  constructor(
    @Inject(DRIZZLE) private readonly db: DbExecutor,
    @Inject(CLOCK) private readonly clock: Clock,
  ) {}

  /** Учитывает событие по всем правилам атомарно (своя транзакция или переданная `executor`). */
  async consume(rules: readonly RateLimitRule[], executor?: DbExecutor): Promise<RateLimitResult> {
    if (rules.length === 0) return { allowed: true, decisions: [], retryAfterSec: 0 };
    rules.forEach(checkRule);
    const now = this.clock.now();
    // Детерминированный порядок блокировок — без взаимоблокировок при пересекающихся наборах правил.
    const ordered = [...rules].sort((a, b) =>
      a.scope === b.scope ? a.subject.localeCompare(b.subject) : a.scope.localeCompare(b.scope),
    );
    const run = async (tx: DbExecutor): Promise<RateLimitResult> => {
      const current: { rule: RateLimitRule; start: Date; end: Date; count: number }[] = [];
      for (const rule of ordered) {
        const { start, end } = windowOf(rule.scope, now);
        await tx.execute(sql`
          INSERT INTO rate_limit_counters (scope, subject, window_start, count, window_end)
          VALUES (${rule.scope}, ${rule.subject}, ${start.toISOString()}::timestamptz, 0, ${end.toISOString()}::timestamptz)
          ON CONFLICT (scope, subject, window_start) DO NOTHING`);
        const sel = await tx.execute<{ count: number }>(sql`
          SELECT count FROM rate_limit_counters
           WHERE scope = ${rule.scope} AND subject = ${rule.subject} AND window_start = ${start.toISOString()}::timestamptz
           FOR UPDATE`);
        current.push({ rule, start, end, count: Number(sel.rows[0]?.count ?? 0) });
      }
      const allowed = current.every((c) => c.count + 1 <= c.rule.limit);
      if (allowed) {
        for (const c of current) {
          await tx.execute(sql`
            UPDATE rate_limit_counters SET count = count + 1, updated_at = now()
             WHERE scope = ${c.rule.scope} AND subject = ${c.rule.subject}
               AND window_start = ${c.start.toISOString()}::timestamptz`);
          c.count += 1;
        }
      }
      return this.decide(
        current.map((c) => ({ ...c, allowedRule: allowed || c.count + 1 <= c.rule.limit })),
        allowed,
        now,
      );
    };
    if (executor) return run(executor);
    return this.db.transaction((tx) => run(tx));
  }

  /** Текущее состояние без изменения счётчиков (например, предварительная проверка cooldown/лимита). */
  async peek(rules: readonly RateLimitRule[], executor: DbExecutor = this.db): Promise<RateLimitResult> {
    rules.forEach(checkRule);
    const now = this.clock.now();
    const current: { rule: RateLimitRule; start: Date; end: Date; count: number; allowedRule: boolean }[] = [];
    for (const rule of rules) {
      const { start, end } = windowOf(rule.scope, now);
      const sel = await executor.execute<{ count: number }>(sql`
        SELECT count FROM rate_limit_counters
         WHERE scope = ${rule.scope} AND subject = ${rule.subject} AND window_start = ${start.toISOString()}::timestamptz`);
      const count = Number(sel.rows[0]?.count ?? 0);
      current.push({ rule, start, end, count, allowedRule: count + 1 <= rule.limit });
    }
    return this.decide(
      current,
      current.every((c) => c.allowedRule),
      now,
    );
  }

  /** Сброс счётчика текущего окна (например, `login_ip_1h` после успешного входа — по решению вызывающего). */
  async reset(scope: RateLimitScope, subject: string, executor: DbExecutor = this.db): Promise<void> {
    const { start } = windowOf(scope, this.clock.now());
    await executor.execute(sql`
      DELETE FROM rate_limit_counters
       WHERE scope = ${scope} AND subject = ${subject} AND window_start = ${start.toISOString()}::timestamptz`);
  }

  /** Очистка: строки с `window_end` старше суток (07 §5.12). Возвращает число удалённых строк. */
  async purgeExpired(executor: DbExecutor = this.db): Promise<number> {
    const cutoff = new Date(this.clock.now().getTime() - RATE_LIMIT_RETENTION_MS);
    const res = await executor.execute(sql`
      DELETE FROM rate_limit_counters WHERE window_end < ${cutoff.toISOString()}::timestamptz`);
    return res.rowCount ?? 0;
  }

  private decide(
    rows: readonly { rule: RateLimitRule; start: Date; end: Date; count: number; allowedRule: boolean }[],
    allowed: boolean,
    now: Date,
  ): RateLimitResult {
    const decisions = rows.map((c): RateLimitDecision => {
      const retry = c.allowedRule ? 0 : Math.max(1, Math.ceil((c.end.getTime() - now.getTime()) / 1000));
      return {
        scope: c.rule.scope,
        allowed: c.allowedRule,
        count: c.count,
        limit: c.rule.limit,
        remaining: Math.max(0, c.rule.limit - c.count),
        windowStart: c.start,
        windowEnd: c.end,
        retryAfterSec: retry,
      };
    });
    const denied = decisions.filter((d) => !d.allowed);
    return {
      allowed,
      decisions,
      retryAfterSec: denied.reduce((m, d) => Math.max(m, d.retryAfterSec), 0),
      ...(denied[0] ? { deniedScope: denied[0].scope } : {}),
    };
  }
}
