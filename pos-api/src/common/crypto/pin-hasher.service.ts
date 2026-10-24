import { type Algorithm, hash, type Options, verify } from '@node-rs/argon2';
import type { SecretRing } from './secret-ring.js';

/**
 * Хэш PIN приложения (D-48; 09 §9.6, BIO-019; 07 §5.13): `app_pins.pin_hash = Argon2id(pepper ‖ pin ‖ user_id)`,
 * параметры не ниже OWASP Password Storage CS — m = 19 MiB, t = 2, p = 1; `PIN_PEPPER` — секрет вне БД
 * (`PIN_PEPPER_FILE`), версия — `app_pins.pepper_version` (`PIN_PEPPER_VERSION`). Хранится PHC-строка `$argon2id$…`
 * (соль — случайная, внутри строки). PIN и хэш никогда не логируются (NFR-LOG-001, 11 SEC-078).
 */
/** `Algorithm.Argon2id` (ambient const enum @node-rs/argon2 недоступен при isolatedModules — значение 2). */
const ARGON2ID = 2 as Algorithm;

export const PIN_ARGON2_PARAMS: Readonly<
  Required<Pick<Options, 'algorithm' | 'memoryCost' | 'timeCost' | 'parallelism' | 'outputLen'>>
> = Object.freeze({
  algorithm: ARGON2ID,
  memoryCost: 19_456, // KiB = 19 MiB
  timeCost: 2,
  parallelism: 1,
  outputLen: 32,
});

/** PIN — 4…6 десятичных цифр (07 §5.13 CHECK pin_length BETWEEN 4 AND 6). Политика роли — у модуля profile. */
export const PIN_FORMAT = /^\d{4,6}$/;

export class PinFormatError extends Error {
  override readonly name = 'PinFormatError';
  constructor() {
    super('PIN: ожидается 4–6 цифр');
  }
}

export interface PinHashResult {
  readonly pinHash: string;
  readonly pepperVersion: number;
  readonly pinLength: number;
}

export interface PinVerifyResult {
  readonly ok: boolean;
  /** true — хэш создан не текущей версией pepper или с иными параметрами: при успехе стоит перехэшировать. */
  readonly needsRehash: boolean;
}

export class PinHasher {
  constructor(private readonly ring: SecretRing) {}

  get currentPepperVersion(): number {
    return this.ring.currentVersion;
  }

  async hash(pin: string, userId: string): Promise<PinHashResult> {
    if (!PIN_FORMAT.test(pin)) throw new PinFormatError();
    const pepperVersion = this.ring.currentVersion;
    const pinHash = await hash(this.material(pin, userId, pepperVersion), PIN_ARGON2_PARAMS);
    return { pinHash, pepperVersion, pinLength: pin.length };
  }

  /**
   * Проверка PIN (сравнение — внутри argon2 за постоянное время). Неверный формат, неизвестная версия pepper или
   * повреждённый хэш → `ok: false` без исключения (вызывающий считает это неверной попыткой).
   */
  async verify(pin: string, userId: string, pinHash: string, pepperVersion: number): Promise<PinVerifyResult> {
    if (!PIN_FORMAT.test(pin) || this.ring.get(pepperVersion) === undefined) return { ok: false, needsRehash: false };
    let ok: boolean;
    try {
      ok = await verify(pinHash, this.material(pin, userId, pepperVersion));
    } catch {
      return { ok: false, needsRehash: false };
    }
    const sameParams = pinHash.startsWith(
      `$argon2id$v=19$m=${PIN_ARGON2_PARAMS.memoryCost},t=${PIN_ARGON2_PARAMS.timeCost},p=${PIN_ARGON2_PARAMS.parallelism}$`,
    );
    return { ok, needsRehash: ok && (pepperVersion !== this.ring.currentVersion || !sameParams) };
  }

  /** `pepper ‖ pin ‖ user_id` (07 §5.13) — байтовая конкатенация; user_id — в нижнем регистре. */
  private material(pin: string, userId: string, version: number): Buffer {
    const pepper = this.ring.get(version);
    if (!pepper) throw new RangeError(`PIN_PEPPER: версия ${version} не настроена`);
    return Buffer.concat([pepper, Buffer.from(pin, 'utf8'), Buffer.from(userId.toLowerCase(), 'utf8')]);
  }
}
