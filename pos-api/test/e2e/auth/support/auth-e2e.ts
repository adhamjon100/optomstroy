import { randomUUID } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { Writable } from 'node:stream';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Controller, Get, Global, Module } from '@nestjs/common';
import { APP_FILTER, APP_GUARD, APP_PIPE } from '@nestjs/core';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { Test } from '@nestjs/testing';
import type pg from 'pg';
import request from 'supertest';
import { AdminUsersModule } from '../../../../src/admin/users/admin-users.module.js';
import { AuthModule } from '../../../../src/auth/auth.module.js';
import {
  AUTH_HTTP_LIMITS,
  type AuthHttpLimits,
  DEFAULT_AUTH_HTTP_LIMITS,
} from '../../../../src/auth/common/http-rate-limits.js';
import { OTP_DELIVERY_OPTIONS, SmsOtpProvider } from '../../../../src/auth/otp/otp.provider.js';
import { AUTH_SESSION_ACTIVITY_GUARD } from '../../../../src/auth/sessions/session-activity.guard.js';
import { AUTH_APP_GUARD } from '../../../../src/common/auth/auth-core.module.js';
import { AuthStateCache } from '../../../../src/common/auth/auth-state.js';
import { CLOCK, FixedClock } from '../../../../src/common/auth/clock.js';
import { type AppConfig, loadAppConfig } from '../../../../src/common/config/app-config.js';
import { ConfigModule } from '../../../../src/common/config/config.module.js';
import { PgBossService } from '../../../../src/common/jobs/pg-boss.service.js';
import { SMS_JOB_PUBLISHER, type SmsJobPublisher } from '../../../../src/notifications/sms/sms-job-publisher.js';
import { PinHasher } from '../../../../src/common/crypto/pin-hasher.service.js';
import { DRIZZLE, PG_POOL } from '../../../../src/common/db/database.module.js';
import { Logger } from 'nestjs-pino';
import { securityHeadersMiddleware } from '../../../../src/common/http/security-headers.middleware.js';
import { LoggingModule } from '../../../../src/common/logging/logging.module.js';
import { requestIdMiddleware } from '../../../../src/common/logging/request-id.middleware.js';
import { ProblemDetailsFilter } from '../../../../src/common/problem-details/problem-details.filter.js';
import { RequirePermission } from '../../../../src/common/rbac/rbac.decorators.js';
import { RbacGuard } from '../../../../src/common/rbac/rbac.guard.js';
import { RbacModule } from '../../../../src/common/rbac/rbac.module.js';
import {
  DEFAULT_READ_ONLY_ALLOWLIST,
  READ_ONLY_ALLOWLIST,
} from '../../../../src/common/read-only/read-only.allowlist.js';
import { ReadOnlyGuard } from '../../../../src/common/read-only/read-only.guard.js';
import { SettingsReader } from '../../../../src/common/settings/settings-reader.js';
import { createValidationPipe } from '../../../../src/common/validation/validation.js';
import { UserProfilesRepository } from '../../../../src/users/user-profiles.repository.js';
import { UserRolesRepository } from '../../../../src/users/user-roles.repository.js';
import { UsersRepository } from '../../../../src/users/users.repository.js';
import type { RoleCode, UserKind, UserStatusValue } from '../../../../src/users/users.types.js';
import { FoundationDb } from '../../../foundation/support/foundation-db.js';
import { testSecret } from '../../../foundation/support/keys.js';

export type Agent = ReturnType<typeof request>;

/** Поток строк лога pino (как test/support/test-app.ts LogCapture — без импорта AppModule). */
export class LogCapture extends Writable {
  readonly lines: string[] = [];

  override _write(chunk: Buffer | string, _enc: BufferEncoding, cb: (error?: Error | null) => void): void {
    for (const line of chunk.toString().split('\n')) if (line.trim() !== '') this.lines.push(line);
    cb();
  }

  get text(): string {
    return this.lines.join('\n');
  }
}

/** Тело JSON-ответа в тестах (как `supertest` `res.body`). */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type JsonBody = Record<string, any>;

/** Рабочий маршрут вне `/me*` и `/auth/*` (проверка ограниченной сессии без PIN и RBAC). */
@Controller('probe')
export class WorkProbeController {
  @RequirePermission('order.create')
  @Get('work')
  work() {
    return { ok: true };
  }
}

/** Базовое окружение e2e модуля auth: dev, FakeSmsGateway (dev_outbox), эфемерные ключи/секреты dev. */
export const AUTH_TEST_ENV: Record<string, string> = {
  APP_ENV: 'dev',
  LOG_LEVEL: 'info',
  MIN_APP_VERSION: 'android=1.0.0,windows=1.0.0,ios=1.0.0',
  SMS_PROVIDER: 'fake',
  OTP_GLOBAL_PER_MIN: '1000',
};

let phoneSeq = 0;
/** Уникальный синтетический номер +99677XXXXXXX (вне имитируемых статусов FakeSmsGateway `+9967000000NN`). */
export function freshPhone(): string {
  phoneSeq += 1;
  return `+99677${String(Math.floor(Math.random() * 10_000)).padStart(4, '0')}${String(phoneSeq).padStart(3, '0')}`;
}

let ipSeq = 0;
/** Уникальный IP клиента (X-Forwarded-For от loopback доверен — `trust proxy`), чтобы лимиты IP не пересекались. */
export function freshIp(): string {
  ipSeq += 1;
  return `10.${Math.floor(ipSeq / 65_000) % 250}.${Math.floor(ipSeq / 250) % 250}.${(ipSeq % 250) + 1}`;
}

export function freshDevice(): string {
  return randomUUID();
}

export interface DeviceBody {
  readonly name: string;
  readonly platform: 'android' | 'ios' | 'windows';
  readonly appVersion: string;
  readonly osVersion?: string;
  readonly biometricClass?: 'class3' | 'class2' | 'none' | 'windows_hello';
}

export const ANDROID: DeviceBody = {
  name: 'Samsung SM-A525F',
  platform: 'android',
  appVersion: '1.4.2',
  osVersion: '14',
  biometricClass: 'class3',
};
export const WINDOWS: DeviceBody = {
  name: 'Касса-2',
  platform: 'windows',
  appVersion: '1.4.2',
  biometricClass: 'windows_hello',
};

export interface LoginResult {
  readonly status: number;
  readonly body: JsonBody;
  readonly challengeId: string;
  readonly code: string;
  readonly deviceKey: string;
  readonly ip: string;
}

/** Тестовый контур: embedded PostgreSQL 17 + миграции 0001/0002 + dev_outbox, Nest-приложение с модулем auth. */
export class AuthE2e {
  readonly fdb = new FoundationDb();
  readonly clock = new FixedClock(new Date());
  readonly logs = new LogCapture();
  app!: NestExpressApplication;
  config!: AppConfig;
  private readonly secretsDir = mkdtempSync(join(tmpdir(), 'pos-auth-e2e-'));

  /** Записанные задания SMS (вариант `AuthModule.withQueuedSms()` с подменённым SMS_JOB_PUBLISHER). */
  readonly publishedJobs: { queue: string; data: Record<string, unknown>; inTx: boolean }[] = [];
  /** Имитация недоступной очереди (pg-boss процесса API не запущен) в варианте `queued`. */
  failPublish = false;

  async start(
    dbName: string,
    env: Record<string, string> = {},
    limits: Partial<AuthHttpLimits> = {},
    variant: 'in_process' | 'queued' = 'in_process',
    opts: { readonly admin?: boolean } = {},
  ): Promise<this> {
    await this.fdb.start(dbName);
    const c = await this.fdb.client();
    try {
      await c.query(`SET app.env = 'test'`);
      await c.query(
        readFileSync(
          fileURLToPath(new URL('../../../../db/migrations-dev/0001_dev_outbox.sql', import.meta.url)),
          'utf8',
        ),
      );
    } finally {
      await c.end();
    }
    // Секреты — файлами *_FILE (строки ≥ 32 байт), как на контуре; эфемерный бинарный pepper dev не используется
    // (D_spec_questions A-12: PinHasher с эфемерным PIN_PEPPER не проверяет собственные хэши).
    const file = (name: string, content: string): string => {
      const p = join(this.secretsDir, name);
      writeFileSync(p, content, { mode: 0o600 });
      return p;
    };
    this.config = loadAppConfig({
      ...AUTH_TEST_ENV,
      DATABASE_URL: this.fdb.url,
      PIN_PEPPER_FILE: file('pin_pepper', testSecret()),
      OTP_HMAC_SECRET_FILE: file('otp_hmac', testSecret()),
      ...env,
    });
    this.bootArgs = { limits, variant, opts };
    await this.boot();
    return this;
  }

  private bootArgs!: {
    readonly limits: Partial<AuthHttpLimits>;
    readonly variant: 'in_process' | 'queued';
    readonly opts: { readonly admin?: boolean };
  };

  /**
   * Перезапуск процесса pos-api на той же БД (12 T-AUTH-019): новое Nest-приложение — in-memory состояние
   * (кэши, лимиты RL-*, circuit-breaker) сбрасывается, данные PostgreSQL сохраняются.
   */
  async restart(): Promise<void> {
    await this.app.close();
    await this.boot();
  }

  private async boot(): Promise<void> {
    const { limits, variant, opts } = this.bootArgs;
    const fdb = this.fdb;
    const httpLimits: AuthHttpLimits = {
      ...DEFAULT_AUTH_HTTP_LIMITS,
      publicIpPerMinute: 10_000,
      authPerDevicePerMinute: 10_000,
      ...limits,
    };

    @Global()
    @Module({
      providers: [
        { provide: PG_POOL, useValue: fdb.pool },
        { provide: DRIZZLE, useValue: fdb.db },
        {
          provide: SettingsReader,
          useFactory: () => new SettingsReader(fdb.pool),
        },
        // Глобально: модуль auth видит их как @Optional-зависимости (OTP_DELIVERY_OPTIONS, AUTH_HTTP_LIMITS).
        { provide: OTP_DELIVERY_OPTIONS, useValue: { retryDelayMs: 0 } },
        { provide: AUTH_HTTP_LIMITS, useValue: httpLimits },
        // pg-boss в тестах не запускается (вариант queued: публикатор заданий подменяется ниже).
        { provide: PgBossService, useValue: { instance: undefined } },
      ],
      exports: [PG_POOL, DRIZZLE, SettingsReader, OTP_DELIVERY_OPTIONS, AUTH_HTTP_LIMITS, PgBossService],
    })
    class TestDbModule {}

    @Module({
      imports: [
        ConfigModule.forRoot(this.config),
        LoggingModule.forRoot(this.config, this.logs),
        TestDbModule,
        RbacModule,
        variant === 'queued' ? AuthModule.withQueuedSms() : AuthModule,
        // Админ-раздел пользователей (выдача аварийного кода, RM-D-016) — для сквозных сценариев входа по коду.
        ...(opts.admin ? [AdminUsersModule] : []),
      ],
      controllers: [WorkProbeController],
      providers: [
        { provide: READ_ONLY_ALLOWLIST, useValue: DEFAULT_READ_ONLY_ALLOWLIST },
        // Порядок глобальных guard'ов — как в app.module.ts после интеграции этапа D.
        { provide: APP_GUARD, useClass: ReadOnlyGuard },
        AUTH_APP_GUARD,
        AUTH_SESSION_ACTIVITY_GUARD,
        { provide: APP_GUARD, useClass: RbacGuard },
        { provide: APP_FILTER, useClass: ProblemDetailsFilter },
        { provide: APP_PIPE, useFactory: createValidationPipe },
      ],
    })
    class AuthE2eRootModule {}

    const jobs = this.publishedJobs;
    const publisher: SmsJobPublisher = {
      publish: (queue, data, _options, executor) => {
        if (this.failPublish) return Promise.reject(new Error('pg-boss не запущен: задание SMS не поставлено'));
        jobs.push({ queue, data: data as Record<string, unknown>, inTx: executor !== undefined });
        return Promise.resolve(randomUUID());
      },
    };
    const builder = Test.createTestingModule({ imports: [AuthE2eRootModule] })
      .overrideProvider(CLOCK)
      .useValue(this.clock);
    const moduleRef = await (
      variant === 'queued' ? builder.overrideProvider(SMS_JOB_PUBLISHER).useValue(publisher) : builder
    ).compile();
    this.app = moduleRef.createNestApplication<NestExpressApplication>({ bodyParser: false, bufferLogs: true });
    // Как configureHttpApp (src/bootstrap/create-app.ts), без импорта AppModule со всеми модулями D-06.
    this.app.useLogger(this.app.get(Logger));
    this.app.set('trust proxy', 'loopback, uniquelocal');
    this.app.use(requestIdMiddleware);
    this.app.use(securityHeadersMiddleware);
    this.app.useBodyParser('json', { limit: '1mb' });
    this.app.setGlobalPrefix('api/v1');
    await this.app.init();
  }

  async stop(): Promise<void> {
    await this.app?.close();
    await this.fdb.stop();
    rmSync(this.secretsDir, { recursive: true, force: true });
  }

  get http(): ReturnType<typeof request> {
    return request(this.app.getHttpServer());
  }

  get pool(): pg.Pool {
    return this.fdb.pool;
  }

  /** Сброс in-memory состояния между сценариями: кэш AuthGuard; часы — вперёд (окна cooldown/глобального лимита). */
  tick(ms = 61_000): void {
    this.clock.advance(ms);
  }

  /** Часы — к началу следующего фиксированного окна (+offset), чтобы сценарий не пересёк границу окна лимита. */
  alignClock(windowMs: number, offsetMs = 1_000): void {
    const now = this.clock.now().getTime();
    this.clock.set(new Date(Math.ceil(now / windowMs) * windowMs + offsetMs));
  }

  clearAuthCache(): void {
    this.app.get(AuthStateCache).clear();
  }

  async drainSms(): Promise<void> {
    await this.app.get(SmsOtpProvider).drain();
  }

  // ---------- HTTP-хелперы ----------

  otpRequest(phone: string, deviceKey: string, ip: string, extra: Record<string, unknown> = {}) {
    return this.http
      .post('/api/v1/auth/otp/request')
      .set('X-Device-Id', deviceKey)
      .set('X-Forwarded-For', ip)
      .set('X-App-Version', '1.4.2')
      .set('X-Platform', 'android')
      .send({ phone, purpose: 'login_or_register', locale: 'ru', ...extra });
  }

  otpVerify(challengeId: string, code: string, deviceKey: string, ip: string, device: DeviceBody = ANDROID) {
    return this.http
      .post('/api/v1/auth/otp/verify')
      .set('X-Device-Id', deviceKey)
      .set('X-Forwarded-For', ip)
      .send({ challengeId, code, device });
  }

  /** Код из dev_outbox (FakeSmsGateway) — после завершения фоновой отправки. */
  async codeFor(challengeId: string): Promise<string> {
    await this.drainSms();
    const r = await this.pool.query<{ text: string }>(
      `SELECT d.text FROM dev_outbox d JOIN otp_challenges c ON c.sms_outbox_id = d.sms_outbox_id WHERE c.id = $1`,
      [challengeId],
    );
    const m = /(\d{6})/.exec(r.rows[0]?.text ?? '');
    if (!m?.[1]) throw new Error(`код для ${challengeId} не найден в dev_outbox`);
    return m[1];
  }

  /** Полный вход по OTP: request → код из dev_outbox → verify. */
  async login(
    phone: string,
    opts: { deviceKey?: string; ip?: string; device?: DeviceBody } = {},
  ): Promise<LoginResult> {
    const deviceKey = opts.deviceKey ?? freshDevice();
    const ip = opts.ip ?? freshIp();
    const req = await this.otpRequest(phone, deviceKey, ip);
    if (req.status !== 202) throw new Error(`otp/request → ${req.status} ${JSON.stringify(req.body)}`);
    const challengeId = req.body.challengeId as string;
    const code = await this.codeFor(challengeId);
    const v = await this.otpVerify(challengeId, code, deviceKey, ip, opts.device ?? ANDROID);
    return { status: v.status, body: v.body as JsonBody, challengeId, code, deviceKey, ip };
  }

  bearer(method: 'get' | 'post' | 'delete' | 'patch', path: string, token: string, deviceKey: string) {
    return this.http[method](`/api/v1${path}`).set('Authorization', `Bearer ${token}`).set('X-Device-Id', deviceKey);
  }

  refresh(refreshToken: string, deviceKey: string) {
    return this.http.post('/api/v1/auth/refresh').set('X-Device-Id', deviceKey).send({ refreshToken });
  }

  unlock(body: Record<string, unknown>, deviceKey: string) {
    return this.http.post('/api/v1/auth/unlock').set('X-Device-Id', deviceKey).send(body);
  }

  // ---------- данные ----------

  async seedUser(
    opts: {
      phone?: string;
      kind?: UserKind;
      role?: RoleCode;
      status?: UserStatusValue;
      fullName?: string;
    } = {},
  ): Promise<{ userId: string; phone: string }> {
    const phone = opts.phone ?? freshPhone();
    const kind = opts.kind ?? 'staff';
    const user = await new UsersRepository(this.fdb.db).create({
      phoneE164: phone,
      kind,
      status: opts.status ?? 'active',
    });
    await new UserRolesRepository(this.fdb.db).assignRole(
      user.id,
      opts.role ?? (kind === 'customer' ? 'customer' : 'seller'),
      null,
    );
    await new UserProfilesRepository(this.fdb.db).create({
      userId: user.id,
      fullName: opts.fullName ?? 'Тестов Тест Тестович',
    });
    return { userId: user.id, phone };
  }

  async setPin(userId: string, pin: string): Promise<void> {
    const h = await this.app.get(PinHasher).hash(pin, userId);
    await this.pool.query(
      `INSERT INTO app_pins (user_id, pin_hash, pepper_version, pin_length, changed_at)
       VALUES ($1, $2, $3, $4, now())
       ON CONFLICT (user_id) DO UPDATE SET pin_hash = excluded.pin_hash, failed_attempts = 0, locked_until = NULL`,
      [userId, h.pinHash, h.pepperVersion, h.pinLength],
    );
  }

  async invite(phone: string, role: RoleCode, fullName: string, expiresAt: Date, status = 'pending'): Promise<string> {
    const admin = await this.seedUser({ role: 'admin' });
    const r = await this.pool.query<{ id: string }>(
      `INSERT INTO user_invitations (phone_e164, role, full_name, invited_by_user_id, status, expires_at, revoked_at)
       VALUES ($1, $2, $3, $4, $5::invitation_status, $6, $7) RETURNING id`,
      [phone, role, fullName, admin.userId, status, expiresAt, status === 'revoked' ? new Date() : null],
    );
    return r.rows[0].id;
  }

  async auditActions(filter: { entityId?: string; actorUserId?: string; since?: Date } = {}): Promise<string[]> {
    const r = await this.pool.query<{ action: string }>(
      `SELECT action FROM audit_logs
        WHERE ($1::uuid IS NULL OR entity_id = $1::uuid)
          AND ($2::uuid IS NULL OR actor_user_id = $2::uuid)
        ORDER BY seq`,
      [filter.entityId ?? null, filter.actorUserId ?? null],
    );
    return r.rows.map((x) => x.action);
  }
}
