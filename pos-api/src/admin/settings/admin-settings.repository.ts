import { Inject, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import type { AppSettingValueType } from './admin-settings.map.js';

export interface AppSettingRow {
  readonly key: string;
  readonly value: unknown;
  readonly rowVersion: number;
}

/**
 * Данные `app_settings` (07 §5.59) для `/admin/settings`. Запись — только этот модуль (common/settings-reader:
 * «Запись — только модуль admin»). Оптимистичная блокировка строки — `row_version` (+1 на каждое изменение,
 * триггер `check_row_version` под ролью pos_app проверяет ровно +1); аудит БД `settings.changed` по строке —
 * триггер `trg_app_settings_audit`.
 */
@Injectable()
export class AdminSettingsRepository {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  /** Сериализация изменений настроек (параллельные PUT с одной `rowVersion` → второй получит VERSION_CONFLICT). */
  async lock(tx: DbExecutor): Promise<void> {
    await tx.execute(sql`SELECT pg_advisory_xact_lock(hashtext('admin.app_settings'))`);
  }

  async load(keys: readonly string[], ex: DbExecutor = this.db): Promise<AppSettingRow[]> {
    if (keys.length === 0) return [];
    const res = await ex.execute<{ key: string; value: unknown; row_version: number | string }>(sql`
      SELECT key, value, row_version FROM app_settings
       WHERE key IN (${sql.join(
         keys.map((k) => sql`${k}`),
         sql`, `,
       )})
       ORDER BY key`);
    return res.rows.map((r) => ({ key: r.key, value: r.value, rowVersion: Number(r.row_version) }));
  }

  async update(key: string, value: unknown, actorUserId: string, tx: DbExecutor): Promise<boolean> {
    const res = await tx.execute<{ key: string }>(sql`
      UPDATE app_settings
         SET value = ${JSON.stringify(value)}::jsonb,
             row_version = row_version + 1,
             updated_by_user_id = ${actorUserId}::uuid,
             updated_at = now()
       WHERE key = ${key}
       RETURNING key`);
    return res.rows.length === 1;
  }

  async insert(
    row: { key: string; value: unknown; valueType: AppSettingValueType; descriptionRu: string },
    actorUserId: string,
    tx: DbExecutor,
  ): Promise<void> {
    await tx.execute(sql`
      INSERT INTO app_settings (key, value, value_type, description_ru, updated_by_user_id)
      VALUES (${row.key}, ${JSON.stringify(row.value)}::jsonb, ${row.valueType}, ${row.descriptionRu},
              ${actorUserId}::uuid)`);
  }
}
