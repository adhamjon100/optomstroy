import { Inject, Injectable, Logger } from '@nestjs/common';
import { type AuditContext, applyAuditGucs } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import { JwtService } from '../../common/auth/jwt.service.js';
import type { AuthenticatedPrincipal } from '../../common/auth/principal.js';
import { DRIZZLE, type Database } from '../../common/db/database.module.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { PermissionCatalog } from '../../common/rbac/permission-catalog.js';
import { SessionsRepository } from '../../users/sessions.repository.js';
import { UsersRepository } from '../../users/users.repository.js';
import { STEP_UP_TTL_SECONDS } from '../common/auth-policy.js';
import { AuthHttpRateLimiter } from '../common/http-rate-limits.js';
import { type IssuedChallenge, OtpService } from '../otp/otp.service.js';
import { PinVerifier } from '../pin/pin-verifier.service.js';
import {
  permissionForOperation,
  STEP_UP_METHODS_R1,
  stepUpPermitted,
  type StepUpMethodR1,
  type StepUpOperation,
  tokenScope,
} from './step-up.operations.js';
import { StepUpTokenVerifier } from './step-up-token.verifier.js';

export interface StepUpTokenBody {
  readonly stepUpToken: string;
  readonly expiresAt: string;
  readonly method: StepUpMethodR1;
  readonly scope: readonly string[];
}

export interface StepUpOtpIssued {
  readonly challengeId: string;
  readonly resendAfterSec: number;
  readonly otpTtlSec: number;
}

export interface StepUpRequestInput {
  readonly principal: AuthenticatedPrincipal;
  readonly method: StepUpMethodR1;
  readonly operation: StepUpOperation;
  readonly pin?: string;
  readonly challengeId?: string;
  readonly code?: string;
  readonly ip: string | null;
  readonly requestId: string | null;
  readonly audit: AuditContext;
}

/** Результат проверки `X-Step-Up-Token` для операции (пишется в аудит операции как `stepUpMethod`). */
export interface VerifiedStepUp {
  readonly method: StepUpMethodR1;
  readonly operation: StepUpOperation;
  readonly jti: string;
  readonly expiresAt: Date;
}

/**
 * Step-up (RM-D-003; 09 §8.8; 08 §2.12, §4.1.7; ядро §18.2 п. 6, §19.3): `stepUpToken` — JWT `purpose=step_up`
 * 15 мин с claims `sid`, `deviceId`, `scope=[operation]`, `method`, `pv` (permissionsVersion); **многоразовый**
 * в своей области до истечения. Не принимается: другая область, другая сессия/устройство, после смены прав (`pv`),
 * после отзыва сессии (AuthGuard) и `jti` из `token_denylist`. Методы R1 — PIN (серверная проверка) и OTP.
 */
@Injectable()
export class StepUpService {
  private readonly logger = new Logger('auth');

  constructor(
    @Inject(DRIZZLE) private readonly db: Database,
    private readonly jwt: JwtService,
    private readonly catalog: PermissionCatalog,
    private readonly pinVerifier: PinVerifier,
    private readonly otp: OtpService,
    private readonly users: UsersRepository,
    private readonly sessions: SessionsRepository,
    private readonly tokens: StepUpTokenVerifier,
    private readonly limiter: AuthHttpRateLimiter,
    private readonly audit: AuditService,
  ) {}

  /** 403 STEP_UP_REQUIRED с подсказкой клиенту (08 §2.12). */
  static required(operation: StepUpOperation): ProblemException {
    return StepUpTokenVerifier.required(operation, STEP_UP_METHODS_R1);
  }

  /**
   * `POST /auth/step-up`: PIN → токен; OTP шаг 1 (без `challengeId`) → 202 с челленджем `purpose=step_up` на
   * номер пользователя; OTP шаг 2 (`challengeId` + `code`) → токен.
   */
  async request(
    input: StepUpRequestInput,
  ): Promise<{ kind: 'token'; body: StepUpTokenBody } | { kind: 'otp'; body: StepUpOtpIssued }> {
    const p = input.principal;
    const granted = this.catalog.effectivePermissions(p);
    if (!stepUpPermitted(input.operation, granted)) {
      await this.failedAudit(input, 'operation_not_permitted');
      throw new ProblemException('FORBIDDEN', {
        detail: 'Операция недоступна для вашей роли.',
        reason: 'operation_not_permitted',
      });
    }
    if (input.method === 'pin') {
      if (input.pin === undefined) throw validation('pin', 'required', 'PIN обязателен');
      await this.limiter.pin(p.userId, p.deviceId);
      const res = await this.db.transaction(async (tx) => {
        await applyAuditGucs(tx, input.audit);
        const check = await this.pinVerifier.verify(p.userId, input.pin as string, tx);
        if (check.kind !== 'ok') {
          await this.audit.write(
            input.audit,
            {
              action: check.kind === 'locked_now' ? 'auth.pin.locked' : 'auth.step_up.failed',
              entityType: 'session',
              entityId: p.sessionId,
              result: 'denied',
              stepUpMethod: 'pin',
              after: { method: 'pin', operation: input.operation, reason: check.kind },
            },
            tx,
          );
          return { ok: false as const, check };
        }
        const body = await this.issueToken(p, input.operation, 'pin');
        await this.sessions.setStepUp(p.sessionId, new Date(body.expiresAt), 'pin', tx);
        await this.okAudit(input, 'pin', tx);
        return { ok: true as const, body };
      });
      if (!res.ok) throw PinVerifier.toProblem(res.check);
      return { kind: 'token', body: res.body };
    }

    // method = otp
    if (input.challengeId === undefined && input.code === undefined) {
      const user = await this.users.findById(p.userId);
      if (!user?.phoneE164)
        throw new ProblemException('FORBIDDEN', { detail: 'Номер не подтверждён.', reason: 'no_phone' });
      const issued: IssuedChallenge = await this.otp.issue({
        phoneE164: user.phoneE164,
        purpose: 'step_up',
        deviceKey: p.deviceId,
        ip: input.ip,
        requestId: input.requestId,
        userId: p.userId,
        audit: input.audit,
      });
      return {
        kind: 'otp',
        body: { challengeId: issued.challengeId, resendAfterSec: issued.resendAfterSec, otpTtlSec: issued.otpTtlSec },
      };
    }
    if (input.challengeId === undefined) throw validation('challengeId', 'required', 'challengeId обязателен');
    if (input.code === undefined) throw validation('code', 'required', 'code обязателен');
    const res = await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, input.audit);
      const check = await this.otp.check(tx, {
        challengeId: input.challengeId as string,
        code: input.code as string,
        deviceKey: p.deviceId,
        purpose: 'step_up',
        userId: p.userId,
        allowReplay: false,
      });
      if (check.kind === 'ok') {
        const body = await this.issueToken(p, input.operation, 'otp');
        await this.sessions.setStepUp(p.sessionId, new Date(body.expiresAt), 'otp', tx);
        await this.okAudit(input, 'otp', tx);
        return { ok: true as const, body };
      }
      if (check.kind !== 'replay' && check.kind !== 'not_found') {
        await this.audit.write(
          input.audit,
          {
            action: check.kind === 'invalid' && check.lockedNow ? 'auth.otp.locked' : 'auth.step_up.failed',
            entityType: 'session',
            entityId: p.sessionId,
            result: 'denied',
            stepUpMethod: 'otp',
            after: { method: 'otp', operation: input.operation, reason: check.kind },
          },
          tx,
        );
      }
      return { ok: false as const, check: check.kind === 'replay' ? ({ kind: 'expired' } as const) : check };
    });
    if (!res.ok) throw OtpService.toProblem(res.check);
    return { kind: 'token', body: res.body };
  }

  /**
   * Проверка `X-Step-Up-Token` для операции (используется StepUpGuard и сервисами других модулей). Нет/неверный/
   * истёкший/чужой токен или другая область → 403 STEP_UP_REQUIRED.
   */
  async verify(
    token: string | undefined,
    principal: AuthenticatedPrincipal,
    operation: StepUpOperation,
  ): Promise<VerifiedStepUp> {
    const v = await this.tokens.verify(token, principal, { operation, allowedMethods: STEP_UP_METHODS_R1 });
    return { method: v.method, operation, jti: v.jti, expiresAt: v.expiresAt };
  }

  private async issueToken(
    p: AuthenticatedPrincipal,
    operation: StepUpOperation,
    method: StepUpMethodR1,
  ): Promise<StepUpTokenBody> {
    const t = await this.jwt.signPurpose('step_up', {
      sub: p.userId,
      ttlSeconds: STEP_UP_TTL_SECONDS,
      claims: {
        sid: p.sessionId,
        deviceId: p.deviceId,
        scope: tokenScope(operation),
        method,
        operation,
        pv: p.permissionsVersion,
      },
    });
    return {
      stepUpToken: t.token,
      expiresAt: t.expiresAt.toISOString(),
      method,
      scope: [permissionForOperation(operation)],
    };
  }

  private async okAudit(
    input: StepUpRequestInput,
    method: StepUpMethodR1,
    tx: Parameters<AuditService['write']>[2],
  ): Promise<void> {
    await this.audit.write(
      input.audit,
      {
        action: 'auth.step_up.ok',
        entityType: 'session',
        entityId: input.principal.sessionId,
        stepUpMethod: method,
        after: { method, operation: input.operation, scope: tokenScope(input.operation) },
      },
      tx,
    );
  }

  private async failedAudit(input: StepUpRequestInput, reason: string): Promise<void> {
    await this.audit
      .write(input.audit, {
        action: 'auth.step_up.failed',
        entityType: 'session',
        entityId: input.principal.sessionId,
        result: 'denied',
        after: { method: input.method, operation: input.operation, reason },
      })
      .catch((err: unknown) => this.logger.error({ event: 'audit.write_failed', err }, 'audit failed'));
  }
}

function validation(field: string, rule: string, message: string): ProblemException {
  return new ProblemException('VALIDATION_FAILED', {
    status: 400,
    detail: 'Запрос не прошёл проверку.',
    errors: [{ field, message, rule }],
  });
}
