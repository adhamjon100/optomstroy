import { randomBytes } from 'node:crypto';

/**
 * Версионированный серверный секрет (pepper): `OTP_HMAC_SECRET` + `OTP_HMAC_SECRET_VERSION`,
 * `PIN_PEPPER` + `PIN_PEPPER_VERSION` (ядро R0 §17.7; 09 §5.2, §9.6; 11 §5.1).
 *
 * Значение приходит из файла `<ИМЯ>_FILE` (конвенция *_FILE, env-file.loader.ts) в одном из двух форматов:
 * - одна строка — секрет текущей версии (`<ИМЯ>_VERSION`);
 * - JSON-объект `{"1": "…", "2": "…"}` — набор версий для ротации без сброса (старые хэши/челленджи проверяются
 *   своей версией, новые создаются текущей). Текущая версия обязана присутствовать в наборе.
 *
 * Секрет — не короче 32 байт (09 §5.2 «≥ 32 байт»). Значения секретов в сообщения об ошибках не попадают.
 */
export const MIN_SECRET_BYTES = 32;

export class SecretConfigError extends Error {
  override readonly name = 'SecretConfigError';
}

export interface SecretRing {
  readonly name: string;
  readonly currentVersion: number;
  /** Секрет версии; `undefined` — версия неизвестна (ротирована и удалена). */
  get(version: number): Buffer | undefined;
  readonly versions: readonly number[];
  /** true — секрет сгенерирован на старт процесса (только APP_ENV=dev, когда файл не задан). */
  readonly ephemeral: boolean;
}

class MapSecretRing implements SecretRing {
  constructor(
    readonly name: string,
    readonly currentVersion: number,
    private readonly map: ReadonlyMap<number, Buffer>,
    readonly ephemeral: boolean,
  ) {}

  get(version: number): Buffer | undefined {
    return this.map.get(version);
  }

  get versions(): readonly number[] {
    return [...this.map.keys()].sort((a, b) => a - b);
  }
}

function checkSecret(name: string, version: number, value: string): Buffer {
  const buf = Buffer.from(value, 'utf8');
  if (buf.length < MIN_SECRET_BYTES) {
    throw new SecretConfigError(`${name} (версия ${version}): секрет короче ${MIN_SECRET_BYTES} байт`);
  }
  return buf;
}

/**
 * Разбор значения секрета. `raw === undefined`: при `appEnv === 'dev'` — эфемерный секрет на время жизни процесса
 * (хэши/HMAC не переживут перезапуск — допустимо только для локальной разработки), иначе — ошибка конфигурации.
 */
export function parseSecretRing(
  name: string,
  raw: string | undefined,
  currentVersion: number,
  appEnv: string,
): SecretRing {
  if (!Number.isInteger(currentVersion) || currentVersion < 1) {
    throw new SecretConfigError(`${name}_VERSION: ожидается целое ≥ 1`);
  }
  if (raw === undefined || raw.trim() === '') {
    if (appEnv !== 'dev') {
      throw new SecretConfigError(`${name} (${name}_FILE) не задан: обязателен при APP_ENV=${appEnv}`);
    }
    // Эфемерный секрет — base64url-строка (43 байта ASCII), а не сырые байты: Argon2 (`@node-rs/argon2.verify`)
    // принимает пароль только в UTF-8, иначе PinHasher.verify никогда не подтверждал бы PIN (D_spec_questions A-12/RG-07).
    const ephemeral = Buffer.from(randomBytes(32).toString('base64url'), 'utf8');
    return new MapSecretRing(name, currentVersion, new Map([[currentVersion, ephemeral]]), true);
  }
  const trimmed = raw.trim();
  const map = new Map<number, Buffer>();
  if (trimmed.startsWith('{')) {
    let parsed: unknown;
    try {
      parsed = JSON.parse(trimmed);
    } catch {
      throw new SecretConfigError(`${name}: набор версий должен быть JSON-объектом {"<версия>": "<секрет>"}`);
    }
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
      throw new SecretConfigError(`${name}: набор версий должен быть JSON-объектом {"<версия>": "<секрет>"}`);
    }
    for (const [k, v] of Object.entries(parsed as Record<string, unknown>)) {
      if (!/^[1-9]\d{0,4}$/.test(k)) throw new SecretConfigError(`${name}: версия «${k}» — не целое ≥ 1`);
      if (typeof v !== 'string') throw new SecretConfigError(`${name} (версия ${k}): значение должно быть строкой`);
      map.set(Number(k), checkSecret(name, Number(k), v));
    }
    if (!map.has(currentVersion)) {
      throw new SecretConfigError(`${name}: в наборе нет текущей версии ${currentVersion} (${name}_VERSION)`);
    }
  } else {
    map.set(currentVersion, checkSecret(name, currentVersion, trimmed));
  }
  return new MapSecretRing(name, currentVersion, map, false);
}
