import { hash, verify } from '@node-rs/argon2';
import { PIN_ARGON2_PARAMS } from './pin-hasher.service.js';
import { EXIT_CODE_LENGTH } from './random.js';
import type { SecretRing } from './secret-ring.js';

/**
 * Хэш аварийного кода выхода планшета магазина (11 SEC-140; 09 §8.9 п. 5; 07 §5.65; ADR-115):
 * `store_tablets.exit_code_hash = Argon2id(pepper ‖ код ‖ tablet_id)` с параметрами и pepper PIN по SEC-047
 * (`PIN_PEPPER_FILE`, m = 19 MiB, t = 2, p = 1); версия pepper — `store_tablets.exit_code_pepper_version`
 * (`PIN_PEPPER_VERSION`, ротация — как `app_pins.pepper_version`). 10^8 вариантов кода мало для перебора по украденной
 * копии хэша — поэтому серверный pepper. Хранится PHC-строка `$argon2id$…` (соль — случайная, внутри строки).
 * Код и хэш никогда не логируются и не попадают в аудит, уведомления и хранилище идемпотентности (SEC-062, SEC-078,
 * SEC-141). Проверку кода (`POST /kiosk/exit`, попытки и пауза) выполняет модуль `kiosk` — здесь только хэш.
 */
/** Аварийный код — ровно 8 десятичных цифр (11 SEC-140). */
export const EXIT_CODE_FORMAT = new RegExp(`^\\d{${EXIT_CODE_LENGTH}}$`);

export class ExitCodeFormatError extends Error {
  override readonly name = 'ExitCodeFormatError';
  constructor() {
    super(`аварийный код: ожидается ${EXIT_CODE_LENGTH} цифр`);
  }
}

export interface ExitCodeHashResult {
  readonly exitCodeHash: string;
  readonly pepperVersion: number;
}

export interface ExitCodeVerifyResult {
  readonly ok: boolean;
  /** true — хэш создан не текущей версией pepper или с иными параметрами (новый код выдаётся подключением заново). */
  readonly needsRehash: boolean;
}

export class ExitCodeHasher {
  constructor(private readonly ring: SecretRing) {}

  get currentPepperVersion(): number {
    return this.ring.currentVersion;
  }

  async hash(code: string, tabletId: string): Promise<ExitCodeHashResult> {
    if (!EXIT_CODE_FORMAT.test(code)) throw new ExitCodeFormatError();
    const pepperVersion = this.ring.currentVersion;
    const exitCodeHash = await hash(this.material(code, tabletId, pepperVersion), PIN_ARGON2_PARAMS);
    return { exitCodeHash, pepperVersion };
  }

  /**
   * Проверка кода (сравнение — внутри argon2 за постоянное время). Неверный формат, неизвестная версия pepper или
   * повреждённый хэш → `ok: false` без исключения (вызывающий считает это неверной попыткой).
   */
  async verify(
    code: string,
    tabletId: string,
    exitCodeHash: string,
    pepperVersion: number,
  ): Promise<ExitCodeVerifyResult> {
    if (!EXIT_CODE_FORMAT.test(code) || this.ring.get(pepperVersion) === undefined) {
      return { ok: false, needsRehash: false };
    }
    let ok: boolean;
    try {
      ok = await verify(exitCodeHash, this.material(code, tabletId, pepperVersion));
    } catch {
      return { ok: false, needsRehash: false };
    }
    const sameParams = exitCodeHash.startsWith(
      `$argon2id$v=19$m=${PIN_ARGON2_PARAMS.memoryCost},t=${PIN_ARGON2_PARAMS.timeCost},p=${PIN_ARGON2_PARAMS.parallelism}$`,
    );
    return { ok, needsRehash: ok && (pepperVersion !== this.ring.currentVersion || !sameParams) };
  }

  /** `pepper ‖ код ‖ tablet_id` (07 §5.65) — байтовая конкатенация; `tablet_id` (`store_tablets.id`) — в нижнем регистре. */
  private material(code: string, tabletId: string, version: number): Buffer {
    const pepper = this.ring.get(version);
    if (!pepper) throw new RangeError(`PIN_PEPPER: версия ${version} не настроена`);
    return Buffer.concat([pepper, Buffer.from(code, 'utf8'), Buffer.from(tabletId.toLowerCase(), 'utf8')]);
  }
}
