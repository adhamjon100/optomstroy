import { Decimal } from 'decimal.js';
import { sql } from 'drizzle-orm';
import type pg from 'pg';
import { type Clock, systemClock } from '../../common/auth/clock.js';
import { PG_BOSS_SCHEMA } from '../../common/jobs/pg-boss.service.js';
import type { PosDatabase } from '../../db/database.js';
import type { SmsGateway } from '../../integrations/sms/sms-gateway.js';
import { SMS_METRICS, type SmsTelemetry } from '../../integrations/sms/sms-telemetry.js';
import { SMS_QUEUES } from './sms-queues.js';

/**
 * Снимок баланса SMSPro (09 §6.6, SMS-018): для SCR-46 (блок «SMS», «баланс и время опроса») и алертов.
 * Суммы — десятичные строки как у вендора (`account`, `smsprice`); арифметика — только сравнение с порогом.
 */
export interface SmsBalanceSnapshot {
  readonly checkedAt: string;
  readonly provider: 'smspro' | 'fake';
  /** `status` `/api/info`: 0 — корректно, 1 — формат, 2 — авторизация, 3 — IP; `null` — вызов не удался. */
  readonly providerStatus: number | null;
  /** 0 — аккаунт активен, 1 — не активен/заблокирован. */
  readonly state: 0 | 1 | null;
  readonly account: string | null;
  readonly smsprice: string | null;
  readonly thresholdSom: number;
  readonly belowThreshold: boolean;
  readonly error?: string;
}

export interface SmsBalanceMonitorDeps {
  readonly gateway: Pick<SmsGateway, 'getAccountInfo' | 'provider'>;
  readonly telemetry: SmsTelemetry;
  /** `SMSPRO_BALANCE_ALERT_SOM` (по умолчанию 300 сом ≈ 150 OTP). */
  readonly thresholdSom: number;
  /** БД для in-app оповещения администраторов (`notifications`); без неё — только алерт в лог. */
  readonly db?: PosDatabase;
  readonly clock?: Clock;
}

/** Сутки по Бишкеку (GMT+6) — ключ дедупликации оповещений: не чаще одного в сутки на вид. */
function bishkekDate(d: Date): string {
  return new Date(d.getTime() + 6 * 3600_000).toISOString().slice(0, 10);
}

/**
 * Контроль баланса `/api/info` (09 §6.6, SMS-018, AC-AUTH-031; RM-D-002 п. 3): задание `sms.balance_poll` каждые
 * `SMSPRO_BALANCE_POLL_MINUTES`. Метрика `sms_balance_som`; алерты: `account < SMSPRO_BALANCE_ALERT_SOM`,
 * `state=1`, `status ∈ {2,3}`, недоступность `/info`. Низкий баланс и проблемы аккаунта дополнительно приходят
 * администраторам in-app уведомлением (`notifications.kind = system`, `dedupe_key` на сутки).
 */
export class SmsBalanceMonitor {
  private readonly clock: Clock;
  private last: SmsBalanceSnapshot | undefined;

  constructor(private readonly d: SmsBalanceMonitorDeps) {
    this.clock = d.clock ?? systemClock;
  }

  /** Последний снимок этого процесса. */
  get lastSnapshot(): SmsBalanceSnapshot | undefined {
    return this.last;
  }

  async poll(): Promise<SmsBalanceSnapshot> {
    const { telemetry, thresholdSom } = this.d;
    const now = this.clock.now();
    const base = { checkedAt: now.toISOString(), provider: this.d.gateway.provider, thresholdSom };
    let snapshot: SmsBalanceSnapshot;
    try {
      const info = await this.d.gateway.getAccountInfo();
      const ok = info.status === 0;
      const below = ok && new Decimal(info.account).lessThan(thresholdSom);
      snapshot = {
        ...base,
        providerStatus: info.status,
        state: info.state,
        account: ok ? info.account : null,
        smsprice: ok ? info.smsprice : null,
        belowThreshold: below,
      };
      if (ok) telemetry.metrics.set(SMS_METRICS.balanceSom, new Decimal(info.account).toNumber()); // money-double: allow — gauge метрики телеметрии; баланс в API/БД — строка NUMERIC
      if (info.status === 2 || info.status === 3) {
        telemetry.alerts.raise({
          kind: info.status === 2 ? 'smspro_auth_failed' : 'smspro_ip_not_allowed',
          severity: 'critical',
          message: info.status === 2 ? 'Неверный логин/пароль SMSPro (/api/info)' : 'IP сервера не в whitelist SMSPro',
          details: { providerStatus: info.status },
        });
        await this.notifyAdmins('account', 'error', 'SMS: проблема доступа к SMSPro', ACCOUNT_BODY, now, {
          providerStatus: info.status,
        });
      } else if (ok && info.state === 1) {
        telemetry.alerts.raise({
          kind: 'sms_account_inactive',
          severity: 'critical',
          message: 'Аккаунт SMSPro не активен или заблокирован (state=1)',
          details: { state: 1 },
        });
        await this.notifyAdmins('account', 'error', 'SMS: аккаунт SMSPro не активен', ACCOUNT_BODY, now, {
          state: 1,
        });
      }
      if (below) {
        telemetry.alerts.raise({
          kind: 'sms_balance_low',
          severity: 'warning',
          message: `Пополните баланс SMSPro: ${info.account} сом < порога ${thresholdSom} сом`,
          details: { account: info.account, thresholdSom },
        });
        await this.notifyAdmins(
          'balance_low',
          'warning',
          'Низкий баланс SMS',
          `Баланс SMSPro: ${info.account} сом (порог ${thresholdSom} сом). Пополните баланс — иначе коды входа по SMS перестанут отправляться.`,
          now,
          { account: info.account, thresholdSom, checkedAt: base.checkedAt },
        );
      }
    } catch (e) {
      snapshot = {
        ...base,
        providerStatus: null,
        state: null,
        account: null,
        smsprice: null,
        belowThreshold: false,
        error: e instanceof Error ? e.message : 'unknown',
      };
      telemetry.alerts.raise({
        kind: 'sms_balance_unreachable',
        severity: 'warning',
        message: 'SMSPro /api/info недоступен',
        details: { error: snapshot.error ?? null },
      });
    }
    telemetry.logger.log({
      event: 'sms.balance',
      providerStatus: snapshot.providerStatus,
      state: snapshot.state,
      account: snapshot.account,
      belowThreshold: snapshot.belowThreshold,
      thresholdSom,
    });
    this.last = snapshot;
    return snapshot;
  }

  /** In-app оповещение всем активным администраторам (роль `admin`); повтор в те же сутки — не создаётся. */
  private async notifyAdmins(
    kind: 'balance_low' | 'account',
    severity: 'warning' | 'error',
    title: string,
    body: string,
    now: Date,
    payload: Record<string, unknown>,
  ): Promise<number> {
    if (!this.d.db) return 0;
    const dedupeKey = `sms.${kind}:${bishkekDate(now)}`;
    const res = await this.d.db.execute(sql`
      INSERT INTO notifications (user_id, kind, severity, title_ru, body_ru, payload, dedupe_key)
      SELECT DISTINCT u.id, 'system'::notification_kind, ${severity}, ${title}, ${body},
             ${JSON.stringify({ source: 'sms', alert: kind, ...payload })}::jsonb, ${dedupeKey}
      FROM users u
      JOIN user_roles ur ON ur.user_id = u.id AND ur.revoked_at IS NULL
      JOIN roles r ON r.id = ur.role_id
      WHERE r.code = 'admin' AND u.status = 'active'
      ON CONFLICT (user_id, dedupe_key) DO NOTHING`);
    return res.rowCount ?? 0;
  }
}

const ACCOUNT_BODY =
  'Отправка SMS с кодами входа невозможна. Проверьте учётные данные, IP-whitelist и состояние аккаунта SMSPro (runbook «SMSPro недоступен»).';

/**
 * Последний снимок баланса из результата завершённого задания `sms.balance_poll` (pg-boss хранит `output`
 * завершённых заданий `deleteAfterSeconds`). Отдельного хранилища снимка в 07 нет — вопрос SMS-Q-04.
 */
export async function latestBalanceSnapshot(pool: Pick<pg.Pool, 'query'>): Promise<SmsBalanceSnapshot | undefined> {
  const res = await pool.query<{ output: SmsBalanceSnapshot | null }>(
    `SELECT output FROM ${PG_BOSS_SCHEMA}.job WHERE name = $1 AND state = 'completed' AND output IS NOT NULL
     ORDER BY completed_on DESC LIMIT 1`,
    [SMS_QUEUES.balancePoll],
  );
  const out = res.rows[0]?.output;
  return out && typeof out === 'object' && 'checkedAt' in out ? out : undefined;
}
