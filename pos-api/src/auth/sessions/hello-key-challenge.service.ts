import { randomBytes } from 'node:crypto';
import { Inject, Injectable, Logger } from '@nestjs/common';
import { type AuditContext, applyAuditGucs } from '../../common/audit/audit-context.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { bySubjectKind } from '../../common/auth/subject-kind.js';
import { HELLO_CHALLENGE_BYTES, HELLO_CHALLENGE_TTL_MS, helloChallengeString } from '../../common/auth/hello-key.js';
import { DRIZZLE, type Database } from '../../common/db/database.module.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { HelloKeysRepository } from '../../users/hello-keys.repository.js';
import { AuthPolicyService } from '../common/auth-policy.js';
import { AuthHttpRateLimiter } from '../common/http-rate-limits.js';
import { HelloKeyService, revokeReasonOf } from './hello-key.service.js';
import { RefreshSessionResolver, type SessionRefusal, sessionProblem } from './refresh-session.resolver.js';

/** Ответ `POST /auth/unlock/challenge` (OpenAPI `AuthUnlockChallengeResponse`). */
export interface HelloChallengeBody {
  readonly challenge: string;
  readonly expiresAt: string;
}

export interface HelloChallengeInput {
  readonly refreshToken: string;
  readonly deviceKey: string;
  readonly audit: AuditContext;
}

/** Тексты причин — 02 §7 `unlock_hello_key_unavailable`, `unlock_hello_failed` (ADR-116). */
export const HELLO_UNLOCK_DETAIL = {
  hello_key_unavailable: 'Вход через Windows Hello выключен на этом компьютере. Введите PIN.',
  hello_key_invalid: 'Windows Hello не подтвердил вход. Введите PIN.',
} as const;

/**
 * `401 UNLOCK_REQUIRED {reason: hello_key_unavailable}` — одинаковое тело для любого отказа по ключу, субъекту и
 * переменной (отказы по самой сессии — `SESSION_REVOKED` / `KIOSK_REVOKED`, как у `POST /auth/unlock`).
 */
export function helloKeyUnavailable(): ProblemException {
  return new ProblemException('UNLOCK_REQUIRED', {
    detail: HELLO_UNLOCK_DETAIL.hello_key_unavailable,
    reason: 'hello_key_unavailable',
  });
}

/** Отказ: `session` — по самой сессии (`sessionProblem`), без него — `hello_key_unavailable`. */
type Outcome =
  { readonly ok: true; readonly body: HelloChallengeBody } | { readonly ok: false; readonly session?: SessionRefusal };

/**
 * `POST /auth/unlock/challenge {method: hello_key, refreshToken}` (08 §4.1.10, API-196; 09 BIO-039; 11 SEC-146):
 * одноразовый challenge `optomstroy-hello-unlock/v1:` + 32 байта CSPRNG на 120 с для подписи ключом Windows Hello.
 * Refresh не ротируется. Сессия проверяется так же, как в `POST /auth/unlock` (RefreshSessionResolver; доработка
 * 2026-11-18 `[ВЫВОД исполнителя]` по 09 BIO-040: отказ по сессии не должен выглядеть как отзыв ключа, иначе приложение
 * удаляет ключ в Windows): неизвестный или отозванный refresh → `401 SESSION_REVOKED` (`KIOSK_REVOKED` для
 * `kiosk_revoked`); сроки вышли → отзыв `expired`, чужой `X-Device-Id` → отзыв `device_mismatch`, пользователь
 * заблокирован → `blocked`, вытесненный refresh → reuse-detection (`reuse_detected`) — всё `401 SESSION_REVOKED` с
 * `reason`; прежний refresh в окне грации или поздний повтор — challenge выдаётся этой же сессии (разблокировка
 * `hello_key` примет тот же refresh «вбок», как PIN). Затем субъект и ключ: `kind=standard`, `platform=windows`,
 * пользователь `active`, не планшет, живой ключ пользователя и устройства, `AUTH_WINDOWS_HELLO_KEY` ≠ `off` и правило
 * `personal` — иначе одинаковый `401 UNLOCK_REQUIRED {reason: hello_key_unavailable}` без ротации и отзыва сессии.
 * При `off` живой ключ отзывается (`policy_off`), при нарушении `personal` — `shared_device` (отзыв — до COMMIT, ответ
 * — после). Challenge хранится у ключа (07 §5.66): новый заменяет прежний. Лимит — RL-PIN (`userId + deviceKey`, общий
 * с `POST /auth/unlock`); выдача не аудируется (доступа не даёт).
 */
@Injectable()
export class HelloKeyChallengeService {
  private readonly logger = new Logger('auth');

  constructor(
    @Inject(DRIZZLE) private readonly db: Database,
    @Inject(CLOCK) private readonly clock: Clock,
    private readonly policy: AuthPolicyService,
    private readonly refreshSessions: RefreshSessionResolver,
    private readonly keys: HelloKeysRepository,
    private readonly helloKeys: HelloKeyService,
    private readonly limiter: AuthHttpRateLimiter,
  ) {}

  async issue(input: HelloChallengeInput): Promise<HelloChallengeBody> {
    const outcome = await this.db.transaction(async (tx): Promise<Outcome> => {
      await applyAuditGucs(tx, { ...input.audit, system: 'auth' });
      return this.issueInTx(input, tx);
    });
    if (outcome.ok) return outcome.body;
    throw outcome.session ? sessionProblem(outcome.session) : helloKeyUnavailable();
  }

  private async issueInTx(input: HelloChallengeInput, tx: DbExecutor): Promise<Outcome> {
    const refused: Outcome = { ok: false };
    const p = (await this.policy.effective()).session;
    const now = this.clock.now();
    const found = await this.refreshSessions.resolve(
      { refreshToken: input.refreshToken, deviceKey: input.deviceKey, use: 'unlock_challenge', audit: input.audit },
      p,
      now,
      tx,
    );
    if (!found.ok) return { ok: false, session: found.failure };
    // Путь `grace` и `replay` (прежний refresh) — challenge той же сессии: `/auth/unlock {hello_key}` ротирует «вбок».
    const { s, user, device } = found;
    if (s.kind !== 'standard' || device.platform !== 'windows' || user.status !== 'active') return refused;
    // Планшет магазина ключа не получает ни в каком виде (09 BIO-037): отказ без отзыва и без лимита.
    if (bySubjectKind(user.kind, { staff: false, customer: false, kiosk: true })) return refused;
    // RL-PIN (08 §2.9, §4.1.10): общий лимит 30 / 10 мин с POST /auth/unlock на `userId + deviceKey`.
    await this.limiter.pin(user.id, input.deviceKey);
    const key = await this.keys.findLiveByDevice(device.id, tx, true);
    if (!key || key.userId !== user.id) return refused;
    const ctx: AuditContext = { ...input.audit, actorUserId: user.id, sessionId: s.id, system: 'auth' };
    const refusal = await this.helloKeys.refusal(user, device.deviceKey, tx);
    if (refusal !== undefined) {
      await this.helloKeys.revoke({ deviceId: device.id }, revokeReasonOf(refusal), ctx, tx);
      this.logger.warn({ event: 'auth.unlock_challenge.key_revoked', sid: s.id, refusal }, 'hello_key revoked');
      return refused;
    }
    const bytes = randomBytes(HELLO_CHALLENGE_BYTES);
    const expiresAt = new Date(now.getTime() + HELLO_CHALLENGE_TTL_MS);
    if (!(await this.keys.setChallenge(key.id, bytes, s.id, expiresAt, tx))) return refused;
    return { ok: true, body: { challenge: helloChallengeString(bytes), expiresAt: expiresAt.toISOString() } };
  }
}
