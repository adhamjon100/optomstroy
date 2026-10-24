import { Inject, Injectable, Logger, Optional } from '@nestjs/common';
import { and, eq, gt } from 'drizzle-orm';
import { type ConsumedRegistrationToken, RegistrationTokenService } from '../auth/login/registration-token.service.js';
import { SessionIssuer } from '../auth/sessions/session-issuer.service.js';
import { SessionStore } from '../auth/sessions/session-store.js';
import { AuthStateCache } from '../common/auth/auth-state.js';
import { applyAuditGucs, type AuditContext } from '../common/audit/audit-context.js';
import { AuditService } from '../common/audit/audit.service.js';
import type { DbExecutor } from '../common/audit/db-executor.js';
import { CLOCK, type Clock } from '../common/auth/clock.js';
import type { IssuedToken } from '../common/auth/jwt.service.js';
import { APP_CONFIG, type AppConfig } from '../common/config/app-config.js';
import { PinHasher, type PinHashResult } from '../common/crypto/pin-hasher.service.js';
import { generateOpaqueToken, sha256 } from '../common/crypto/random.js';
import { DRIZZLE } from '../common/db/database.module.js';
import type { ConsentKind } from '../common/enums.js';
import { routeKey } from '../common/http/route-template.js';
import { requestFingerprint } from '../common/idempotency/fingerprint.js';
import { IdempotencyService } from '../common/idempotency/idempotency.service.js';
import type { IdempotencyScope } from '../common/idempotency/idempotency.store.js';
import { ReplayedResponseException } from '../common/idempotency/replayed-response.exception.js';
import { newId } from '../common/ids/uuid.js';
import { ProblemException, type ProblemFieldError } from '../common/problem-details/problem.exception.js';
import type { PosDatabase } from '../db/database.js';
import { sessions as sessionsTable, userInvitations, users as usersTable } from '../db/schema/index.js';
import { consentEntry, isCurrentConsentVersion } from '../profile/consents/consent-catalog.js';
import { type ConsentChange, ConsentsService } from '../profile/consents/consents.service.js';
import { CustomerLinkReader } from '../profile/customer-link.reader.js';
import {
  activitySphereErrors,
  birthYearErrors,
  fullNameErrors,
  loginProtectionRequired,
  normalizeFullName,
  pinErrors,
  pinMinLength,
  throwIfErrors,
} from '../profile/domain/profile-rules.js';
import { type MeDto, MeService } from '../profile/me/me.service.js';
import { AppPinWriter } from '../profile/pin/app-pin.writer.js';
import { DevicesRepository } from '../users/devices.repository.js';
import { SessionsRepository } from '../users/sessions.repository.js';
import { TokenDenylistRepository } from '../users/token-denylist.repository.js';
import { UserProfilesRepository } from '../users/user-profiles.repository.js';
import { UserRolesRepository } from '../users/user-roles.repository.js';
import { UsersRepository } from '../users/users.repository.js';
import type { RoleCode, SessionRow, UserRow } from '../users/users.types.js';
import {
  CUSTOMER_MATCHING_PORT,
  type CustomerMatchingPort,
  type CustomerMatchSummary,
  NO_MATCH,
  summaryOf,
} from './ports/customer-matching.port.js';
import type { RegistrationCompleteRequest } from './registration.dto.js';

export const REGISTRATION_ROUTE = routeKey('POST', '/registration/complete');

/** contracts/openapi `RegistrationCompleteAuthenticated` (= `AuthAuthenticated` + `customerMatch`). */
export interface RegistrationAuthenticatedResponse {
  readonly status: 'authenticated';
  readonly accessToken: string;
  readonly accessExpiresIn: number;
  readonly refreshToken: string;
  readonly refreshExpiresAt: string;
  readonly tokenType: 'Bearer';
  readonly sid: string;
  readonly user: MeDto;
  readonly biometricRefreshOffered: boolean;
  readonly roleSource?: 'invitation';
  readonly nextStep: 'set_pin' | 'none';
  readonly customerMatch?: CustomerMatchSummary;
}

/** contracts/openapi `AuthPendingActivation` (только при `CUSTOMER_SELF_SERVICE=false`). */
export interface RegistrationPendingResponse {
  readonly status: 'pending_activation';
  readonly accessToken: string;
  readonly refreshToken: string;
  readonly user: MeDto;
}

export type RegistrationResponse = RegistrationAuthenticatedResponse | RegistrationPendingResponse;

/**
 * Итог в `idempotency_keys.response_body` — **без токенов** (07 §5.56): повтор с тем же ключом выдаёт новую пару
 * токенов для сессии первого вызова на том же устройстве (B-AR-01; contracts/openapi NOTES §8).
 */
interface StoredRegistration {
  readonly status: 'authenticated' | 'pending_activation';
  readonly userId: string;
  readonly sessionId: string;
  readonly roleSource?: 'invitation';
  readonly biometricRefreshOffered: boolean;
  /**
   * `jti` и срок access-токена первого ответа (идентификатор, не сам токен): при повторе он попадает в
   * `token_denylist` (как при повторе verify, 09 §5.6; ревью D-MN-02).
   */
  readonly accessJti?: string;
  readonly accessExpiresAt?: string;
}

interface Registered {
  readonly stored: StoredRegistration;
  readonly refreshToken: string;
  readonly access: IssuedToken;
}

export interface RegistrationRequestMeta {
  /** `X-Device-Id` (UUID v4, нижний регистр). */
  readonly deviceKey: string;
  /** `Idempotency-Key` (UUID v4, обязателен). */
  readonly idempotencyKey: string;
  readonly ctx: AuditContext;
  readonly userAgent: string | null;
}

type Branch =
  | { readonly kind: 'customer'; readonly status: 'active' }
  | { readonly kind: 'staff'; readonly status: 'pending_activation' }
  | {
      readonly kind: 'staff';
      readonly status: 'active';
      readonly invitationId: string;
      readonly role: RoleCode;
      readonly invitedBy: string;
    };

const PG_UNIQUE_VIOLATION = '23505';

function isUniqueViolation(e: unknown): boolean {
  const cause = (e as { cause?: { code?: unknown } } | null)?.cause;
  return (e as { code?: unknown } | null)?.code === PG_UNIQUE_VIOLATION || cause?.code === PG_UNIQUE_VIOLATION;
}

function phoneTaken(): ProblemException {
  return new ProblemException('PHONE_ALREADY_REGISTERED', { detail: 'Номер уже зарегистрирован — войдите.' });
}

/**
 * `POST /registration/complete` (08 §4.2.1; 09 §7.1–§7.6; ядро §19.3, §24.2; RM-D-004, RM-D-014, RM-D-017).
 *
 * Роль по D-07 (ред. ядра §24.2): действующее приглашение (появилось после выдачи токена — защитная ветвь) → `staff`
 * с ролью приглашения; иначе `CUSTOMER_SELF_SERVICE=true` → `customer` `active`; `false` → `staff` без ролей
 * `pending_activation`. Защита входа: `staff` — PIN обязателен (D-48), `customer` — PIN или биометрия с
 * криптопривязкой (Android class3 / iOS). Согласия — с версией и хэшем текста; `sms` при регистрации не
 * записывается (09 §7.3). `registration_token` проверяет и гасит (`token_denylist`) RegistrationTokenService модуля
 * auth в той же транзакции; сессию и токены выпускает SessionIssuer модуля auth. Привязка к карточке 1С — порт
 * модуля `customers` после фиксации. Идемпотентность — скоуп `reg:<sha256(jti)>` (B-AR-01).
 */
@Injectable()
export class RegistrationService {
  private readonly logger = new Logger('registration');

  constructor(
    @Inject(DRIZZLE) private readonly db: PosDatabase,
    @Inject(CLOCK) private readonly clock: Clock,
    @Inject(APP_CONFIG) private readonly config: AppConfig,
    private readonly regTokens: RegistrationTokenService,
    private readonly issuer: SessionIssuer,
    private readonly hasher: PinHasher,
    private readonly idempotency: IdempotencyService,
    private readonly users: UsersRepository,
    private readonly roles: UserRolesRepository,
    private readonly profiles: UserProfilesRepository,
    private readonly devices: DevicesRepository,
    private readonly sessions: SessionsRepository,
    private readonly pins: AppPinWriter,
    private readonly consents: ConsentsService,
    private readonly me: MeService,
    private readonly links: CustomerLinkReader,
    private readonly audit: AuditService,
    private readonly store: SessionStore,
    private readonly denylist: TokenDenylistRepository,
    private readonly authState: AuthStateCache,
    @Optional() @Inject(CUSTOMER_MATCHING_PORT) private readonly matching?: CustomerMatchingPort,
  ) {}

  async complete(body: RegistrationCompleteRequest, meta: RegistrationRequestMeta): Promise<RegistrationResponse> {
    // Проверка без погашения: подпись, срок, тип, устройство, челлендж и хэш (401 REGISTRATION_TOKEN_INVALID).
    const token = await this.regTokens.inspect(body.registrationToken, { deviceKey: meta.deviceKey }, this.db);
    const scope: IdempotencyScope = {
      key: meta.idempotencyKey,
      subjectKey: `reg:${sha256(token.jti).toString('hex')}`,
      userId: null,
      route: REGISTRATION_ROUTE,
    };
    const begin = await this.idempotency.begin(scope, requestFingerprint({}, body));
    if (begin.kind === 'replay') {
      throw new ReplayedResponseException(begin.status, await this.replay(begin.status, begin.body, meta));
    }

    let done: Registered;
    try {
      this.validateFields(body);
      done = await this.register(body, meta, token);
    } catch (e) {
      // Побочный эффект не зафиксирован (транзакция откатилась) — ключ освобождается, повтор выполнится заново.
      await this.idempotency.release(scope).catch((err: unknown) => this.logger.warn({ err }, 'release failed'));
      throw e;
    }
    await this.storeOutcome(scope, done.stored, meta.ctx.requestId ?? null);
    const customerMatch =
      done.stored.status === 'authenticated' && done.stored.roleSource === undefined
        ? await this.matchCustomer(done.stored.userId, token.phoneE164, meta.ctx.requestId ?? null)
        : undefined;
    const session = await this.sessions.findById(done.stored.sessionId);
    if (!session) throw new Error('registration: сессия не найдена после фиксации');
    return this.respond(
      done.stored,
      session,
      meta.deviceKey,
      { refreshToken: done.refreshToken, access: done.access },
      customerMatch,
    );
  }

  private validateFields(body: RegistrationCompleteRequest): void {
    const errors: ProblemFieldError[] = [
      ...fullNameErrors(body.fullName),
      ...birthYearErrors(body.birthYear, this.clock.now()),
      ...activitySphereErrors(body.activitySphere),
    ];
    const seen = new Set<string>();
    body.consents.forEach((c, i) => {
      if (!consentEntry(c.kind)) {
        errors.push({ field: `consents[${i}].kind`, message: 'Вид согласия недоступен в R1', rule: 'consent_kind' });
      }
      if (seen.has(c.kind)) {
        errors.push({ field: `consents[${i}].kind`, message: 'Вид согласия повторяется', rule: 'consent_duplicate' });
      }
      seen.add(c.kind);
    });
    throwIfErrors(errors);

    const kinds = new Map(body.consents.map((c) => [c.kind, c.version] as const));
    const missing = (kind: ConsentKind, detail: string): ProblemException =>
      new ProblemException('CONSENT_REQUIRED', {
        detail,
        reason: kind,
        errors: [{ field: 'consents', message: detail, rule: kind }],
      });
    const pd = kinds.get('personal_data');
    if (pd === undefined || !isCurrentConsentVersion('personal_data', pd)) {
      throw missing('personal_data', 'Отметьте «Я ознакомлен(а)» с актуальной версией текста.');
    }
    if (body.security.biometricsEnabled === true) {
      const v = kinds.get('biometrics_device');
      if (v === undefined || !isCurrentConsentVersion('biometrics_device', v)) {
        throw missing('biometrics_device', 'Нужно согласие на вход по биометрии устройства.');
      }
    }
    if (body.activitySphere !== undefined && body.activitySphere !== null) {
      const v = kinds.get('activity_sphere');
      if (v === undefined || !isCurrentConsentVersion('activity_sphere', v)) {
        throw missing('activity_sphere', 'Сфера деятельности передаётся только с согласием.');
      }
    }
    // Версии остальных переданных видов (sms, activity_sphere без поля) — тоже только действующие (02 UI-03-014).
    for (const [kind, version] of kinds) {
      if (!isCurrentConsentVersion(kind, version)) {
        throw missing(kind, 'Версия текста согласия устарела. Обновите приложение.');
      }
    }
  }

  /** Биометрия с криптопривязкой на устройстве регистрации (08 §4.2.1): Android class3 / iOS; Windows — нет. */
  private cryptoBiometrics(device: RegistrationCompleteRequest['device']): boolean {
    if (device.platform === 'android') return device.biometricClass === 'class3';
    if (device.platform === 'ios') return device.biometricClass !== 'none' && device.biometricClass !== 'windows_hello';
    return false;
  }

  private loginProtection(body: RegistrationCompleteRequest, kind: 'staff' | 'customer'): void {
    const pin = body.security.pin;
    if (kind === 'staff') {
      // D-48: PIN обязателен для всех staff на всех платформах (T-REG-009, T-SEC-044 — 422).
      if (pin === undefined) throw loginProtectionRequired(422, 'Для сотрудника PIN приложения обязателен');
    } else if (pin === undefined && !(body.security.biometricsEnabled === true && this.cryptoBiometrics(body.device))) {
      // Ядро §24.2, 08 API-182: хотя бы один способ — PIN или биометрия с криптопривязкой.
      throw loginProtectionRequired(400, 'Установите PIN или включите вход по биометрии устройства');
    }
    if (pin !== undefined) {
      throwIfErrors(
        pinErrors(pin, pinMinLength(kind, this.config.PIN_MIN_LENGTH_STAFF), body.birthYear, 'security.pin'),
      );
    }
  }

  private async decideBranch(phoneE164: string, ex: DbExecutor, lock: boolean): Promise<Branch> {
    const q = ex
      .select()
      .from(userInvitations)
      .where(
        and(
          eq(userInvitations.phoneE164, phoneE164),
          eq(userInvitations.status, 'pending'),
          gt(userInvitations.expiresAt, this.clock.now()),
        ),
      )
      .limit(1);
    const invitation = (lock ? await q.for('update') : await q)[0];
    if (invitation) {
      return {
        kind: 'staff',
        status: 'active',
        invitationId: invitation.id,
        role: invitation.role,
        invitedBy: invitation.invitedByUserId,
      };
    }
    return this.config.CUSTOMER_SELF_SERVICE
      ? { kind: 'customer', status: 'active' }
      : { kind: 'staff', status: 'pending_activation' };
  }

  private async register(
    body: RegistrationCompleteRequest,
    meta: RegistrationRequestMeta,
    token: ConsumedRegistrationToken,
  ): Promise<Registered> {
    // Ветка до транзакции — чтобы проверить защиту входа и захэшировать PIN (Argon2id) вне блокировок; в транзакции
    // ветка вычисляется повторно под FOR UPDATE.
    const preBranch = await this.decideBranch(token.phoneE164, this.db, false);
    this.loginProtection(body, preBranch.kind);
    const now = this.clock.now();
    // id задаётся заранее: user_id входит в материал хэша PIN (07 §5.13, Argon2id(pepper‖pin‖user_id)).
    const userId = newId();
    const pinHash: PinHashResult | undefined =
      body.security.pin !== undefined ? await this.hasher.hash(body.security.pin, userId) : undefined;

    try {
      return await this.db.transaction(async (tx) => {
        await applyAuditGucs(tx, { ...meta.ctx, system: 'registration' });
        // Погашение registration_token (ядро §17.3): jti → token_denylist (reason=used); повтор → 401.
        await this.regTokens.consume(body.registrationToken, { deviceKey: meta.deviceKey }, tx);
        if (await this.users.findByPhone(token.phoneE164, tx)) throw phoneTaken();
        const branch = await this.decideBranch(token.phoneE164, tx, true);
        if (branch.kind !== preBranch.kind) this.loginProtection(body, branch.kind);

        const user = await this.createUser(userId, token.phoneE164, now, branch, tx);
        const roleSource = 'invitationId' in branch ? ('invitation' as const) : undefined;
        let roles: RoleCode[] = [];
        if ('invitationId' in branch) {
          await this.roles.assignRole(user.id, branch.role, branch.invitedBy, tx);
          await tx
            .update(userInvitations)
            .set({ status: 'accepted', acceptedUserId: user.id, acceptedAt: now, updatedAt: now })
            .where(eq(userInvitations.id, branch.invitationId));
          roles = [branch.role];
        } else if (branch.kind === 'customer') {
          await this.roles.assignRole(user.id, 'customer', null, tx);
          roles = ['customer'];
        }

        const kinds = new Map(body.consents.map((c) => [c.kind, c.version] as const));
        await this.profiles.create(
          {
            userId: user.id,
            fullName: normalizeFullName(body.fullName),
            birthYear: body.birthYear,
            activitySphere: kinds.has('activity_sphere') ? (body.activitySphere ?? null) : null,
          },
          tx,
        );
        const issued = await this.issuer.createLoginSession(
          {
            user,
            roles,
            deviceKey: meta.deviceKey,
            device: body.device,
            ip: meta.ctx.ip ?? null,
            userAgent: meta.userAgent,
            challengeId: token.challengeId,
          },
          tx,
        );
        // Имя устройства для SCR-42 (`Me.session.deviceName`): SessionIssuer пишет его в `model`.
        await this.devices.upsert(
          { userId: user.id, deviceKey: meta.deviceKey, platform: body.device.platform, displayName: body.device.name },
          tx,
        );

        const granted: ConsentChange[] = [];
        for (const [kind, version] of kinds) {
          if (kind === 'sms') continue; // 09 §7.3: служебные SMS — по договору, согласие при регистрации не создаётся
          if (kind === 'biometrics_device' && body.security.biometricsEnabled !== true) continue;
          granted.push(
            await this.consents.grant(
              {
                userId: user.id,
                kind,
                version,
                deviceRowId: issued.device.id,
                ip: meta.ctx.ip ?? null,
                appVersion: body.device.appVersion,
                otpChallengeId: token.challengeId,
              },
              tx,
            ),
          );
        }
        if (pinHash) {
          await this.pins.upsert(
            {
              userId: user.id,
              pinHash: pinHash.pinHash,
              pepperVersion: pinHash.pepperVersion,
              pinLength: pinHash.pinLength,
              changedAt: now,
            },
            tx,
          );
        }
        await this.users.touchLastLogin(user.id, now, tx);

        // Аудит — последними операторами транзакции (07 §9.3): user.created (актор — система), consent.granted,
        // auth.pin.set (11 §7.2).
        const sessionCtx = { sessionId: issued.session.id, deviceId: meta.deviceKey };
        await this.audit.write(
          { ...meta.ctx, ...sessionCtx, system: 'registration' },
          {
            action: 'user.created',
            entityType: 'users',
            entityId: user.id,
            after: {
              kind: user.kind,
              status: user.status,
              phone: user.phoneE164,
              roleSource: roleSource ?? 'self',
              ...('invitationId' in branch ? { invitationId: branch.invitationId, role: branch.role } : {}),
            },
          },
          tx,
        );
        const actorCtx: AuditContext = {
          ...meta.ctx,
          ...sessionCtx,
          actorUserId: user.id,
          actorRole: roles[0] ?? null,
        };
        for (const g of granted) {
          if (!g.changed) continue;
          await this.audit.write(
            actorCtx,
            {
              action: 'consent.granted',
              entityType: 'consents',
              entityId: g.row.id,
              after: {
                kind: g.row.kind,
                version: g.row.version,
                deviceId: g.row.deviceId,
                challengeId: token.challengeId,
              },
            },
            tx,
          );
        }
        if (pinHash) {
          await this.audit.write(
            actorCtx,
            {
              action: 'auth.pin.set',
              entityType: 'app_pins',
              entityId: user.id,
              after: { pepperVersion: pinHash.pepperVersion, deviceId: meta.deviceKey },
            },
            tx,
          );
        }
        const stored: StoredRegistration = {
          status: user.status === 'pending_activation' ? 'pending_activation' : 'authenticated',
          userId: user.id,
          sessionId: issued.session.id,
          ...(roleSource ? { roleSource } : {}),
          biometricRefreshOffered:
            this.cryptoBiometrics(body.device) && (branch.kind === 'customer' || pinHash !== undefined),
          accessJti: issued.access.jti,
          accessExpiresAt: issued.access.expiresAt.toISOString(),
        };
        // Refresh-токен — только в ответе; в БД — SHA-256 (09 §2.3).
        return { stored, refreshToken: issued.refreshToken, access: issued.access };
      });
    } catch (e) {
      if (isUniqueViolation(e)) throw phoneTaken();
      throw e;
    }
  }

  private async createUser(
    userId: string,
    phoneE164: string,
    verifiedAt: Date,
    branch: Branch,
    tx: DbExecutor,
  ): Promise<UserRow> {
    const rows = await tx
      .insert(usersTable)
      .values({
        id: userId,
        phoneE164,
        kind: branch.kind,
        status: branch.status,
        phoneVerifiedAt: verifiedAt,
        invitationId: 'invitationId' in branch ? branch.invitationId : null,
      })
      .returning();
    const row = rows[0];
    if (!row) throw new Error('registration: INSERT users не вернул строку');
    return row;
  }

  private async storeOutcome(
    scope: IdempotencyScope,
    stored: StoredRegistration,
    requestId: string | null,
  ): Promise<void> {
    for (let attempt = 1; attempt <= 3; attempt++) {
      try {
        await this.idempotency.complete(scope, 201, stored, stored.userId);
        return;
      } catch (err) {
        if (attempt === 3) {
          // Ключ остаётся in_progress до TTL (повтор → 409, а не вторая регистрация; 08 §2.7, ревью C-CR-02).
          this.logger.error({ event: 'registration.idempotency_complete_failed', requestId, err }, 'complete failed');
        }
      }
    }
  }

  private async matchCustomer(
    userId: string,
    phoneE164: string,
    requestId: string | null,
  ): Promise<CustomerMatchSummary> {
    if (!this.matching) {
      this.logger.warn(
        { event: 'registration.customer_match_unavailable', requestId },
        'customer matching port missing',
      );
      return NO_MATCH;
    }
    try {
      return await this.matching.proposeForUser({ userId, phoneE164, ...(requestId ? { requestId } : {}) });
    } catch (err) {
      this.logger.warn({ event: 'registration.customer_match_failed', requestId, err }, 'customer match failed');
      return NO_MATCH;
    }
  }

  private async respond(
    stored: StoredRegistration,
    session: SessionRow,
    deviceKey: string,
    tokens: { readonly refreshToken: string; readonly access: IssuedToken },
    customerMatch: CustomerMatchSummary | undefined,
  ): Promise<RegistrationResponse> {
    const user = await this.me.build(stored.userId, { sessionId: session.id, deviceKey });
    const { refreshToken: refresh, access } = tokens;
    if (stored.status === 'pending_activation') {
      return { status: 'pending_activation', accessToken: access.token, refreshToken: refresh, user };
    }
    return {
      status: 'authenticated',
      accessToken: access.token,
      accessExpiresIn: this.issuer.accessTtlSeconds,
      refreshToken: refresh,
      refreshExpiresAt: session.expiresAt.toISOString(),
      tokenType: 'Bearer',
      sid: session.id,
      user,
      biometricRefreshOffered: stored.biometricRefreshOffered,
      ...(stored.roleSource ? { roleSource: stored.roleSource } : {}),
      nextStep: 'none',
      ...(customerMatch ? { customerMatch } : {}),
    };
  }

  /**
   * Повтор с тем же `Idempotency-Key` (08 §2.7; B-AR-01): новая пара токенов для сессии первого вызова — **только
   * один раз** и только пока сессия не использовалась (`rotated_at`, `last_used_at`, `grace_used_at` пусты), как
   * повтор verify (09 §5.6; ревью D-MN-02). Прежний refresh вытесняется (`superseded_refresh_hash`), прежний access —
   * в `token_denylist`. Иначе → 409 PHONE_ALREADY_REGISTERED (регистрация завершена — войдите), без ротации.
   */
  private async replay(status: number, body: unknown, meta: RegistrationRequestMeta): Promise<unknown> {
    const stored = body as Partial<StoredRegistration> | null;
    if (status !== 201 || !stored || typeof stored.sessionId !== 'string' || typeof stored.userId !== 'string') {
      return body; // сохранённая бизнес-ошибка — как есть
    }
    const full = stored as StoredRegistration;
    const now = this.clock.now();
    const rotated = await this.db.transaction(async (tx) => {
      const session = (
        await tx.select().from(sessionsTable).where(eq(sessionsTable.id, full.sessionId)).limit(1).for('update')
      )[0];
      if (!session || session.revokedAt !== null || session.expiresAt.getTime() <= now.getTime()) {
        throw new ProblemException('SESSION_REVOKED', { detail: 'Сессия регистрации завершена. Войдите снова.' });
      }
      const device = await this.devices.findById(session.deviceId, tx);
      if (!device || device.deviceKey !== meta.deviceKey.toLowerCase()) {
        throw new ProblemException('IDEMPOTENCY_KEY_REUSED', {
          detail: 'Ключ идемпотентности использован с другого устройства.',
        });
      }
      if (session.rotatedAt !== null || session.lastUsedAt !== null || session.graceUsedAt !== null) {
        this.logger.warn(
          { event: 'registration.replay_rejected', sid: session.id, requestId: meta.ctx.requestId ?? undefined },
          'registration.replay_rejected',
        );
        throw new ProblemException('PHONE_ALREADY_REGISTERED', {
          detail: 'Регистрация уже завершена. Войдите по номеру телефона.',
          reason: 'registration_replay_used',
        });
      }
      const refreshToken = generateOpaqueToken();
      const next = await this.store.rotateAside(
        session.id,
        { newRefreshHash: sha256(refreshToken), now, idleExpiresAt: session.idleExpiresAt },
        tx,
      );
      if (!next) throw new ProblemException('SESSION_REVOKED', { detail: 'Сессия регистрации завершена.' });
      if (full.accessJti && full.accessExpiresAt && Date.parse(full.accessExpiresAt) > now.getTime()) {
        const expiresAt = new Date(full.accessExpiresAt);
        await this.denylist.add(
          { jti: full.accessJti, tokenKind: 'access', expiresAt, reason: 'revoked', sessionId: session.id },
          tx,
        );
        this.authState.denyJti(full.accessJti, expiresAt);
      }
      return { session: next, refreshToken };
    });
    const row = await this.users.findById(full.userId);
    if (!row) throw new Error('registration: пользователь не найден');
    const roles = await this.roles.activeRoleCodes(full.userId);
    const access = await this.issuer.access(row, roles, rotated.session, meta.deviceKey, ['sms']);
    const match =
      full.status === 'authenticated' && full.roleSource === undefined
        ? summaryOf(await this.links.view(full.userId))
        : undefined;
    return this.respond(full, rotated.session, meta.deviceKey, { refreshToken: rotated.refreshToken, access }, match);
  }
}
