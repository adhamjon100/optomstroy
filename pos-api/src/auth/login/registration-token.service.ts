import { Inject, Injectable } from '@nestjs/common';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { JwtService, JwtVerificationError } from '../../common/auth/jwt.service.js';
import { constantTimeEqual, sha256 } from '../../common/crypto/random.js';
import { isUuid } from '../../common/ids/uuid.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { TokenDenylistRepository } from '../../users/token-denylist.repository.js';
import { REGISTRATION_TOKEN_TTL_SECONDS } from '../common/auth-policy.js';
import { type OtpChallengeRow, OtpChallengesRepository } from '../otp/otp-challenges.repository.js';

export interface IssuedRegistrationToken {
  readonly token: string;
  readonly jti: string;
  readonly expiresAt: Date;
  readonly expiresIn: number;
}

/** Данные погашенного `registration_token` для `POST /registration/complete` (RM-D-004). */
export interface ConsumedRegistrationToken {
  readonly challengeId: string;
  /** Подтверждённый номер — из `otp_challenges`, не из JWT (в токене ПДн нет). */
  readonly phoneE164: string;
  /** `X-Device-Id`, на котором подтверждён код. */
  readonly deviceKey: string;
  readonly jti: string;
  readonly expiresAt: Date;
}

/**
 * `registration_token` (09 §7.3; ядро §17.2, §18.2 п. 6): JWT `purpose=registration` 15 мин с claims
 * `{challengeId, deviceId}` (без телефона); привязан к челленджу через `otp_challenges.registration_token_hash`
 * (SHA-256) и `registration_token_expires_at`. Одноразовость — `token_denylist` (`token_kind=registration`, (check-secrets: allow — текст документации, не секрет)
 * `reason=used`). Повтор verify (09 §5.6) перевыпускает токен — прежний перестаёт совпадать с хэшем.
 */
@Injectable()
export class RegistrationTokenService {
  constructor(
    @Inject(CLOCK) private readonly clock: Clock,
    private readonly jwt: JwtService,
    private readonly challenges: OtpChallengesRepository,
    private readonly denylist: TokenDenylistRepository,
  ) {}

  async issue(challenge: OtpChallengeRow, deviceKey: string, tx: DbExecutor): Promise<IssuedRegistrationToken> {
    const t = await this.jwt.signPurpose('registration', {
      ttlSeconds: REGISTRATION_TOKEN_TTL_SECONDS,
      claims: { challengeId: challenge.id, deviceId: deviceKey },
    });
    await this.challenges.update(
      challenge.id,
      { registrationTokenHash: sha256(t.token), registrationTokenExpiresAt: t.expiresAt },
      this.clock.now(),
      tx,
    );
    return { token: t.token, jti: t.jti, expiresAt: t.expiresAt, expiresIn: REGISTRATION_TOKEN_TTL_SECONDS };
  }

  /**
   * Проверка и погашение токена в транзакции регистрации. Любая неудача (подпись, срок, чужой тип, хэш не
   * совпадает, другое устройство, повторное использование) → 401 REGISTRATION_TOKEN_INVALID без деталей.
   */
  async consume(
    token: string,
    opts: { readonly deviceKey?: string },
    tx: DbExecutor,
  ): Promise<ConsumedRegistrationToken> {
    const v = await this.inspect(token, opts, tx);
    const fresh = await this.denylist.add(
      { jti: v.jti, tokenKind: 'registration', expiresAt: v.expiresAt, reason: 'used' },
      tx,
    );
    if (!fresh) throw invalid();
    return v;
  }

  /** Проверка без погашения (например, предварительная валидация формы). */
  async inspect(
    token: string,
    opts: { readonly deviceKey?: string },
    tx: DbExecutor,
  ): Promise<ConsumedRegistrationToken> {
    let verified: Awaited<ReturnType<JwtService['verifyPurpose']>>;
    try {
      verified = await this.jwt.verifyPurpose(token, 'registration');
    } catch (e) {
      if (e instanceof JwtVerificationError) throw invalid();
      throw e;
    }
    const challengeId = verified.claims.challengeId;
    const deviceId = verified.claims.deviceId;
    if (!isUuid(challengeId) || typeof deviceId !== 'string') throw invalid();
    if (opts.deviceKey !== undefined && opts.deviceKey.toLowerCase() !== deviceId.toLowerCase()) throw invalid();
    const ch = await this.challenges.findById(challengeId, tx, true);
    const now = this.clock.now();
    if (
      !ch ||
      ch.purpose !== 'login_or_register' ||
      ch.status !== 'verified' ||
      ch.deviceKey !== deviceId ||
      ch.registrationTokenHash === null ||
      ch.registrationTokenExpiresAt === null ||
      ch.registrationTokenExpiresAt.getTime() <= now.getTime() ||
      !constantTimeEqual(ch.registrationTokenHash, sha256(token))
    ) {
      throw invalid();
    }
    return {
      challengeId: ch.id,
      phoneE164: ch.phoneE164,
      deviceKey: deviceId,
      jti: verified.jti,
      expiresAt: new Date(verified.exp * 1000),
    };
  }
}

function invalid(): ProblemException {
  return new ProblemException('REGISTRATION_TOKEN_INVALID', {
    detail: 'Сеанс регистрации истёк. Подтвердите номер заново.',
  });
}
