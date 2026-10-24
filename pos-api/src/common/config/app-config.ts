import { directSecretProblems, type EnvSource, type FileReader, resolveEnvWithFiles } from './env-file.loader.js';
import { ENV_KEYS, type Env, envSchema, SECRET_ENV_KEYS } from './env.schema.js';

/** Токен DI для типизированной конфигурации (значение загружается один раз в bootstrap). */
export const APP_CONFIG = Symbol('APP_CONFIG');
export type AppConfig = Env;

/**
 * Ошибка конфигурации: перечисляет имена переменных и причины, но не значения (секреты не попадают в вывод).
 * main.ts печатает message в stderr и завершает процесс с кодом 1 (RM-C-009 п. 5).
 */
export class ConfigError extends Error {
  constructor(readonly problems: readonly string[]) {
    super(`Конфигурация окружения невалидна — сервис не запущен:\n  - ${problems.join('\n  - ')}`);
    this.name = 'ConfigError';
  }
}

export function loadAppConfig(source: EnvSource = process.env, readFile?: FileReader): AppConfig {
  const resolved = resolveEnvWithFiles(ENV_KEYS, source, readFile);
  const problems = [
    ...resolved.errors,
    ...directSecretProblems(resolved, SECRET_ENV_KEYS, resolved.values.APP_ENV?.trim()),
  ];
  const parsed = envSchema.safeParse(resolved.values);
  if (!parsed.success) {
    for (const issue of parsed.error.issues) {
      const key = issue.path.map(String).join('.') || '(env)';
      const missing = issue.code === 'invalid_type' && resolved.values[key] === undefined;
      problems.push(
        missing ? `${key} (или ${key}_FILE): обязательная переменная не задана` : `${key}: ${issue.message}`,
      );
    }
  }
  if (problems.length > 0 || !parsed.success) throw new ConfigError(problems);
  return Object.freeze(parsed.data);
}
