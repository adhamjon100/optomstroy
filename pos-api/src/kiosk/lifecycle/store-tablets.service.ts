import { Inject, Injectable, Logger } from '@nestjs/common';
import { principalOf } from '../../admin/users/shared/principal.js';
import { verifiedStepUp } from '../../admin/users/shared/step-up.guard.js';
import { clientIp, headerValue, requestIdOf, type AuthHttpRequest } from '../../auth/common/request.js';
import { OtpChallengesRepository } from '../../auth/otp/otp-challenges.repository.js';
import { SessionIssuer } from '../../auth/sessions/session-issuer.service.js';
import { SessionStore } from '../../auth/sessions/session-store.js';
import { KioskCartCloser } from '../../cart/kiosk-cart-closer.js';
import { applyAuditGucs, auditContextFromRequest } from '../../common/audit/audit-context.js';
import { AuditService } from '../../common/audit/audit.service.js';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import { AuthStateCache } from '../../common/auth/auth-state.js';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import type { IssuedToken } from '../../common/auth/jwt.service.js';
import type { AuthenticatedPrincipal } from '../../common/auth/principal.js';
import { ExitCodeHasher } from '../../common/crypto/exit-code-hasher.service.js';
import { generateExitCode, generateOpaqueToken, sha256 } from '../../common/crypto/random.js';
import { DRIZZLE } from '../../common/db/database.module.js';
import { IdempotencyService } from '../../common/idempotency/idempotency.service.js';
import type { IdempotencyScope } from '../../common/idempotency/idempotency.store.js';
import { ReplayedResponseException } from '../../common/idempotency/replayed-response.exception.js';
import { newId } from '../../common/ids/uuid.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { DevicesRepository } from '../../users/devices.repository.js';
import { SessionsRepository } from '../../users/sessions.repository.js';
import { TokenDenylistRepository } from '../../users/token-denylist.repository.js';
import { UserProfilesRepository } from '../../users/user-profiles.repository.js';
import { UserRolesRepository } from '../../users/user-roles.repository.js';
import { UsersRepository } from '../../users/users.repository.js';
import type { DeviceRow, SessionRow } from '../../users/users.types.js';
import {
  type KioskTokensDto,
  type StoreTabletDto,
  type StoreTabletEnrollBody,
  type StoreTabletRevokeBody,
  type StoreTabletStatus,
  type StoreTabletsListDto,
  type StoreTabletUpdateBody,
  toStoreTabletDto,
} from './store-tablets.dto.js';
import { StoreTabletsRepository } from './store-tablets.repository.js';

/** Ключ идемпотентности подключения (снят с запроса до глобального интерсептора — ответ несёт секреты, 08 §2.7). */
export interface SecretIdempotency {
  readonly key: string;
  /** `METHOD /шаблон` — как у `IdempotencyInterceptor` (`routeKey(method, requestRouteTemplate(req))`). */
  readonly route: string;
  /** `requestFingerprint(params, body)` (08 §2.7). */
  readonly fingerprint: Buffer;
}

/**
 * Итог подключения в `idempotency_keys.response_body` — **только идентификаторы** (08 §2.7 «Подключение и подключение
 * заново планшета»; 11 SEC-141 п. 5): без токенов и аварийного кода. `jti` и срок выданного access — не сам токен
 * (при повторе он попадает в `token_denylist`, как у `POST /registration/complete`).
 */
interface StoredEnrollment {
  readonly tabletId: string;
  readonly userId: string;
  readonly sessionId: string;
  readonly accessJti: string;
  readonly accessExpiresAt: string;
}

interface Enrolled {
  readonly stored: StoredEnrollment;
  readonly session: SessionRow;
  readonly device: DeviceRow;
  readonly refreshToken: string;
  readonly access: IssuedToken;
  readonly exitCode: string;
  readonly revokedAdminSessions: readonly string[];
}

interface Reconnected extends Enrolled {
  /** Прежние сессии технического пользователя, отозванные с `kiosk_revoked` (копия на заменённом устройстве). */
  readonly revokedTabletSessions: readonly string[];
}

/** Операции с ответом `KioskTokens` и своей идемпотентностью (08 §2.7): статус ответа и события журнала повтора. */
const TOKEN_OPERATIONS = {
  enroll: { status: 201, replayed: 'kiosk.enroll_replayed', rejected: 'kiosk.enroll_replay_rejected' },
  reconnect: { status: 200, replayed: 'kiosk.reconnect_replayed', rejected: 'kiosk.reconnect_replay_rejected' },
} as const;
type TokenOperation = keyof typeof TOKEN_OPERATIONS;

type Req = AuthHttpRequest;

const KIOSK_ROLES = ['kiosk'] as const;

function tabletNotFound(): ProblemException {
  return new ProblemException('NOT_FOUND', { detail: 'Планшет не найден.' });
}

function warehouseNotFound(): ProblemException {
  return new ProblemException('NOT_FOUND', { detail: 'Склад не найден или не действует.' });
}

function replayUsed(): ProblemException {
  return new ProblemException('IDEMPOTENCY_KEY_REUSED', {
    detail: 'Подключение уже выполнено. Войдите и подключите планшет заново.',
    reason: 'replay_used',
  });
}

function isStoredEnrollment(v: unknown): v is StoredEnrollment {
  if (typeof v !== 'object' || v === null) return false;
  const o = v as Record<string, unknown>;
  return ['tabletId', 'userId', 'sessionId', 'accessJti', 'accessExpiresAt'].every((k) => typeof o[k] === 'string');
}

/**
 * Жизненный цикл планшета магазина в модуле `admin` (08 §4.18.11–§4.18.15; 09 §8.9; 07 §5.65; 10 KIOSK-002…KIOSK-004,
 * KIOSK-031; 11 SEC-136, SEC-139…SEC-142; ADR-115; FLOW-043, SCR-54): подключение этого устройства, список, изменение
 * имени и склада, отключение, подключение заново тем же техническим пользователем. Аварийный выход со связью —
 * `KioskExitService` (тот же модуль `kiosk/lifecycle`).
 * Каждое изменение — одна транзакция READ COMMITTED: `applyAuditGucs` первым оператором, аудит — последним
 * (07 §9.3); после COMMIT — сброс кэша состояния AuthGuard (≤ 60 с иначе, 08 §2.2). Токены и аварийный код не
 * попадают ни в логи, ни в аудит, ни в хранилище идемпотентности (11 SEC-062, SEC-140, SEC-141).
 */
@Injectable()
export class StoreTabletsService {
  private readonly logger = new Logger('kiosk');
  /**
   * Погашение кодов `kiosk_order` планшета (`gashKioskCodes`, 09 §5.3 п. 4) — в транзакции отключения. Класс без
   * состояния (только `DRIZZLE`); `AuthModule` его не экспортирует, а второй провайдер с тем же токеном в графе модулей
   * подменил бы экземпляр модуля `auth` для `app.get(OtpChallengesRepository)` — поэтому экземпляр создаётся здесь.
   */
  private readonly otpChallenges: OtpChallengesRepository;

  constructor(
    @Inject(DRIZZLE) private readonly db: DbExecutor,
    @Inject(CLOCK) private readonly clock: Clock,
    private readonly repo: StoreTabletsRepository,
    private readonly issuer: SessionIssuer,
    private readonly store: SessionStore,
    private readonly hasher: ExitCodeHasher,
    private readonly idempotency: IdempotencyService,
    private readonly users: UsersRepository,
    private readonly roles: UserRolesRepository,
    private readonly profiles: UserProfilesRepository,
    private readonly devices: DevicesRepository,
    private readonly sessions: SessionsRepository,
    private readonly denylist: TokenDenylistRepository,
    private readonly audit: AuditService,
    private readonly authState: AuthStateCache,
    private readonly kioskCarts: KioskCartCloser,
  ) {
    this.otpChallenges = new OtpChallengesRepository(db);
  }

  /** `GET /admin/store-tablets` (08 §4.18.12): все планшеты или по статусу; порядок — по имени. */
  async list(status: StoreTabletStatus | undefined): Promise<StoreTabletsListDto> {
    const items = await this.repo.list(status, this.clock.now());
    return { items: items.map(toStoreTabletDto) };
  }

  // ---------------------------------------------------------------------------------------------- подключение

  /**
   * `POST /admin/store-tablets` (08 §4.18.11; 09 §8.9 п. 1; FLOW-043): администратор на самом планшете (тот же
   * `X-Device-Id`) подключает устройство. Одна транзакция: технический пользователь `kind=kiosk` (без телефона,
   * `active`), профиль (имя, склад), роль `kiosk`, строка `devices` для того же `device_key`, одна сессия планшета
   * (`standard`, `amr=["pin"]`, 180 дн / 7 дн простоя), строка `store_tablets` (`active`, хэш нового аварийного кода,
   * `lock_task_enabled = NULL`); сессии администратора на этом устройстве → `logout`, его access `jti` — в
   * `token_denylist`; аудит `kiosk.enrolled`. Ответ — токены планшета и аварийный код (один раз). Идемпотентность —
   * своя (08 §2.7): в `idempotency_keys` только идентификаторы; повтор — `replayTokens`.
   */
  async enroll(req: Req, body: StoreTabletEnrollBody, idem: SecretIdempotency): Promise<KioskTokensDto> {
    const admin = principalOf(req);
    const scope: IdempotencyScope = {
      key: idem.key,
      subjectKey: `user:${admin.userId}`,
      userId: admin.userId,
      route: idem.route,
    };
    const begin = await this.idempotency.begin(scope, idem.fingerprint);
    if (begin.kind === 'replay') {
      throw new ReplayedResponseException(
        begin.status,
        await this.replayTokens(req, admin, begin.status, begin.body, 'enroll'),
      );
    }
    let done: Enrolled;
    try {
      done = await this.enrollTx(req, admin, body);
    } catch (e) {
      // Транзакция откатилась — побочного эффекта нет: ключ освобождается, повтор выполнится заново.
      await this.idempotency.release(scope).catch((err: unknown) => this.logger.warn({ err }, 'release failed'));
      throw e;
    }
    // Сессии администратора на устройстве и его access — недействительны в этом процессе сразу (08 §2.2).
    for (const sid of done.revokedAdminSessions) this.authState.invalidateSession(sid);
    if (admin.tokenExpiresAt.getTime() > this.clock.now().getTime()) {
      this.authState.denyJti(admin.jti, admin.tokenExpiresAt);
    }
    await this.storeOutcome(scope, done.stored, TOKEN_OPERATIONS.enroll.status, requestIdOf(req));
    this.logger.log(
      { event: 'kiosk.enrolled', requestId: requestIdOf(req), tabletId: done.stored.tabletId },
      'kiosk.enrolled',
    );
    return this.tokens(done.stored.tabletId, done.session, done.refreshToken, done.access, done.exitCode);
  }

  private async enrollTx(req: Req, admin: AuthenticatedPrincipal, body: StoreTabletEnrollBody): Promise<Enrolled> {
    const ctx = auditContextFromRequest(req);
    const now = this.clock.now();
    const ip = clientIp(req);
    const userAgent = headerValue(req, 'user-agent') ?? null;
    // `store_tablets.id` входит в хэш кода (pepper ‖ код ‖ tablet_id) — задаётся до вставки; Argon2id — вне транзакции.
    const tabletId = newId();
    const exitCode = generateExitCode();
    const exit = await this.hasher.hash(exitCode, tabletId);
    return this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, ctx);
      // Сессия администратора под блокировкой: параллельное подключение с того же устройства ждёт COMMIT и получает
      // 401 (сессия уже завершена) — второго планшета из одного входа не получится.
      const adminSession = await this.sessions.lockById(admin.sessionId, tx);
      if (!adminSession || adminSession.userId !== admin.userId || adminSession.revokedAt !== null) {
        throw new ProblemException('SESSION_REVOKED', { detail: 'Сессия завершена. Войдите снова.' });
      }
      const adminDevice = await this.devices.findById(adminSession.deviceId, tx);
      if (!adminDevice) throw new Error('store_tablets: нет устройства сессии администратора');
      if (!(await this.repo.isActiveWarehouse(body.warehouseId, tx))) throw warehouseNotFound();

      const user = await this.repo.insertKioskUser(tx);
      await this.profiles.create({ userId: user.id, fullName: body.name, homeWarehouseId: body.warehouseId }, tx);
      await this.roles.assignRole(user.id, 'kiosk', admin.userId, tx);
      const device = await this.devices.upsert(
        {
          userId: user.id,
          deviceKey: admin.deviceId,
          platform: adminDevice.platform,
          model: adminDevice.model,
          osVersion: adminDevice.osVersion,
          appVersion: adminDevice.appVersion,
          lastIp: ip,
        },
        tx,
      );
      const issued = await this.issuer.createKioskSession({ user, roles: KIOSK_ROLES, device, ip, userAgent }, tx);
      await this.repo.insert(
        {
          id: tabletId,
          userId: user.id,
          deviceId: device.id,
          exitCodeHash: exit.exitCodeHash,
          exitCodePepperVersion: exit.pepperVersion,
          enrolledByUserId: admin.userId,
          enrolledAt: now,
        },
        tx,
      );
      // Сессии администратора на этом устройстве (как при повторном входе на том же устройстве — 09 §8.9 п. 1).
      const revokedAdminSessions = await this.sessions.revokeAllForUser(
        admin.userId,
        'logout',
        { deviceId: adminSession.deviceId },
        tx,
      );
      if (admin.tokenExpiresAt.getTime() > now.getTime()) {
        await this.denylist.add(
          {
            jti: admin.jti,
            tokenKind: 'access',
            expiresAt: admin.tokenExpiresAt,
            reason: 'logout',
            sessionId: admin.sessionId,
          },
          tx,
        );
      }
      await this.audit.write(
        ctx,
        {
          action: 'kiosk.enrolled',
          entityType: 'store_tablet',
          entityId: tabletId,
          after: {
            tabletId,
            name: body.name,
            warehouseId: body.warehouseId,
            userId: user.id,
            deviceId: device.id,
            revokedAdminSessions: revokedAdminSessions.length,
            revokedTabletSessions: issued.revokedSessionIds.length,
          },
          stepUpMethod: verifiedStepUp(req)?.method ?? null,
        },
        tx,
      );
      return {
        stored: {
          tabletId,
          userId: user.id,
          sessionId: issued.session.id,
          accessJti: issued.access.jti,
          accessExpiresAt: issued.access.expiresAt.toISOString(),
        },
        session: issued.session,
        device,
        refreshToken: issued.refreshToken,
        access: issued.access,
        exitCode,
        revokedAdminSessions,
      };
    });
  }

  /** Итог — отдельной командой после COMMIT, с повторами (как `POST /registration/complete`; 08 §2.7, C-CR-02). */
  private async storeOutcome(
    scope: IdempotencyScope,
    stored: StoredEnrollment,
    status: number,
    requestId: string | null,
  ): Promise<void> {
    for (let attempt = 1; attempt <= 3; attempt++) {
      try {
        await this.idempotency.complete(scope, status, stored, stored.tabletId);
        return;
      } catch (err) {
        if (attempt === 3) {
          // Ключ остаётся in_progress до TTL: повтор → 409, а не второе подключение (08 §2.7).
          this.logger.error({ event: 'kiosk.enroll_idempotency_complete_failed', requestId, err }, 'complete failed');
        }
      }
    }
  }

  /**
   * Повтор с тем же `Idempotency-Key` подключения или подключения заново (08 §2.7; 09 §8.9 п. 1, п. 6; ADR-115 п. 20):
   * **один раз** и только пока сессия планшета не использовалась (`rotated_at`, `last_used_at`, `grace_used_at`
   * пусты), с того же устройства и для действующего планшета: сессия ротируется в сторону (прежний refresh →
   * `superseded_refresh_hash`), прежний access `jti` — в `token_denylist`, хэш аварийного кода заменяется (прежний код
   * недействителен); ответ — тот же статус, новые токены и новый код. Иначе — `422 IDEMPOTENCY_KEY_REUSED`
   * (`reason: replay_used`): «Подключить заново».
   */
  private async replayTokens(
    req: Req,
    admin: AuthenticatedPrincipal,
    status: number,
    body: unknown,
    op: TokenOperation,
  ): Promise<unknown> {
    const names = TOKEN_OPERATIONS[op];
    if (status !== names.status || !isStoredEnrollment(body)) return body;
    const stored = body;
    const requestId = requestIdOf(req);
    const now = this.clock.now();
    const exitCode = generateExitCode();
    const exit = await this.hasher.hash(exitCode, stored.tabletId);
    const reject = (why: string): never => {
      this.logger.warn({ event: names.rejected, requestId, tabletId: stored.tabletId, why }, 'replay');
      throw replayUsed();
    };
    const out = await this.db.transaction(async (tx) => {
      const tablet = await this.repo.lock(stored.tabletId, tx);
      if (!tablet || tablet.status !== 'active' || tablet.userId !== stored.userId) return reject('tablet');
      const session = await this.sessions.lockById(stored.sessionId, tx);
      if (!session || session.userId !== stored.userId || session.revokedAt !== null) return reject('session');
      if (session.expiresAt.getTime() <= now.getTime()) return reject('session');
      const device = await this.devices.findById(session.deviceId, tx);
      if (!device || device.deviceKey !== admin.deviceId.toLowerCase()) return reject('device');
      if (session.rotatedAt !== null || session.lastUsedAt !== null || session.graceUsedAt !== null) {
        return reject('used');
      }
      const refreshToken = generateOpaqueToken();
      const next = await this.store.rotateAside(
        session.id,
        { newRefreshHash: sha256(refreshToken), now, idleExpiresAt: session.idleExpiresAt },
        tx,
      );
      if (!next) return reject('session');
      const accessExpiresAt = new Date(stored.accessExpiresAt);
      const deny = accessExpiresAt.getTime() > now.getTime();
      if (deny) {
        await this.denylist.add(
          {
            jti: stored.accessJti,
            tokenKind: 'access',
            expiresAt: accessExpiresAt,
            reason: 'revoked',
            sessionId: session.id,
          },
          tx,
        );
      }
      await this.repo.replaceExitCode(stored.tabletId, exit.exitCodeHash, exit.pepperVersion, now, tx);
      return { session: next, device, refreshToken, deny, accessExpiresAt };
    });
    if (out.deny) this.authState.denyJti(stored.accessJti, out.accessExpiresAt);
    this.authState.invalidateSession(out.session.id);
    const user = await this.users.findById(stored.userId);
    if (!user) throw new Error('store_tablets: технический пользователь не найден');
    const roles = await this.roles.activeRoleCodes(stored.userId);
    const access = await this.issuer.access(user, roles, out.session, out.device.deviceKey, ['pin']);
    this.logger.log({ event: names.replayed, requestId, tabletId: stored.tabletId }, names.replayed);
    return this.tokens(stored.tabletId, out.session, out.refreshToken, access, exitCode);
  }

  /** `KioskTokens` (08 §3.17): `tablet` — проекция после COMMIT; токены и код — только в этом ответе. */
  private async tokens(
    tabletId: string,
    session: SessionRow,
    refreshToken: string,
    access: IssuedToken,
    exitCode: string,
  ): Promise<KioskTokensDto> {
    return {
      tablet: await this.load(tabletId),
      accessToken: access.token,
      accessExpiresIn: this.issuer.accessTtlSeconds,
      refreshToken,
      refreshExpiresAt: session.expiresAt.toISOString(),
      sid: session.id,
      exitCode,
    };
  }

  // ---------------------------------------------------------------------------------------------- подключение заново

  /**
   * `POST /admin/store-tablets/{id}/reconnect` (08 §4.18.15; 09 §8.9 п. 6; 07 §5.65; 10 KIOSK-031; FLOW-043 A2):
   * администратор на самом планшете (тот же `X-Device-Id`) подключает заново **ту же** запись — из `active` и из
   * `revoked`; тот же технический пользователь (имя, склад, история заявок и код автора в 1С не меняются). Одна
   * транзакция: прежние сессии технического пользователя → `kiosk_revoked` (копия приложения на заменённом
   * устройстве получает `401 KIOSK_REVOKED`); строка `devices` текущего `device_key` (новая, если сменился) и
   * `store_tablets.device_id` на неё; новая сессия планшета; новый аварийный код (прежний недействителен, попытки и
   * пауза обнуляются); коды `kiosk_order` планшета гасятся, затем активная корзина технического пользователя →
   * `cleared` (`KioskCartCloser` модуля `cart`, аудит `cart.cleared` `reason: kiosk_reconnect`; 04 FLOW-045.A1 —
   * корзина прошлого покупателя не возвращается); `status=active`, `reconnected_*`, поля отключения
   * очищаются, `lock_task_enabled = NULL`; сессии администратора на устройстве → `logout`, его access `jti` — в
   * `token_denylist`; аудит `kiosk.reconnected`. Ответ 200 — `KioskTokens` (код показывается один раз).
   * Идемпотентность — как у подключения (08 §2.7): в `idempotency_keys` только идентификаторы.
   */
  async reconnect(req: Req, id: string, idem: SecretIdempotency): Promise<KioskTokensDto> {
    const admin = principalOf(req);
    const scope: IdempotencyScope = {
      key: idem.key,
      subjectKey: `user:${admin.userId}`,
      userId: admin.userId,
      route: idem.route,
    };
    const begin = await this.idempotency.begin(scope, idem.fingerprint);
    if (begin.kind === 'replay') {
      throw new ReplayedResponseException(
        begin.status,
        await this.replayTokens(req, admin, begin.status, begin.body, 'reconnect'),
      );
    }
    let done: Reconnected;
    try {
      done = await this.reconnectTx(req, admin, id);
    } catch (e) {
      // Транзакция откатилась (в том числе 404 планшета) — побочного эффекта нет: ключ освобождается.
      await this.idempotency.release(scope).catch((err: unknown) => this.logger.warn({ err }, 'release failed'));
      throw e;
    }
    // Прежние сессии планшета, сессии администратора на устройстве и его access — недействительны сразу (08 §2.2).
    this.authState.invalidateUser(done.stored.userId);
    for (const sid of [...done.revokedTabletSessions, ...done.revokedAdminSessions]) {
      this.authState.invalidateSession(sid);
    }
    if (admin.tokenExpiresAt.getTime() > this.clock.now().getTime()) {
      this.authState.denyJti(admin.jti, admin.tokenExpiresAt);
    }
    await this.storeOutcome(scope, done.stored, TOKEN_OPERATIONS.reconnect.status, requestIdOf(req));
    this.logger.log(
      {
        event: 'kiosk.reconnected',
        requestId: requestIdOf(req),
        tabletId: done.stored.tabletId,
        revokedTabletSessions: done.revokedTabletSessions.length,
      },
      'kiosk.reconnected',
    );
    return this.tokens(done.stored.tabletId, done.session, done.refreshToken, done.access, done.exitCode);
  }

  private async reconnectTx(req: Req, admin: AuthenticatedPrincipal, id: string): Promise<Reconnected> {
    const ctx = auditContextFromRequest(req);
    const now = this.clock.now();
    const ip = clientIp(req);
    const userAgent = headerValue(req, 'user-agent') ?? null;
    // Хэш нового кода (pepper ‖ код ‖ tablet_id; tablet_id тот же) — Argon2id вне транзакции.
    const exitCode = generateExitCode();
    const exit = await this.hasher.hash(exitCode, id);
    return this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, ctx);
      // Сессия администратора под блокировкой (как при подключении): параллельный второй запрос того же входа ждёт
      // COMMIT и получает 401 — вторую сессию планшета из одного входа не выдать.
      const adminSession = await this.sessions.lockById(admin.sessionId, tx);
      if (!adminSession || adminSession.userId !== admin.userId || adminSession.revokedAt !== null) {
        throw new ProblemException('SESSION_REVOKED', { detail: 'Сессия завершена. Войдите снова.' });
      }
      const adminDevice = await this.devices.findById(adminSession.deviceId, tx);
      if (!adminDevice) throw new Error('store_tablets: нет устройства сессии администратора');
      const tablet = await this.repo.lock(id, tx);
      if (!tablet) throw tabletNotFound();
      const user = await this.users.findById(tablet.userId, tx);
      if (!user) throw new Error('store_tablets: технический пользователь не найден');
      const profile = await this.profiles.findByUserId(tablet.userId, tx);

      // Прежние сессии технического пользователя (09 §8.9 п. 4, строка «Подключение заново»).
      const revokedTabletSessions = await this.sessions.revokeAllForUser(tablet.userId, 'kiosk_revoked', {}, tx);
      const device = await this.devices.upsert(
        {
          userId: tablet.userId,
          deviceKey: admin.deviceId,
          platform: adminDevice.platform,
          model: adminDevice.model,
          osVersion: adminDevice.osVersion,
          appVersion: adminDevice.appVersion,
          lastIp: ip,
        },
        tx,
      );
      const roles = await this.roles.activeRoleCodes(tablet.userId, tx);
      const issued = await this.issuer.createKioskSession({ user, roles, device, ip, userAgent }, tx);
      const codes = await this.otpChallenges.gashKioskCodes(tx, tablet.id, now);
      // Корзина прошлого покупателя (04 FLOW-045.A1): тот же users.id — активная корзина, оставшаяся после отключения,
      // аварийного выхода или истёкшей сессии, закрывается здесь; новая — первым GET /cart новой сессии. Порядок
      // блокировок «коды → корзина» (как сброс и заявка); аудит cart.cleared {reason: kiosk_reconnect, itemsCount}.
      await this.kioskCarts.closeActiveOfTablet(tx, ctx, {
        tabletUserId: tablet.userId,
        reason: 'kiosk_reconnect',
        now,
      });
      await this.repo.markReconnected(
        tablet.id,
        {
          deviceId: device.id,
          exitCodeHash: exit.exitCodeHash,
          pepperVersion: exit.pepperVersion,
          byUserId: admin.userId,
          at: now,
        },
        tx,
      );
      // Сессии администратора на этом устройстве (как при подключении — 09 §8.9 п. 1, п. 6).
      const revokedAdminSessions = await this.sessions.revokeAllForUser(
        admin.userId,
        'logout',
        { deviceId: adminSession.deviceId },
        tx,
      );
      if (admin.tokenExpiresAt.getTime() > now.getTime()) {
        await this.denylist.add(
          {
            jti: admin.jti,
            tokenKind: 'access',
            expiresAt: admin.tokenExpiresAt,
            reason: 'logout',
            sessionId: admin.sessionId,
          },
          tx,
        );
      }
      const tabletSessions = [...revokedTabletSessions, ...issued.revokedSessionIds];
      await this.audit.write(
        ctx,
        {
          action: 'kiosk.reconnected',
          entityType: 'store_tablet',
          entityId: tablet.id,
          before: { status: tablet.status, deviceId: tablet.deviceId },
          after: {
            tabletId: tablet.id,
            status: 'active',
            name: profile?.fullName ?? null,
            warehouseId: profile?.homeWarehouseId ?? null,
            userId: tablet.userId,
            deviceId: device.id,
            previousDeviceId: tablet.deviceId,
            revokedAdminSessions: revokedAdminSessions.length,
            revokedTabletSessions: tabletSessions.length,
            gashedKioskCodes: codes.superseded + codes.replayed,
          },
          stepUpMethod: verifiedStepUp(req)?.method ?? null,
        },
        tx,
      );
      return {
        stored: {
          tabletId: tablet.id,
          userId: tablet.userId,
          sessionId: issued.session.id,
          accessJti: issued.access.jti,
          accessExpiresAt: issued.access.expiresAt.toISOString(),
        },
        session: issued.session,
        device,
        refreshToken: issued.refreshToken,
        access: issued.access,
        exitCode,
        revokedAdminSessions,
        revokedTabletSessions: tabletSessions,
      };
    });
  }

  // ---------------------------------------------------------------------------------------------- изменение

  /**
   * `PATCH /admin/store-tablets/{id}` (08 §4.18.13): имя (`user_profiles.full_name`) и склад
   * (`user_profiles.home_warehouse_id`) технического пользователя; без step-up. Тот же состав → 200 без изменений и
   * без аудита; последнее изменение побеждает (`rowVersion` не используется), аудит `kiosk.updated` — было/стало
   * изменённых полей. Новый склад действует со следующей корзины (после `POST /kiosk/reset`), каталог — сразу.
   * Работает и при `KIOSK_MODE=false`, и у отключённого планшета.
   */
  async update(req: Req, id: string, body: StoreTabletUpdateBody): Promise<StoreTabletDto> {
    const ctx = auditContextFromRequest(req);
    const changed = await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, ctx);
      const tablet = await this.repo.lock(id, tx);
      if (!tablet) throw tabletNotFound();
      const profile = await this.profiles.findByUserId(tablet.userId, tx);
      if (!profile) throw new Error('store_tablets: нет профиля технического пользователя');
      const before: Record<string, unknown> = {};
      const after: Record<string, unknown> = {};
      if (body.name !== undefined && body.name !== profile.fullName) {
        before.name = profile.fullName;
        after.name = body.name;
      }
      if (body.warehouseId !== undefined && body.warehouseId !== profile.homeWarehouseId) {
        if (!(await this.repo.isActiveWarehouse(body.warehouseId, tx))) throw warehouseNotFound();
        before.warehouseId = profile.homeWarehouseId;
        after.warehouseId = body.warehouseId;
      }
      if (Object.keys(after).length === 0) return false;
      const patch = {
        ...(after.name !== undefined ? { fullName: body.name } : {}),
        ...(after.warehouseId !== undefined ? { homeWarehouseId: body.warehouseId } : {}),
      };
      await this.profiles.update(tablet.userId, patch, undefined, tx);
      await this.audit.write(
        ctx,
        { action: 'kiosk.updated', entityType: 'store_tablet', entityId: id, before, after },
        tx,
      );
      return true;
    });
    if (changed) {
      this.logger.log({ event: 'kiosk.updated', requestId: requestIdOf(req), tabletId: id }, 'kiosk.updated');
    }
    return this.load(id);
  }

  // ---------------------------------------------------------------------------------------------- отключение

  /**
   * `POST /admin/store-tablets/{id}/revoke` (08 §4.18.14; 09 §8.9 п. 4; 11 SEC-139): одна транзакция — все сессии
   * технического пользователя → `kiosk_revoked`; действующие коды `kiosk_order` планшета гасятся (`sent` →
   * `superseded`, проверенный, но не погашенный — `replayed_at`); `store_tablets` → `revoked` (`revoked_at`,
   * `revoked_by_user_id`, `revoke_reason` — событие отключения); аудит `kiosk.revoked` с причиной. Повтор для уже
   * отключённого планшета → 200 с текущим состоянием без аудита. Запись, история заявок и пользователь сохраняются
   * для подключения заново. Работает и при `KIOSK_MODE=false` (путь отката P-002 §23).
   */
  async revoke(req: Req, id: string, body: StoreTabletRevokeBody): Promise<StoreTabletDto> {
    const admin = principalOf(req);
    const ctx = auditContextFromRequest(req);
    const now = this.clock.now();
    const result = await this.db.transaction(async (tx) => {
      await applyAuditGucs(tx, ctx);
      const tablet = await this.repo.lock(id, tx);
      if (!tablet) throw tabletNotFound();
      if (tablet.status !== 'active') return null;
      const revokedSessions = await this.sessions.revokeAllForUser(tablet.userId, 'kiosk_revoked', {}, tx);
      const codes = await this.otpChallenges.gashKioskCodes(tx, tablet.id, now);
      await this.repo.markRevoked(tablet.id, admin.userId, now, tx);
      await this.audit.write(
        ctx,
        {
          action: 'kiosk.revoked',
          entityType: 'store_tablet',
          entityId: tablet.id,
          before: { status: 'active' },
          after: {
            status: 'revoked',
            revokedSessions: revokedSessions.length,
            gashedKioskCodes: codes.superseded + codes.replayed,
          },
          reason: body.reason,
          stepUpMethod: verifiedStepUp(req)?.method ?? null,
        },
        tx,
      );
      return { userId: tablet.userId, revokedSessions };
    });
    if (result) {
      // Технический пользователь и его сессии — недействительны в этом процессе сразу (08 §2.2; 11 SEC-139).
      this.authState.invalidateUser(result.userId);
      for (const sid of result.revokedSessions) this.authState.invalidateSession(sid);
      this.logger.log(
        {
          event: 'kiosk.revoked',
          requestId: requestIdOf(req),
          tabletId: id,
          revokedSessions: result.revokedSessions.length,
        },
        'kiosk.revoked',
      );
    }
    return this.load(id);
  }

  private async load(id: string): Promise<StoreTabletDto> {
    const view = await this.repo.view(id, this.clock.now());
    if (!view) throw tabletNotFound();
    return toStoreTabletDto(view);
  }
}
