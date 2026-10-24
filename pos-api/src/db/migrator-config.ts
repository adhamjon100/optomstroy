import { z } from 'zod';
import {
  directSecretProblems,
  type EnvSource,
  type FileReader,
  resolveEnvWithFiles,
} from '../common/config/env-file.loader.js';
import { envShape } from '../common/config/env.schema.js';

/**
 * Конфигурация контейнера `migrate` (16 §4.3–§4.4; R0 §17.7). Читается только то, что нужно мигратору, —
 * с той же конвенцией `*_FILE`, что и api (env-file.loader): `DATABASE_URL_FILE` даёт хост/порт/БД,
 * `DB_MIGRATOR_PASSWORD_FILE` — пароль роли `pos_migrate` (владелец схемы, DATA-012). Остальные переменные api
 * (`MIN_APP_VERSION` и т. п.) мигратору не нужны и не проверяются.
 */
export const MIGRATOR_ROLE = 'pos_migrate';

const migratorEnvSchema = z.object({
  APP_ENV: envShape.APP_ENV,
  LOG_LEVEL: envShape.LOG_LEVEL,
  DATABASE_URL: envShape.DATABASE_URL,
  DB_MIGRATOR_PASSWORD: envShape.DB_MIGRATOR_PASSWORD,
  RECEIVABLES_MAX_AGE_MIN: envShape.RECEIVABLES_MAX_AGE_MIN,
});

export type MigratorEnv = z.infer<typeof migratorEnvSchema>;

export interface MigratorConnection {
  /** Строка подключения (содержит пароль — не логировать). */
  readonly connectionString: string;
  /** Роль, под которой выполняются миграции. */
  readonly user: string;
  /**
   * true — `DB_MIGRATOR_PASSWORD(_FILE)` не задан и используется пользователь `DATABASE_URL` как есть.
   * Допускается только при `APP_ENV=dev` (локально/CI — суперпользователь embedded PostgreSQL).
   */
  readonly fallbackToDatabaseUrlUser: boolean;
}

export class MigratorConfigError extends Error {
  constructor(readonly problems: readonly string[]) {
    super(`Конфигурация мигратора невалидна:\n  - ${problems.join('\n  - ')}`);
    this.name = 'MigratorConfigError';
  }
}

export function loadMigratorEnv(source: EnvSource = process.env, readFile?: FileReader): MigratorEnv {
  const keys = Object.keys(migratorEnvSchema.shape);
  const resolved = resolveEnvWithFiles(keys, source, readFile);
  const problems = [
    ...resolved.errors,
    ...directSecretProblems(resolved, ['DATABASE_URL', 'DB_MIGRATOR_PASSWORD'], resolved.values.APP_ENV?.trim()),
  ];
  const parsed = migratorEnvSchema.safeParse(resolved.values);
  if (!parsed.success) {
    for (const issue of parsed.error.issues) {
      const key = issue.path.map(String).join('.') || '(env)';
      problems.push(
        resolved.values[key] === undefined
          ? `${key} (или ${key}_FILE): обязательная переменная не задана`
          : `${key}: ${issue.message}`,
      );
    }
  }
  if (problems.length > 0 || !parsed.success) throw new MigratorConfigError(problems);
  return parsed.data;
}

/**
 * Подключение мигратора: логин `pos_migrate` + пароль из `DB_MIGRATOR_PASSWORD_FILE`, хост/порт/БД/параметры —
 * из `DATABASE_URL`. Без пароля мигратора — только `APP_ENV=dev` (пользователь `DATABASE_URL`, предупреждение в
 * лог); в staging/prod — ошибка конфигурации (роль приложения `pos_app` не имеет DDL, DATA-012).
 */
export function migratorConnection(env: MigratorEnv): MigratorConnection {
  let url: URL;
  try {
    url = new URL(env.DATABASE_URL);
  } catch {
    throw new MigratorConfigError(['DATABASE_URL: не удалось разобрать строку подключения']);
  }
  if (env.DB_MIGRATOR_PASSWORD === undefined) {
    if (env.APP_ENV !== 'dev') {
      throw new MigratorConfigError([
        `DB_MIGRATOR_PASSWORD_FILE: обязательна при APP_ENV=${env.APP_ENV} (миграции — только под ролью ${MIGRATOR_ROLE})`,
      ]);
    }
    return {
      connectionString: env.DATABASE_URL,
      user: decodeURIComponent(url.username),
      fallbackToDatabaseUrlUser: true,
    };
  }
  url.username = MIGRATOR_ROLE;
  url.password = encodeURIComponent(env.DB_MIGRATOR_PASSWORD);
  return { connectionString: url.toString(), user: MIGRATOR_ROLE, fallbackToDatabaseUrlUser: false };
}
