import { readFileSync } from 'node:fs';

/**
 * Конвенция `*_FILE` (RM-C-009, 16 §4.3, infra/env/README.md): для переменной `X` значение берётся из файла,
 * путь к которому задан в `X_FILE` (Docker Compose secrets `/run/secrets/...`). Если заданы обе — `X_FILE`
 * имеет приоритет над `X`. Пустая строка считается «не задано» (строки `X=` в `.env`).
 * Завершающий перевод строки файла отбрасывается (типично для `echo ... > secrets/x`).
 */
export type EnvSource = Readonly<Record<string, string | undefined>>;
export type FileReader = (path: string) => string;

export interface ResolvedEnv {
  readonly values: Record<string, string>;
  /** Имена переменных, значение которых получено из файла (для диагностики; сами значения не логируются). */
  readonly fromFile: readonly string[];
  readonly errors: readonly string[];
}

const defaultReader: FileReader = (path) => readFileSync(path, 'utf8');

export function resolveEnvWithFiles(
  keys: readonly string[],
  source: EnvSource,
  readFile: FileReader = defaultReader,
): ResolvedEnv {
  const values: Record<string, string> = {};
  const fromFile: string[] = [];
  const errors: string[] = [];
  for (const key of keys) {
    const filePath = nonEmpty(source[`${key}_FILE`]);
    if (filePath !== undefined) {
      try {
        values[key] = readFile(filePath).replace(/\r?\n$/, '');
        fromFile.push(key);
      } catch (e) {
        const reason = e instanceof Error && 'code' in e ? String((e as NodeJS.ErrnoException).code) : 'read error';
        errors.push(`${key}_FILE: не удалось прочитать файл секрета (${reason})`);
      }
      continue;
    }
    const direct = nonEmpty(source[key]);
    if (direct !== undefined) values[key] = direct;
  }
  return { values, fromFile, errors };
}

function nonEmpty(v: string | undefined): string | undefined {
  return v === undefined || v.trim() === '' ? undefined : v;
}

/**
 * 16 §4.3 п. (3): обычные (не-`_FILE`) варианты секретов — только fallback конвенции `*_FILE` при `APP_ENV=dev`.
 * Возвращает проблемы конфигурации (имена переменных, без значений) для секретов, заданных прямым значением вне dev
 * (ревью C-MJ-01).
 */
export function directSecretProblems(
  resolved: ResolvedEnv,
  secretKeys: readonly string[],
  appEnv: string | undefined,
): string[] {
  const env = appEnv ?? 'dev';
  if (env === 'dev') return [];
  return secretKeys
    .filter((k) => resolved.values[k] !== undefined && !resolved.fromFile.includes(k))
    .map(
      (k) =>
        `${k}: при APP_ENV=${env} секрет задаётся только файлом через ${k}_FILE (прямое значение допустимо лишь при APP_ENV=dev, 16 §4.3)`,
    );
}
