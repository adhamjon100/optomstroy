import type pg from 'pg';
import type { Logger } from 'pino';
import type { SyncEntity } from '../../common/enums.js';
import { isOnecError } from '../../integrations/onec/onec-error.js';
import { ONEC_AUTH_PAUSE_MINUTES, type SyncAlertService } from './sync-alerts.service.js';

type Queryable = Pick<pg.Pool, 'query'>;

/** Узел плана обмена (`sync_node_state.node`, = `ONEC_NODE` цикла `onec.changes`). */
const NODE = 'pos';

/** Итог проверки паузы: до какого момента чтение из 1С не выполняется. */
export interface OnecAuthPauseState {
  readonly until: Date;
  readonly since: Date;
}

/**
 * Пауза чтения из 1С после отказа авторизации или прав (401 `POS_E_UNAUTHORIZED`, 403 `POS_E_FORBIDDEN`; 05 §6.5:
 * «алерт администратору, `consecutive_errors++`, следующий запрос сущности — не раньше чем через 15 мин, без
 * backoff-ретраев»; ТЗ для 1С А.1; разбор расхождений п. 89). Отметка — `sync_node_state.auth_error_at` (миграция
 * 0019): её видят все задания чтения процесса-исполнителя (цикл `onec.changes`, прогоны `sync.*` — статусы заказов,
 * долги, возвраты, фото, срезы), в том числе после перезапуска. Запись в 1С (outbox) паузой не останавливается: там
 * 401/403 переводит элемент в `dead` сразу (SYNC-044).
 */
export class OnecAuthPause {
  private readonly minutes: number;

  constructor(
    private readonly db: Queryable,
    private readonly opts: {
      readonly alerts?: Pick<SyncAlertService, 'onecAuthFailed'>;
      readonly log?: Pick<Logger, 'warn' | 'error'>;
      readonly minutes?: number;
    } = {},
  ) {
    this.minutes = opts.minutes ?? ONEC_AUTH_PAUSE_MINUTES;
  }

  /** Пауза действует → момент её окончания; иначе `null` (ошибка чтения отметки паузу не включает). */
  async active(): Promise<OnecAuthPauseState | null> {
    try {
      const r = await this.db.query<{ since: Date; until: Date }>(
        `SELECT auth_error_at AS since, auth_error_at + make_interval(mins => $2::int) AS until
           FROM sync_node_state
          WHERE node = $1 AND auth_error_at IS NOT NULL AND auth_error_at + make_interval(mins => $2::int) > now()`,
        [NODE, this.minutes],
      );
      const row = r.rows[0];
      return row ? { since: new Date(row.since), until: new Date(row.until) } : null;
    } catch (err) {
      this.opts.log?.warn({ err }, 'sync.auth_pause.read_failed: отметка паузы не прочитана, чтение не приостановлено');
      return null;
    }
  }

  /**
   * Отказ авторизации получен: отметка `auth_error_at = now()` и `last_error_code = ONEC_REJECTED` узла, тревога
   * администратору (не чаще раза в час, SYNC-038). Сбой записи журналируется и не маскирует исходную ошибку.
   */
  async record(e: unknown, ctx: { readonly entity?: SyncEntity | null } = {}): Promise<void> {
    const httpStatus = isOnecError(e) ? e.status : statusFromMessage(e);
    try {
      await this.db.query(
        `INSERT INTO sync_node_state (node, auth_error_at, last_error_code) VALUES ($1, now(), 'ONEC_REJECTED')
         ON CONFLICT (node) DO UPDATE SET auth_error_at = now(), last_error_code = 'ONEC_REJECTED', updated_at = now()`,
        [NODE],
      );
    } catch (err) {
      this.opts.log?.error({ err }, 'sync.auth_pause.record_failed');
    }
    this.opts.log?.error(
      { httpStatus, entity: ctx.entity ?? null, pauseMinutes: this.minutes },
      'sync.auth_pause.started: 1С отклонила авторизацию — чтение приостановлено, без повторов (05 §6.5)',
    );
    await this.opts.alerts
      ?.onecAuthFailed({ httpStatus, entity: ctx.entity ?? null })
      .catch((err: unknown) => this.opts.log?.error({ err }, 'sync.auth_pause.alert_failed'));
  }
}

function statusFromMessage(e: unknown): number | null {
  const m = e instanceof Error ? /\b(40[13]) POS_E_/.exec(e.message) : null;
  return m ? Number(m[1]) : null;
}
