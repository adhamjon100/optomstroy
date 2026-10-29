import type pg from 'pg';
import type { Logger } from 'pino';
import type { SyncEntity } from '../../common/enums.js';
import { assertNotificationPayload } from '../../common/notifications/notification-target.js';
import type { RunFinishedEvent } from '../scheduler/sync-run.registry.js';

type Queryable = Pick<pg.Pool, 'query'>;

/**
 * Порог алерта «ошибки прогонов» (05 SYNC-038, §7.6.1; 07 DATA-151): `consecutive_errors ≥ 3` по сущности.
 * Переменной окружения в 16 §4.3 и ключа `app_settings` для порога нет — значение ТЗ (EQ-SYNC-03).
 */
export const SYNC_ALERT_CONSECUTIVE_ERRORS = 3;
/** Повторное уведомление по тому же триггеру — не чаще раза в 60 мин до восстановления (SYNC-038). */
export const SYNC_ALERT_REPEAT_MINUTES = 60;

/** Получатели алертов синхронизации (05 §7.6.1): недоступность 1С и `consecutive_errors ≥ 3`. */
export const SYNC_ALERT_ROLES = ['admin', 'owner', 'senior_seller'] as const;
/** Получатель уведомления о расхождении `$count` (05 SYNC-068: «уведомление `sync_error` администратору»). */
export const COUNT_MISMATCH_ROLES = ['admin'] as const;

/**
 * Пауза чтения из 1С после отказа авторизации 401/403 (05 §6.5: «следующий запрос сущности — не раньше чем через
 * 15 мин, без backoff-ретраев»; ТЗ для 1С А.1).
 */
export const ONEC_AUTH_PAUSE_MINUTES = 15;

/** Порог алерта о недоступности 1С по умолчанию (`SYNC_ALERT_UNREACHABLE_MIN`, 16 §4.3; 05 SYNC-038 п. 1). */
export const SYNC_ALERT_UNREACHABLE_MIN_DEFAULT = 10;
/** Узел плана обмена (`sync_node_state.node`, = `ONEC_NODE` цикла `onec.changes`). */
const NODE = 'pos';

export interface SyncAlertOptions {
  readonly threshold?: number;
  readonly repeatMinutes?: number;
  /** `SYNC_ALERT_UNREACHABLE_MIN`: непрерывная недоступность 1С (`sync_node_state.unreachable_since`), минут. */
  readonly unreachableMinutes?: number;
}

export interface CountMismatchAlert {
  readonly entity: SyncEntity;
  readonly runId: string;
  readonly tables: readonly { readonly table: string; readonly sourceTotal: number; readonly localTotal: number }[]; // money-double: allow — число записей ($count), не деньги
}

/**
 * Уведомления `sync_error` (in-app, `notifications`, D-41; SCR-44) и запись уровня `error` в журнал (SYNC-038):
 * (1) `consecutive_errors ≥ порога` по сущности — `admin`, `owner`, `senior_seller`; повтор — не чаще раза в
 * `repeatMinutes` (ключ дедупликации — окно времени); после первого успешного прогона — «синхронизация
 * восстановлена»; (2) расхождение сверки `$count` — `admin`. Тексты без ПДн: только сущность и числа.
 */
export class SyncAlertService {
  private readonly threshold: number;
  private readonly repeatMinutes: number;
  private readonly unreachableMinutes: number;

  constructor(
    private readonly db: Queryable,
    private readonly log: Logger,
    options: SyncAlertOptions = {},
  ) {
    this.threshold = options.threshold ?? SYNC_ALERT_CONSECUTIVE_ERRORS;
    this.repeatMinutes = options.repeatMinutes ?? SYNC_ALERT_REPEAT_MINUTES;
    this.unreachableMinutes = options.unreachableMinutes ?? SYNC_ALERT_UNREACHABLE_MIN_DEFAULT;
  }

  get consecutiveThreshold(): number {
    return this.threshold;
  }

  /** Обработчик `SyncRunRegistry.onFinished`: оценка одной сущности по свежему значению счётчика. */
  async onRunFinished(e: RunFinishedEvent): Promise<void> {
    if (e.consecutiveErrors === undefined) return;
    await this.evaluate(e.entity);
  }

  /** Проверка всех сущностей (после цикла `onec.changes`, где прогоны ведёт трекер конвейера apply). */
  async sweep(): Promise<number> {
    const r = await this.db.query<{ entity: SyncEntity }>(`SELECT entity::text AS entity FROM sync_state`);
    let n = await this.evaluateNode();
    for (const row of r.rows) n += await this.evaluate(row.entity);
    return n;
  }

  /**
   * Триггер 1 SYNC-038 — недоступность 1С: `onec_reachable=false` дольше `SYNC_ALERT_UNREACHABLE_MIN` (признак ведёт
   * цикл `onec.changes`) → уведомление `sync_error` admin/owner/senior_seller; повтор — не чаще раза в
   * `repeatMinutes`, отсчёт окон — от момента начала недоступности (до T+порог+60 мин повтора нет); после
   * восстановления связи — одно уведомление «связь с 1С восстановлена». Возвращает число созданных уведомлений.
   */
  async evaluateNode(): Promise<number> {
    const r = await this.db.query<{ reachable: boolean; since_ms: string | null; down_ms: string | null }>(
      `SELECT onec_reachable AS reachable,
              (extract(epoch FROM unreachable_since) * 1000)::bigint::text AS since_ms,
              (extract(epoch FROM now() - unreachable_since) * 1000)::bigint::text AS down_ms
         FROM sync_node_state WHERE node = $1`,
      [NODE],
    );
    const row = r.rows[0];
    if (!row) return 0;
    if (!row.reachable && row.since_ms !== null && row.down_ms !== null) {
      const downMs = Number(row.down_ms);
      const thresholdMs = this.unreachableMinutes * 60_000;
      if (downMs < thresholdMs) return 0;
      // Та же недоступность уже объявлена менее `repeatMinutes` назад — повтора нет (SYNC-038).
      const recent = await this.db.query(
        `SELECT 1 FROM notifications
          WHERE kind = 'sync_error' AND dedupe_key LIKE 'sync_error:unreachable:%'
            AND created_at >= to_timestamp($1::bigint / 1000.0)
            AND created_at > now() - make_interval(mins => $2::int)
          LIMIT 1`,
        [row.since_ms, this.repeatMinutes],
      );
      if ((recent.rowCount ?? 0) > 0) return 0;
      const windowNo = Math.floor((downMs - thresholdMs) / (this.repeatMinutes * 60_000));
      const minutes = Math.floor(downMs / 60_000);
      const created = await this.notify(SYNC_ALERT_ROLES, {
        severity: 'error',
        title: 'Нет связи с 1С',
        body: `1С недоступна ${minutes} мин. Каталог, цены и остатки не обновляются. Откройте «Синхронизация».`,
        payload: { trigger: 'onec_unreachable', unreachableMinutes: minutes },
        dedupeKey: `sync_error:unreachable:${row.since_ms}:${windowNo}`,
      });
      if (created > 0) {
        this.log.error(
          { unreachableMinutes: minutes, threshold: this.unreachableMinutes, recipients: created },
          'sync.alert.onec_unreachable: 1С недоступна дольше порога (SYNC-038 п. 1)',
        );
      }
      return created;
    }
    if (!row.reachable) return 0;
    const last = await this.db.query<{ created_at: Date | null }>(
      `SELECT max(created_at) AS created_at FROM notifications
        WHERE kind = 'sync_error' AND dedupe_key LIKE 'sync_error:unreachable:%'`,
    );
    const alertAt = last.rows[0]?.created_at;
    if (!alertAt) return 0;
    const done = await this.db.query(
      `SELECT 1 FROM notifications
        WHERE kind = 'sync_error' AND dedupe_key LIKE 'sync_error:onec_recovered:%' AND created_at >= $1 LIMIT 1`,
      [alertAt],
    );
    if ((done.rowCount ?? 0) > 0) return 0;
    const created = await this.notify(SYNC_ALERT_ROLES, {
      severity: 'info',
      title: 'Связь с 1С восстановлена',
      body: 'Обмен с 1С снова выполняется.',
      payload: { trigger: 'onec_recovered' },
      dedupeKey: `sync_error:onec_recovered:${alertAt.getTime()}`,
    });
    if (created > 0) this.log.info('sync.alert.onec_recovered: связь с 1С восстановлена');
    return created;
  }

  /** Возвращает число созданных уведомлений. */
  async evaluate(entity: SyncEntity): Promise<number> {
    const st = await this.db.query<{ consecutive_errors: number; last_error_at: Date | null }>(
      `SELECT consecutive_errors, last_error_at FROM sync_state WHERE entity = $1`,
      [entity],
    );
    const row = st.rows[0];
    if (!row) return 0;
    const errors = Number(row.consecutive_errors);
    if (errors >= this.threshold) {
      const bucket = Math.floor(Date.now() / (this.repeatMinutes * 60_000));
      const created = await this.notify(SYNC_ALERT_ROLES, {
        severity: 'error',
        title: 'Ошибка синхронизации с 1С',
        body: `Синхронизация «${entity}» завершилась ошибкой ${errors} раз подряд. Откройте «Синхронизация».`,
        payload: { entity, consecutiveErrors: errors, trigger: 'consecutive_errors' },
        dedupeKey: `sync_error:consecutive:${entity}:${bucket}`,
      });
      if (created > 0) {
        this.log.error(
          { entity, consecutiveErrors: errors, threshold: this.threshold, recipients: created },
          'sync.alert.consecutive_errors: ошибки прогонов подряд достигли порога (SYNC-038)',
        );
      }
      return created;
    }
    if (errors === 0) return this.recovered(entity);
    return 0;
  }

  /** «Синхронизация восстановлена» — только если был алерт и после него восстановления ещё не объявляли. */
  private async recovered(entity: SyncEntity): Promise<number> {
    const last = await this.db.query<{ created_at: Date | null }>(
      `SELECT max(created_at) AS created_at FROM notifications
        WHERE kind = 'sync_error' AND dedupe_key LIKE $1`,
      [`sync_error:consecutive:${entity}:%`],
    );
    const alertAt = last.rows[0]?.created_at;
    if (!alertAt) return 0;
    const done = await this.db.query(
      `SELECT 1 FROM notifications WHERE kind = 'sync_error' AND dedupe_key LIKE $1 AND created_at >= $2 LIMIT 1`,
      [`sync_error:recovered:${entity}:%`, alertAt],
    );
    if ((done.rowCount ?? 0) > 0) return 0;
    const created = await this.notify(SYNC_ALERT_ROLES, {
      severity: 'info',
      title: 'Синхронизация восстановлена',
      body: `Синхронизация «${entity}» снова выполняется успешно.`,
      payload: { entity, consecutiveErrors: 0, trigger: 'recovered' },
      dedupeKey: `sync_error:recovered:${entity}:${alertAt.getTime()}`,
    });
    if (created > 0) this.log.info({ entity }, 'sync.alert.recovered: синхронизация сущности восстановлена');
    return created;
  }

  /** Расхождение сверки `$count` (05 SYNC-068): уведомление администраторам, по одному на прогон сверки. */
  async countMismatch(a: CountMismatchAlert): Promise<number> {
    const diff = a.tables.map((t) => `${t.table}: 1С ${t.sourceTotal}, POS ${t.localTotal}`).join('; ');
    const created = await this.notify(COUNT_MISMATCH_ROLES, {
      severity: 'warning',
      title: 'Расхождение количества записей с 1С',
      body: `Сверка «${a.entity}»: ${diff}.`,
      payload: { entity: a.entity, runId: a.runId, trigger: 'count_mismatch' },
      dedupeKey: `sync_error:count_mismatch:${a.entity}:${a.runId}`,
    });
    this.log.error(
      { entity: a.entity, runId: a.runId, tables: a.tables },
      'sync.alert.count_mismatch: сверка $count нашла расхождение (SYNC-068)',
    );
    return created;
  }

  /**
   * Отказ авторизации или прав 1С (401/403) при чтении (05 §6.5; ТЗ для 1С А.1): тревога `sync_error` администратору
   * сразу, без порога `consecutive_errors`; повтор — не чаще раза в `repeatMinutes` (окно времени в ключе
   * дедупликации). Текст без ПДн и секретов: HTTP-статус и сущность. Возвращает число созданных уведомлений.
   */
  async onecAuthFailed(info: {
    readonly httpStatus: number | null;
    readonly entity: SyncEntity | null;
  }): Promise<number> {
    const bucket = Math.floor(Date.now() / (this.repeatMinutes * 60_000));
    const status = info.httpStatus === 403 ? '403 (нет прав роли POS_ИнтеграцияPOS)' : '401 (неверные учётные данные)';
    const created = await this.notify(COUNT_MISMATCH_ROLES, {
      severity: 'error',
      title: '1С отклонила доступ POS',
      body:
        `1С ответила ${status}${info.entity ? ` при синхронизации «${info.entity}»` : ''}. Чтение из 1С ` +
        `приостановлено на ${ONEC_AUTH_PAUSE_MINUTES} мин; проверьте учётные данные и права пользователя интеграции.`,
      payload: {
        trigger: 'onec_auth_failed',
        ...(info.httpStatus !== null ? { httpStatus: info.httpStatus } : {}),
        ...(info.entity ? { entity: info.entity } : {}),
      },
      dedupeKey: `sync_error:onec_auth:${bucket}`,
    });
    if (created > 0) {
      this.log.error(
        { httpStatus: info.httpStatus, entity: info.entity, recipients: created },
        'sync.alert.onec_auth_failed: 1С отклонила авторизацию (05 §6.5)',
      );
    }
    return created;
  }

  /**
   * Несовместимая версия API расширения 1С (05 ONEC-095, F13): тревога `sync_error` администратору; повтор — не чаще
   * раза в `repeatMinutes` для той же версии (окно в ключе дедупликации). Текст — версии и действие, без ПДн.
   */
  async onecApiIncompatible(info: {
    readonly apiVersion: string;
    readonly extensionVersion: string | null;
  }): Promise<number> {
    const bucket = Math.floor(Date.now() / (this.repeatMinutes * 60_000));
    const created = await this.notify(COUNT_MISMATCH_ROLES, {
      severity: 'error',
      title: 'Обмен с 1С приостановлен: несовместимая версия',
      body:
        `Расширение 1С сообщает версию API «${info.apiVersion}»` +
        `${info.extensionVersion ? ` (расширение ${info.extensionVersion})` : ''}, POS поддерживает другую. ` +
        'Обмен приостановлен, данные не потеряны. Обновите backend POS или расширение 1С.',
      payload: {
        trigger: 'api_incompatible',
        apiVersion: info.apiVersion,
        ...(info.extensionVersion ? { extensionVersion: info.extensionVersion } : {}),
      },
      dedupeKey: `sync_error:api_incompatible:${info.apiVersion}:${bucket}`,
    });
    if (created > 0) {
      this.log.error(
        { apiVersion: info.apiVersion, extensionVersion: info.extensionVersion, recipients: created },
        'sync.alert.api_incompatible: несовместимая версия API расширения 1С (05 ONEC-095)',
      );
    }
    return created;
  }

  /** Версия API расширения снова совместима — обмен возобновлён (одно уведомление на снятие паузы). */
  async onecApiRestored(info: { readonly apiVersion: string }): Promise<number> {
    return this.notify(COUNT_MISMATCH_ROLES, {
      severity: 'info',
      title: 'Обмен с 1С возобновлён',
      body: `Версия API расширения 1С «${info.apiVersion}» совместима с POS. Обмен с 1С снова выполняется.`,
      payload: { trigger: 'api_restored', apiVersion: info.apiVersion },
      dedupeKey: `sync_error:api_restored:${Date.now()}`,
    });
  }

  private async notify(
    roles: readonly string[],
    n: {
      severity: 'info' | 'warning' | 'error';
      title: string;
      body: string;
      payload: Record<string, unknown>;
      dedupeKey: string;
    },
  ): Promise<number> {
    // Переход по `sync_error` клиент строит по `kind` (SCR-43); `target` — только enum контракта (ревью F, RC-3).
    assertNotificationPayload(n.payload);
    const r = await this.db.query(
      `INSERT INTO notifications (user_id, kind, severity, title_ru, body_ru, payload, dedupe_key)
       SELECT DISTINCT u.id, 'sync_error'::notification_kind, $2::text, $3::text, $4::text, $5::jsonb, $6::text
         FROM users u
         JOIN user_roles ur ON ur.user_id = u.id AND ur.revoked_at IS NULL
         JOIN roles r ON r.id = ur.role_id AND r.code::text = ANY($1::text[])
        WHERE u.status = 'active' AND u.deleted_at IS NULL
       ON CONFLICT (user_id, dedupe_key) DO NOTHING`,
      [roles, n.severity, n.title, n.body, JSON.stringify(n.payload), n.dedupeKey],
    );
    return r.rowCount ?? 0;
  }
}
