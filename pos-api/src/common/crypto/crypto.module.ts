import { Global, Logger, Module } from '@nestjs/common';
import { APP_CONFIG, type AppConfig } from '../config/app-config.js';
import { OtpHmacService } from './otp-hmac.service.js';
import { PinHasher } from './pin-hasher.service.js';
import { parseSecretRing, type SecretRing } from './secret-ring.js';

/** Токены DI наборов секретов (для тестов и ротации). */
export const OTP_HMAC_SECRET_RING = Symbol('OTP_HMAC_SECRET_RING');
export const PIN_PEPPER_RING = Symbol('PIN_PEPPER_RING');

function ringFactory(name: 'OTP_HMAC_SECRET' | 'PIN_PEPPER') {
  return (c: AppConfig): SecretRing => {
    const ring =
      name === 'OTP_HMAC_SECRET'
        ? parseSecretRing(name, c.OTP_HMAC_SECRET, c.OTP_HMAC_SECRET_VERSION, c.APP_ENV)
        : parseSecretRing(name, c.PIN_PEPPER, c.PIN_PEPPER_VERSION, c.APP_ENV);
    if (ring.ephemeral) {
      new Logger('crypto').warn(
        { event: 'crypto.ephemeral_secret', secret: name },
        `${name}_FILE не задан: APP_ENV=dev — эфемерный секрет до перезапуска процесса`,
      );
    }
    return ring;
  };
}

/**
 * common/crypto (RM-D-001, RM-D-004 — общий фундамент): HMAC OTP и хэш PIN с версионированными секретами
 * из `*_FILE`. CSPRNG-утилиты (random.ts) — чистые функции, DI не требуют.
 */
@Global()
@Module({
  providers: [
    { provide: OTP_HMAC_SECRET_RING, inject: [APP_CONFIG], useFactory: ringFactory('OTP_HMAC_SECRET') },
    { provide: PIN_PEPPER_RING, inject: [APP_CONFIG], useFactory: ringFactory('PIN_PEPPER') },
    { provide: OtpHmacService, inject: [OTP_HMAC_SECRET_RING], useFactory: (r: SecretRing) => new OtpHmacService(r) },
    { provide: PinHasher, inject: [PIN_PEPPER_RING], useFactory: (r: SecretRing) => new PinHasher(r) },
  ],
  exports: [OtpHmacService, PinHasher, OTP_HMAC_SECRET_RING, PIN_PEPPER_RING],
})
export class CryptoModule {}
