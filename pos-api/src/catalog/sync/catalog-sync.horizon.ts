import type pg from 'pg';
import { CATALOG_SYNC_HIDDEN_SESSION_LAG_SECONDS } from './catalog-sync.types.js';

/** Формат меток курсора: UTC с микросекундами (см. `SyncPosition.ts`). */
export const TS_FORMAT = `'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'`;

/** SQL-выражение метки `timestamptz` в формате курсора. */
export function tsText(expr: string): string {
  return `to_char((${expr}) AT TIME ZONE 'UTC', ${TS_FORMAT})`;
}

export interface SyncHorizon {
  /** Строки с `updated_at < horizon` выгружаются; более новые — в следующем запросе. */
  readonly horizon: string;
  /** Время сервера БД на момент запроса (`serverTime` ответа). */
  readonly serverTime: string;
  /** `true` — горизонт сдвинут назад: в БД есть транзакции, начатые до запроса и ещё не завершённые. */
  readonly lagging: boolean;
}

/**
 * Горизонт выгрузки (08 §4.24: «строка, изменённая во время выгрузки, … не теряется»).
 *
 * `updated_at` ставит триггер `set_updated_at` (DATA-002) значением `now()` — **началом** транзакции записи, а строка
 * видна другим только после COMMIT. Если транзакция применения 1С началась в T0 и фиксируется в T0+60 с, а
 * клиент в T0+30 с получил курсор по строке с `updated_at = T0+29 с`, то строки той транзакции (`updated_at = T0`)
 * оказались бы «позади» курсора и были бы потеряны. Поэтому выдаются только строки с `updated_at` строго меньше
 * начала самой ранней незавершённой транзакции в этой БД (`pg_stat_activity.xact_start`), но не позже `now()`.
 * Любая транзакция с началом раньше горизонта к моменту этого запроса уже завершена, и её строки видны следующему
 * запросу страницы (отдельный оператор в режиме READ COMMITTED — новый снимок).
 *
 * Запрос горизонта выполняется отдельным оператором **до** чтения страницы: снимок `pg_stat_activity` берётся раз
 * на транзакцию, а снимок данных следующего оператора — позже, поэтому завершённая между ними транзакция уже видна.
 *
 * Сеансы другой роли без `pg_read_all_stats` в `pg_stat_activity` скрыты (`xact_start = NULL`). В целевом
 * развёртывании api и worker работают под одной ролью `pos_app` (0001 §11) и видят друг друга; если скрытые сеансы
 * есть — горизонт дополнительно не позже `now() - CATALOG_SYNC_HIDDEN_SESSION_LAG_SECONDS` (EQ-CSYNC-03).
 */
export async function readSyncHorizon(db: Pick<pg.Pool, 'query'>): Promise<SyncHorizon> {
  const res = await db.query<{ horizon: string; server_time: string; lagging: boolean }>(
    `WITH act AS (
       SELECT a.xact_start, (a.xact_start IS NULL AND a.state IS NULL) AS hidden
         FROM pg_stat_activity a
        WHERE a.datname = current_database()
          AND a.pid <> pg_backend_pid()
          AND a.backend_type = 'client backend'
     ), h AS (
       SELECT least(
                now(),
                coalesce((SELECT min(xact_start) FROM act WHERE xact_start IS NOT NULL), now()),
                CASE WHEN EXISTS (SELECT 1 FROM act WHERE hidden)
                     THEN now() - make_interval(secs => $1::int) ELSE now() END
              ) AS horizon
     )
     SELECT ${tsText('h.horizon')} AS horizon, ${tsText('now()')} AS server_time, h.horizon < now() AS lagging
       FROM h`,
    [CATALOG_SYNC_HIDDEN_SESSION_LAG_SECONDS],
  );
  const r = res.rows[0];
  if (!r) throw new Error('catalog sync: горизонт не прочитан');
  return { horizon: r.horizon, serverTime: r.server_time, lagging: r.lagging };
}

/** ISO-метка курсора → ISO-строка ответа (`serverTime`, `updatedAt`) с миллисекундами. */
export function isoMillis(ts: string): string {
  return new Date(ts).toISOString();
}
