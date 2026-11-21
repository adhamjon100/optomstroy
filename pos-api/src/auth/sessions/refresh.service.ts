import { Inject, Injectable, Logger } from '@nestjs/common';
import { type AuditContext, applyAuditGucs, toRbacRole } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { AuthStateCache } from '../../common/auth/auth-state.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { HELLO_CHALLENGE_PREFIX, verifyHelloSignature } from '../../common/auth/hello-key.js';
import type { AmrValue } from '../../common/auth/jwt.service.js';
import { bySubjectKind } from '../../common/auth/subject-kind.js';
import { weakBiometricsAllowedFor, weakReauthDueAt } from '../../common/auth/weak-biometrics.js';
import { generateOpaqueToken, sha256 } from '../../common/crypto/random.js';
import { DRIZZLE, type Database } from '../../common/db/database.module.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { DevicesRepository } from '../../users/devices.repository.js';
import { type HelloKeyRow, HelloKeysRepository } from '../../users/hello-keys.repository.js';
import { SessionsRepository } from '../../users/sessions.repository.js';
import { UserProfilesRepository } from '../../users/user-profiles.repository.js';
import { UserRolesRepository } from '../../users/user-roles.repository.js';
import type { DeviceRow, SessionRow, UserRow } from '../../users/users.types.js';
import { AuthPolicyService } from '../common/auth-policy.js';
import { AppPinsRepository } from '../pin/app-pins.repository.js';
import { type PinCheck, PinVerifier } from '../pin/pin-verifier.service.js';
import { AuthHttpRateLimiter } from '../common/http-rate-limits.js';
import { HELLO_UNLOCK_DETAIL } from './hello-key-challenge.service.js';
import { HelloKeyService, revokeReasonOf } from './hello-key.service.js';
import {
  type RefreshPath,
  RefreshSessionResolver,
  type RefreshUse,
  type SessionRefusal,
  sessionProblem,
} from './refresh-session.resolver.js';
import { contractAmr, firstFactor, nextIdleExpiry, SessionIssuer } from './session-issuer.service.js';
import { SessionStore } from './session-store.js';

export type RotationMode = Exclude<RefreshUse, 'unlock_challenge'>;

export interface RotateInput {
  readonly refreshToken: string;
  readonly deviceKey: string;
  readonly mode: RotationMode;
  readonly pin?: string;
  readonly biometricInvalidated?: boolean;
  /** `method: hello_key` — подпись challenge ключом Windows Hello (base64url; 08 §4.1.8, ADR-116). */
  readonly signature?: string;
  /** `method: pin` — ключ Windows Hello пропал в Windows: после верного PIN ключ устройства отзывается (`invalidated`). */
  readonly helloKeyInvalidated?: boolean;
  readonly ip: string | null;
  readonly audit: AuditContext;
}

export interface TokenPairBody {
  readonly accessToken: string;
  readonly accessExpiresIn: number;
  readonly refreshToken: string;
  readonly refreshExpiresAt: string;
  readonly sid: string;
  readonly permissionsVersion: number;
  readonly amr?: readonly AmrValue[];
}

/** Как найден предъявленный refresh (09 §8.3); `reuse` обрабатывает RefreshSessionResolver (отзыв семьи). */
type Path = Exclude<RefreshPath, 'reuse'>;

type Failure =
  | SessionRefusal
  | { readonly kind: 'unlock_required'; readonly reason?: string }
  | { readonly kind: 'validation'; readonly rule: string; readonly field: string; readonly message: string }
  | { readonly kind: 'pin'; readonly check: Exclude<PinCheck, { kind: 'ok' }> };

type TxResult = { readonly ok: true; readonly body: TokenPairBody } | { readonly ok: false; readonly failure: Failure };

/**
 * Ротация refresh (RM-D-003; 09 §8.3, §8.8; 08 §4.1.3, §4.1.8; RFC 9700 §4.14.2) для `/auth/refresh` и
 * `/auth/unlock`: CAS-ротация; окно грации 30 с (однократно, пока текущий токен не использовался); поздний повтор
 * (`refresh_replay`) — без отзыва семьи: `UNLOCK_REQUIRED` при наличии PIN (разблокировка PIN выдаёт новую
 * ротацию), иначе отзыв только этой сессии; повторное использование (`reuse_detected`) — отзыв всей семьи и аудит;
 * чужой `X-Device-Id` — отзыв сессии (`device_mismatch`); staff на Windows без `unlocked_until > now` →
 * `UNLOCK_REQUIRED` (D-48). Ошибки бросаются после COMMIT (отзыв и счётчики PIN сохраняются). Поиск сессии, отзыв,
 * сроки, устройство, статус и reuse-detection — RefreshSessionResolver, общий с `POST /auth/unlock/challenge`.
 *
 * Уровень W Android (15 ADR-116 п. 2; 08 §4.1.8; 09 BIO-031, BIO-032; 11 SEC-144): семья `kind=biometric` с
 * `weak_reauth_due_at`. `/auth/unlock {method: biometric}` такой семьи после всех проверок refresh и до ротации:
 * `AUTH_BIO_ALLOW_WEAK` не разрешает субъекта → отзыв семьи (`biometric_weak_disabled`) и `401 UNLOCK_REQUIRED
 * {reason: bio_weak_disabled}`; срок прошёл, PIN заблокирован или не задан → `401 UNLOCK_REQUIRED {reason:
 * bio_weak_pin_due}` без ротации и отзыва. Успешная разблокировка PIN продлевает срок живых семей W пользователя на
 * этом устройстве; ротация refresh срок не меняет.
 *
 * Ключ Windows Hello — вариант W2 (15 ADR-116 п. 3, п. 4; 08 §4.1.8, API-197; 09 BIO-039; 11 SEC-146, RR-10):
 * `/auth/unlock {method: hello_key, refreshToken, signature}` — refresh проверяется как при PIN (сроки, устройство,
 * reuse-detection, окно грации, поздний повтор), затем субъект и ключ (`kind` ≠ `kiosk`, `active`, `platform=windows`,
 * живой ключ устройства, `AUTH_WINDOWS_HELLO_KEY` и правило `personal` → `hello_key_unavailable`), challenge этого ключа и
 * этой сессии (есть и не истёк; гасится при любом исходе) и подпись RSASSA-PKCS1-v1_5 SHA-256 (`hello_key_invalid`) →
 * ротация, `amr [sms, bio]`, `unlocked_until`, `hello_keys.last_used_at`. Отказ — `401 UNLOCK_REQUIRED` без ротации и
 * отзыва сессии; лимит — RL-PIN (счётчик неверных PIN не растёт). `method: pin` с `helloKeyInvalidated` после верного
 * PIN отзывает ключ устройства (`invalidated`).
 *
 * Планшет магазина (`kind=kiosk`; 08 §4.1.3 «Сессия планшета магазина»; 09 §8.3, §8.9 п. 3, п. 8; 11 SEC-139;
 * ADR-115): поздний повтор прежнего refresh после потерянного ответа идёт путём грации (ротация в сторону, отметка
 * `grace_used_at`) — один раз на ротацию; второй поздний повтор подряд — `reuse`. Сессия, отозванная с
 * `revoke_reason='kiosk_revoked'`, — `401 KIOSK_REVOKED`. Для `staff` и `customer` правила не меняются.
 */
@Injectable()
export class RefreshService {
  private readonly logger = new Logger('auth');

  constructor(
    @Inject(DRIZZLE) private readonly db: Database,
    @Inject(CLOCK) private readonly clock: Clock,
    private readonly policy: AuthPolicyService,
    private readonly sessions: SessionsRepository,
    private readonly store: SessionStore,
    private readonly refreshSessions: RefreshSessionResolver,
    private readonly roles: UserRolesRepository,
    private readonly devices: DevicesRepository,
    private readonly profiles: UserProfilesRepository,
    private readonly pins: AppPinsRepository,
    private readonly pinVerifier: PinVerifier,
    private readonly issuer: SessionIssuer,
    private readonly cache: AuthStateCache,
    private readonly audit: AuditService,
    private readonly limiter: AuthHttpRateLimiter,
    private readonly keys: HelloKeysRepository,
    private readonly helloKeys: HelloKeyService,
  ) {}

  async rotate(input: RotateInput): Promise<TokenPairBody> {
    const result = await this.db.transaction(async (tx): Promise<TxResult> => {
      await applyAuditGucs(tx, { ...input.audit, system: 'auth' });
      return this.rotateInTx(input, tx);
    });
    if (result.ok) return result.body;
    throw toProblem(result.failure);
  }

  private async rotateInTx(input: RotateInput, tx: DbExecutor): Promise<TxResult> {
    const p = (await this.policy.effective()).session;
    const now = this.clock.now();
    // Поиск сессии, отзыв, сроки (`expired`), устройство (`device_mismatch`), статус и reuse-detection — общие с
    // `POST /auth/unlock/challenge` (RefreshSessionResolver; 08 §4.1.10).
    const found = await this.refreshSessions.resolve(
      { refreshToken: input.refreshToken, deviceKey: input.deviceKey, use: input.mode, audit: input.audit },
      p,
      now,
      tx,
    );
    if (!found.ok) return fail(found.failure);
    const { s, user, device, ctx } = found;
    let path: Path = found.path;
    // Планшет магазина: потерянный ответ `/auth/refresh` (P-002 §8.2 п. 5; 09 §8.9 п. 3) — поздний повтор прежнего
    // токена при неиспользованном новом (`last_used_at IS NULL`) и непотраченной грации (`grace_used_at IS NULL`,
    // иначе `classifyPrevious` уже дал `reuse`) идёт путём грации: `rotateAside` ставит `grace_used_at`, поэтому
    // второй поздний повтор подряд — `reuse_detected`. Сроки, устройство и статус проверены выше. `refresh_replay`
    // у планшета не возникает; staff и customer — прежние ветки (UNLOCK_REQUIRED / refresh_replay).
    if (
      path === 'replay' &&
      input.mode === 'refresh' &&
      bySubjectKind(user.kind, { staff: false, customer: false, kiosk: true })
    ) {
      path = 'grace';
      this.logger.warn({ event: 'auth.refresh.kiosk_late_grace', sid: s.id }, 'auth.refresh.kiosk_late_grace');
    }

    // Вид токена ↔ эндпоинт (08 §4.1.3, §4.1.8; ядро §19.3).
    if (input.mode === 'refresh' && s.kind === 'biometric') {
      return fail({
        kind: 'validation',
        rule: 'use_unlock',
        field: 'refreshToken',
        message: 'Используйте POST /auth/unlock',
      });
    }
    // Ключ Windows Hello — только со стандартным refresh (08 §4.1.8): иначе `hello_key_unavailable`, без отзыва.
    if (input.mode === 'unlock_hello_key' && s.kind !== 'standard') {
      return fail(await this.helloDenied(s, ctx, tx, 'hello_key_unavailable'));
    }
    if (input.mode === 'unlock_biometric' && (s.kind !== 'biometric' || device.platform === 'windows')) {
      return fail({
        kind: 'validation',
        rule: 'method',
        field: 'method',
        message: 'Биометрическая разблокировка недоступна',
      });
    }

    const pinSet = await this.pins.exists(user.id, tx);
    // Поздний повтор с PIN или подписью ключа Windows Hello — разблокировка «вбок» (второй фактор проверяется ниже).
    if (path === 'replay' && input.mode !== 'unlock_pin' && input.mode !== 'unlock_hello_key') {
      this.logger.warn({ event: 'auth.refresh.replay', sid: s.id, mode: input.mode }, 'auth.refresh.replay');
      if (input.mode === 'refresh' && pinSet && s.kind === 'standard') {
        return fail({ kind: 'unlock_required', reason: 'refresh_replay' });
      }
      // Без PIN (customer) или биометрическая семья: отзыв только этой сессии, без алерта (09 §8.3);
      // `revoke_reason = refresh_replay` — миграция 0003 (09 §17 п. 19(а); DQ-03 / auth A-08).
      await this.refreshSessions.revoke(s, 'refresh_replay', ctx, tx, false);
      return fail({ kind: 'revoked', reason: 'refresh_replay' });
    }

    const windowsStaff = user.kind === 'staff' && device.platform === 'windows';
    if (
      input.mode === 'refresh' &&
      windowsStaff &&
      (s.unlockedUntil === null || s.unlockedUntil.getTime() <= now.getTime())
    ) {
      return fail({ kind: 'unlock_required', reason: 'idle_lock' });
    }

    // Уровень W (ADR-116; 08 §4.1.8 «Порядок для biometric уровня W»: refresh → переменная → срок и PIN → ротация).
    const weak = input.mode === 'unlock_biometric' && s.weakReauthDueAt !== null;
    if (weak) {
      const refused = await this.refuseWeak(s, user, device, now, ctx, tx);
      if (refused) return fail(refused);
    }

    // Ключ Windows Hello (08 §4.1.8 «Порядок проверок hello_key»: refresh → субъект и ключ → challenge → подпись).
    let helloKey: HelloKeyRow | undefined;
    if (input.mode === 'unlock_hello_key') {
      const checked = await this.checkHelloKey(s, user, device, input, now, ctx, tx);
      if (!checked.ok) return fail(checked.failure);
      helloKey = checked.key;
    }

    // Первый фактор — из `sessions.amr` (`admin_code` у входа по аварийному коду, 09 §6.13 п. 3; миграция 0003).
    let stored = [...s.amr] as AmrValue[];
    if (input.mode === 'unlock_pin') {
      if (input.pin === undefined) {
        return fail({ kind: 'validation', rule: 'required', field: 'pin', message: 'PIN обязателен' });
      }
      // RL-PIN (08 §2.9): 30 попыток / 10 мин на `userId + deviceId` — тот же ключ, что у step-up по PIN.
      await this.limiter.pin(user.id, input.deviceKey);
      const check = await this.pinVerifier.verify(user.id, input.pin, tx);
      if (check.kind !== 'ok') {
        await this.audit.write(
          ctx,
          {
            action: check.kind === 'locked_now' ? 'auth.pin.locked' : 'auth.unlock',
            entityType: 'session',
            entityId: s.id,
            result: 'denied',
            ...(check.kind === 'locked_now' ? { severity: 'warning' as const } : {}),
            after: { method: 'pin', reason: check.kind },
          },
          tx,
        );
        return fail({ kind: 'pin', check });
      }
      stored = [firstFactor(stored), 'pin'];
      if (input.biometricInvalidated === true) await this.invalidateBiometrics(user, device, ctx, tx);
      // Ключ Windows Hello пропал в Windows (`KeyCredentialStatus.NotFound`; 09 §9.2 W2 п. 4): отзыв ключа устройства.
      if (input.helloKeyInvalidated === true) {
        await this.helloKeys.revoke({ userId: user.id, deviceId: device.id }, 'invalidated', ctx, tx);
      }
    } else if (input.mode === 'unlock_biometric' || input.mode === 'unlock_hello_key') {
      stored = [firstFactor(stored), 'bio'];
    }
    const amr = stored;

    const refreshToken = generateOpaqueToken();
    const unlock = input.mode !== 'refresh';
    const patch = {
      newRefreshHash: sha256(refreshToken),
      now,
      idleExpiresAt: nextIdleExpiry(s, user.kind, p, now),
      ...(unlock ? { unlockedUntil: new Date(now.getTime() + p.idleLockMinutes * 60_000) } : {}),
      ...(unlock ? { amr: stored } : {}),
      ip: input.ip,
    };
    const rotated =
      path === 'current'
        ? await this.store.rotate(s.id, sha256(input.refreshToken), patch, tx)
        : await this.store.rotateAside(s.id, patch, tx);
    if (!rotated) return fail({ kind: 'revoked' });
    if (input.mode === 'refresh' && windowsStaff) {
      // 09 §8.8: активность продлевает разблокировку — успешный refresh в пределах unlocked_until тоже.
      await this.store.touchActivity(rotated.id, now, p.idleLockMinutes, input.ip, tx);
    }
    if (input.mode === 'unlock_pin') {
      // Уровень W (08 §4.1.8 «Срок уровня W»): PIN на этом устройстве продлевает срок разблокировки лицом.
      await this.sessions.extendWeakReauth(
        user.id,
        device.id,
        weakReauthDueAt(now, this.policy.config.AUTH_BIO_WEAK_REAUTH_HOURS),
        tx,
      );
    }
    if (helloKey) await this.keys.markUsed(helloKey.id, now, tx);
    const roles = await this.roles.activeRoleCodes(user.id, tx);
    const access = await this.issuer.access(user, roles, rotated, input.deviceKey, amr);
    if (unlock) {
      await this.audit.write(
        { ...ctx, actorRole: toRbacRole(roles[0]) },
        {
          action: 'auth.unlock',
          entityType: 'session',
          entityId: s.id,
          after: {
            method: unlockMethod(input.mode),
            path,
            // 11 §7.2.1, 08 §4.1.8: уровень биометрии — strong (S, Class 3) или weak (W, Class 2; ADR-116).
            ...(input.mode === 'unlock_biometric' ? { bioStrength: weak ? 'weak' : 'strong' } : {}),
            // Ключ Windows Hello — только источник (без подписи, challenge и ключа; 11 §7.2.1, SEC-146).
            ...(helloKey ? { keySource: helloKey.source } : {}),
          },
        },
        tx,
      );
    } else {
      this.logger.log({ event: 'auth.refresh', sid: s.id, path }, 'auth.refresh');
    }
    return {
      ok: true,
      body: {
        accessToken: access.token,
        accessExpiresIn: this.issuer.accessTtlSeconds,
        refreshToken,
        refreshExpiresAt: rotated.expiresAt.toISOString(),
        sid: rotated.id,
        permissionsVersion: user.permissionsVersion,
        // Схема ответа (contracts/openapi AuthTokenPair.amr): только sms|bio|pin — `admin_code` не выводится.
        ...(unlock ? { amr: contractAmr(amr) } : {}),
      },
    };
  }

  /**
   * Уровень W: отказ разблокировки лицом (ADR-116; 08 §2.4 «Причины `UNLOCK_REQUIRED` входа по лицу»; 09 BIO-031,
   * BIO-032). `undefined` — разблокировка разрешена. Запрет переменной проверяется раньше срока: семья W отзывается
   * (`biometric_weak_disabled`), семьи уровня S и стандартная сессия не затрагиваются. Срок прошёл, PIN заблокирован
   * или не задан → `bio_weak_pin_due`: без ротации и отзыва, секрет на устройстве сохраняется.
   */
  private async refuseWeak(
    s: SessionRow,
    user: UserRow,
    device: DeviceRow,
    now: Date,
    ctx: AuditContext,
    tx: DbExecutor,
  ): Promise<Failure | undefined> {
    if (!weakBiometricsAllowedFor(this.policy.config.AUTH_BIO_ALLOW_WEAK, user.kind)) {
      const ids = await this.sessions.revokeFamily(s.familyId, 'biometric_weak_disabled', tx);
      for (const id of ids) this.cache.invalidateSession(id);
      const live = await this.store.listActiveWithDevices(user.id, now, tx);
      const bio = live.filter((r) => r.session.kind === 'biometric');
      if (!bio.some((r) => r.device.id === device.id)) await this.devices.setBiometricEnrolled(device.id, null, tx);
      if (bio.length === 0) await this.profiles.setBiometricsEnabled(user.id, false, tx);
      await this.audit.write(
        ctx,
        {
          action: 'auth.biometrics.disabled',
          entityType: 'device',
          entityId: device.id,
          after: { reason: 'biometric_weak_disabled', bioStrength: 'weak', revokedSessions: ids.length },
        },
        tx,
      );
      this.logger.warn({ event: 'auth.unlock.bio_weak_disabled', sid: s.id }, 'auth.unlock.bio_weak_disabled');
      return { kind: 'unlock_required', reason: 'bio_weak_disabled' };
    }
    const pin = await this.pins.find(user.id, tx);
    const lockedUntil = pin?.lockedUntil ?? null;
    const pinLocked = lockedUntil !== null && lockedUntil.getTime() > now.getTime();
    const due = s.weakReauthDueAt !== null && s.weakReauthDueAt.getTime() <= now.getTime();
    if (pin === undefined || pinLocked || due) {
      await this.audit.write(
        ctx,
        {
          action: 'auth.unlock',
          entityType: 'session',
          entityId: s.id,
          result: 'denied',
          after: { method: 'biometric', bioStrength: 'weak', reason: 'bio_weak_pin_due' },
        },
        tx,
      );
      return { kind: 'unlock_required', reason: 'bio_weak_pin_due' };
    }
    return undefined;
  }

  /**
   * Ключ Windows Hello (08 §4.1.8, API-197; 11 SEC-146): после проверок refresh. RL-PIN — на каждую попытку (общий
   * лимит с PIN и challenge, счётчик неверных PIN не меняется). Субъект и ключ → `hello_key_unavailable` (при `off` и
   * нарушении `personal` ключ отзывается — `policy_off`, `shared_device`); challenge гасится сразу после блокировки строки
   * ключа — при любом исходе; нет challenge, чужая сессия, истёк, неверная подпись → `hello_key_invalid`.
   */
  private async checkHelloKey(
    s: SessionRow,
    user: UserRow,
    device: DeviceRow,
    input: RotateInput,
    now: Date,
    ctx: AuditContext,
    tx: DbExecutor,
  ): Promise<{ readonly ok: true; readonly key: HelloKeyRow } | { readonly ok: false; readonly failure: Failure }> {
    await this.limiter.pin(user.id, input.deviceKey);
    const denied = async (reason: HelloReason, key?: HelloKeyRow) => ({
      ok: false as const,
      failure: await this.helloDenied(s, ctx, tx, reason, key),
    });
    // Планшет магазина ключа не получает ни в каком виде (09 BIO-037); пользователь — только `active` (08 §4.1.10).
    const kiosk = bySubjectKind(user.kind, { staff: false, customer: false, kiosk: true });
    if (kiosk || user.status !== 'active' || device.platform !== 'windows') return denied('hello_key_unavailable');
    const key = await this.keys.findLiveByDevice(device.id, tx, true);
    if (!key || key.userId !== user.id) return denied('hello_key_unavailable');
    const challenge = key.challenge;
    const challengeSessionId = key.challengeSessionId;
    const challengeExpiresAt = key.challengeExpiresAt;
    if (challenge !== null) await this.keys.clearChallenge(key.id, tx);
    const refusal = await this.helloKeys.refusal(user, device.deviceKey, tx);
    if (refusal !== undefined) {
      await this.helloKeys.revoke({ deviceId: device.id }, revokeReasonOf(refusal), ctx, tx);
      return denied('hello_key_unavailable', key);
    }
    const valid =
      challenge !== null &&
      challengeSessionId === s.id &&
      challengeExpiresAt !== null &&
      challengeExpiresAt.getTime() > now.getTime() &&
      input.signature !== undefined &&
      verifyHelloSignature(
        key.publicKey,
        `${HELLO_CHALLENGE_PREFIX}${challenge.toString('base64url')}`,
        input.signature,
      );
    if (!valid) return denied('hello_key_invalid', key);
    return { ok: true, key };
  }

  /** Отказ входа ключом Windows Hello: аудит `auth.unlock` (denied, без подписи и challenge) и причина ответа. */
  private async helloDenied(
    s: SessionRow,
    ctx: AuditContext,
    tx: DbExecutor,
    reason: HelloReason,
    key?: HelloKeyRow,
  ): Promise<Failure> {
    await this.audit.write(
      ctx,
      {
        action: 'auth.unlock',
        entityType: 'session',
        entityId: s.id,
        result: 'denied',
        after: { method: 'hello_key', reason, ...(key ? { keySource: key.source } : {}) },
      },
      tx,
    );
    this.logger.warn({ event: 'auth.unlock.hello_key_denied', sid: s.id, reason }, 'auth.unlock.hello_key_denied');
    return { kind: 'unlock_required', reason };
  }

  /** `biometricInvalidated=true` (08 §4.1.8; ядро §18.2 п. 8, §21 п. 2(в)): отзыв биометрической семьи устройства. */
  private async invalidateBiometrics(
    user: UserRow,
    device: DeviceRow,
    ctx: AuditContext,
    tx: DbExecutor,
  ): Promise<void> {
    const ids = await this.sessions.revokeAllForUser(
      user.id,
      'biometric_invalidated',
      { kind: 'biometric', deviceId: device.id },
      tx,
    );
    for (const id of ids) this.cache.invalidateSession(id);
    await this.devices.setBiometricEnrolled(device.id, null, tx);
    const others = await this.store.listActiveWithDevices(user.id, this.clock.now(), tx);
    if (!others.some((r) => r.session.kind === 'biometric'))
      await this.profiles.setBiometricsEnabled(user.id, false, tx);
    await this.audit.write(
      ctx,
      {
        action: 'auth.biometrics.disabled',
        entityType: 'device',
        entityId: device.id,
        after: { reason: 'biometric_invalidated', revokedSessions: ids.length },
      },
      tx,
    );
  }
}

type HelloReason = keyof typeof HELLO_UNLOCK_DETAIL;

/**
 * Тексты причин входа по лицу — 02 §7 `unlock_bio_pin_due`, `unlock_bio_weak_disabled`, `unlock_hello_key_unavailable`,
 * `unlock_hello_failed` (ADR-116).
 */
const UNLOCK_DETAIL: Readonly<Record<string, string>> = {
  bio_weak_pin_due: 'Пора ввести PIN. Введите PIN.',
  bio_weak_disabled: 'Вход по лицу выключен. Введите PIN.',
  ...HELLO_UNLOCK_DETAIL,
};

/** Метод разблокировки в аудите `auth.unlock` (11 §7.2.1): `pin` | `biometric` | `hello_key`. */
function unlockMethod(mode: RotationMode): 'pin' | 'biometric' | 'hello_key' | 'refresh' {
  switch (mode) {
    case 'unlock_pin':
      return 'pin';
    case 'unlock_biometric':
      return 'biometric';
    case 'unlock_hello_key':
      return 'hello_key';
    case 'refresh':
      return 'refresh';
  }
}

function fail(failure: Failure): TxResult {
  return { ok: false, failure };
}

function toProblem(f: Failure): ProblemException {
  switch (f.kind) {
    case 'revoked':
    case 'kiosk_revoked':
      return sessionProblem(f);
    case 'unlock_required':
      return new ProblemException('UNLOCK_REQUIRED', {
        detail: UNLOCK_DETAIL[f.reason ?? ''] ?? 'Разблокируйте приложение PIN-кодом.',
        ...(f.reason ? { reason: f.reason } : {}),
      });
    case 'validation':
      return new ProblemException('VALIDATION_FAILED', {
        status: 400,
        detail: 'Запрос не прошёл проверку.',
        errors: [{ field: f.field, message: f.message, rule: f.rule }],
      });
    case 'pin':
      return PinVerifier.toProblem(f.check);
  }
}
