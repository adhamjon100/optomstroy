import type pg from 'pg';
import type { Logger } from 'pino';
import type { SyncEntity } from '../../common/enums.js';
import type { SyncAlertService } from './sync-alerts.service.js';

type Queryable = Pick<pg.Pool, 'query'>;

/** Узел плана обмена (`sync_node_state.node`, = `ONEC_NODE` цикла `onec.changes`). */
const NODE = 'pos';

/**
 * Мажорная версия API расширения, которую понимает backend (05 §6.3: версия — в пути `v1` и в `X-POS-API-Version: 1`;
 * несовместимые изменения → `v2`; контракт `Health.apiVersion` — «для v1 — `1`»). Дополнительные части (`1.1`) —
 * совместимые расширения той же мажорной версии.
 */
export const ONEC_SUPPORTED_API_MAJOR = 1;

/**
 * Префикс `sync_state.paused_reason` автоматической паузы по ONEC-095 (= значение `api_incompatible` из перечня
 * причин `/health/ready` контракта 08). По нему пауза отличается от прочих и снимается при совместимой версии.
 */
export const API_INCOMPATIBLE_REASON = 'api_incompatible';

const MAX_VERSION_LEN = 32;

/** `apiVersion` из `/pos/v1/health` совместима с backend: мажорная часть = `ONEC_SUPPORTED_API_MAJOR`. */
export function isApiVersionCompatible(apiVersion: string): boolean {
  const m = /^(\d+)(?:\.\d+)*$/.exec(apiVersion.trim());
  return m !== null && Number(m[1]) === ONEC_SUPPORTED_API_MAJOR;
}

/** Действующая пауза обмена из-за несовместимой версии API расширения. */
export interface OnecApiPauseState {
  /** Текст причины (`sync_state.paused_reason`), без ПДн. */
  readonly reason: string;
}

/** Обмен с 1С приостановлен (ONEC-095): цикл/прогон к 1С не обращается, причина — в `reason`. */
export class OnecApiPausedError extends Error {
  constructor(readonly reason: string) {
    super(reason);
    this.name = 'OnecApiPausedError';
  }
}

/** Версия для текста: только печатные символы, усечение (ответ 1С — внешние данные). */
function shown(v: string): string {
  const s = v.replace(/[^\p{L}\p{N}._-]/gu, '').slice(0, MAX_VERSION_LEN);
  return s === '' ? '—' : s;
}

/**
 * Совместимость версии API расширения 1С (05 ONEC-095, F13; 12 T-SYNC-F13, T-COMPAT-008): при каждом
 * `GET /pos/v1/health` цикла `onec.changes` backend сверяет `apiVersion`. Несовместимая версия → все сущности
 * `sync_state.paused = true` с причиной (`paused_reason`), тревога `sync_error` администратору, запись уровня `error`;
 * обмен к 1С не обращается (`/changes` не читается, ack не отправляется — регистрации плана обмена остаются в 1С,
 * локальные данные не меняются: потери данных нет). Совместимая версия снова → пауза снимается, уведомление
 * «обмен возобновлён». Версии расширения/API пишутся в `sync_node_state` (05 SYNC-037). В R1 это единственный
 * источник `paused` (05 SYNC-028: ручная пауза — R2).
 */
export class OnecApiCompatibility {
  constructor(
    private readonly db: Queryable,
    private readonly opts: {
      readonly alerts?: Pick<SyncAlertService, 'onecApiIncompatible' | 'onecApiRestored'>;
      readonly log?: Pick<Logger, 'info' | 'error' | 'warn'>;
    } = {},
  ) {}

  /** Пауза действует (для сущности или для любой) → причина; иначе `null`. Ошибка чтения паузу не включает. */
  async active(entity?: SyncEntity): Promise<OnecApiPauseState | null> {
    try {
      const r = await this.db.query<{ reason: string }>(
        `SELECT paused_reason AS reason FROM sync_state
          WHERE paused AND paused_reason LIKE $1 AND ($2::sync_entity IS NULL OR entity = $2::sync_entity)
          ORDER BY entity LIMIT 1`,
        [`${API_INCOMPATIBLE_REASON}%`, entity ?? null],
      );
      const row = r.rows[0];
      return row ? { reason: row.reason } : null;
    } catch (err) {
      this.opts.log?.warn({ err }, 'sync.api_compat.read_failed: отметка паузы не прочитана, обмен не приостановлен');
      return null;
    }
  }

  /**
   * Сверка ответа `/health`. Несовместимо → пауза (возвращает её состояние); совместимо → снятие паузы (`null`).
   * Тревога — при каждой несовместимой проверке, повтор не чаще раза в 60 мин (окно в ключе дедупликации, SYNC-038).
   */
  async check(health: {
    readonly apiVersion: string;
    readonly extensionVersion?: string | null;
  }): Promise<OnecApiPauseState | null> {
    const apiVersion = String(health.apiVersion);
    const extensionVersion = health.extensionVersion ? String(health.extensionVersion) : null;
    await this.db.query(
      `INSERT INTO sync_node_state (node, api_version, extension_version) VALUES ($1, $2, $3)
       ON CONFLICT (node) DO UPDATE SET api_version = EXCLUDED.api_version, extension_version = EXCLUDED.extension_version
        WHERE sync_node_state.api_version IS DISTINCT FROM EXCLUDED.api_version
           OR sync_node_state.extension_version IS DISTINCT FROM EXCLUDED.extension_version`,
      [NODE, apiVersion.slice(0, 64), extensionVersion?.slice(0, 64) ?? null],
    );
    if (isApiVersionCompatible(apiVersion)) {
      await this.resume(apiVersion);
      return null;
    }
    const reason =
      `${API_INCOMPATIBLE_REASON}: расширение 1С сообщает версию API «${shown(apiVersion)}»` +
      `${extensionVersion ? ` (расширение ${shown(extensionVersion)})` : ''}, POS поддерживает версию ` +
      `${ONEC_SUPPORTED_API_MAJOR}. Обмен с 1С приостановлен, данные не потеряны; обновите backend POS или ` +
      'расширение 1С (05 ONEC-095).';
    const r = await this.db.query<{ entity: SyncEntity }>(
      `UPDATE sync_state SET paused = true, paused_reason = $1, updated_at = now()
        WHERE (NOT paused OR paused_reason LIKE $2) AND paused_reason IS DISTINCT FROM $1
        RETURNING entity::text AS entity`,
      [reason, `${API_INCOMPATIBLE_REASON}%`],
    );
    if ((r.rowCount ?? 0) > 0) {
      this.opts.log?.error(
        { apiVersion: shown(apiVersion), extensionVersion, entities: r.rows.map((x) => x.entity) },
        'sync.api_compat.paused: несовместимая версия API расширения 1С — обмен приостановлен (05 ONEC-095)',
      );
    }
    await this.opts.alerts
      ?.onecApiIncompatible({
        apiVersion: shown(apiVersion),
        extensionVersion: extensionVersion && shown(extensionVersion),
      })
      .catch((err: unknown) => this.opts.log?.error({ err }, 'sync.api_compat.alert_failed'));
    return { reason };
  }

  /** Совместимая версия: снять автоматическую паузу ONEC-095 (только её) и сообщить о возобновлении. */
  private async resume(apiVersion: string): Promise<void> {
    const r = await this.db.query<{ entity: SyncEntity }>(
      `UPDATE sync_state SET paused = false, paused_reason = NULL, updated_at = now()
        WHERE paused AND paused_reason LIKE $1 RETURNING entity::text AS entity`,
      [`${API_INCOMPATIBLE_REASON}%`],
    );
    if ((r.rowCount ?? 0) === 0) return;
    this.opts.log?.info(
      { apiVersion: shown(apiVersion), entities: r.rows.map((x) => x.entity) },
      'sync.api_compat.resumed: версия API расширения 1С совместима — обмен возобновлён',
    );
    await this.opts.alerts
      ?.onecApiRestored({ apiVersion: shown(apiVersion) })
      .catch((err: unknown) => this.opts.log?.error({ err }, 'sync.api_compat.alert_failed'));
  }
}
