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

/**
 * Предупреждения конфигурации, не мешающие старту (печатают main.ts и worker.ts при запуске; значения секретов не
 * выводятся). ADR-123: `QR_PROVIDER=bakai` — устаревший синоним `bank` (банк заказчика — не Бакай, Q-381).
 */
export function configWarnings(source: EnvSource = process.env): string[] {
  const out: string[] = [];
  if (source.QR_PROVIDER?.trim() === 'bakai') {
    out.push('QR_PROVIDER=bakai — устаревшее значение, используется QR_PROVIDER=bank (ADR-123); замените в .env');
  }
  const qr = source.QR_PROVIDER?.trim();
  if ((qr === 'bank' || qr === 'bakai') && (source.BANK_QR_ADAPTER?.trim() ?? 'sandbox') === 'sandbox') {
    const unused = ['BANK_QR_API_BASE_URL', 'BANK_QR_MERCHANT_ID', 'BANK_QR_API_KEY_FILE'].filter(
      (k) => (source[k] ?? '').trim() !== '',
    );
    if (unused.length > 0) {
      out.push(`BANK_QR_ADAPTER=sandbox: ${unused.join(', ')} не используются песочницей банка (ADR-123)`);
    }
  }
  return out;
}
