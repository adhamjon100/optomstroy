import { randomBytes, randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { type DynamicModule, Global, Module, type Provider } from '@nestjs/common';
import { APP_FILTER, APP_GUARD, APP_INTERCEPTOR, APP_PIPE } from '@nestjs/core';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { Test } from '@nestjs/testing';
import { and, eq, inArray } from 'drizzle-orm';
import request from 'supertest';
import { configureHttpApp } from '../../../src/bootstrap/create-app.js';
import { AuthModule } from '../../../src/auth/auth.module.js';
import { AuditModule } from '../../../src/common/audit/audit.module.js';
import { AUTH_SESSION_ACTIVITY_GUARD } from '../../../src/auth/sessions/session-activity.guard.js';
import { AUTH_APP_GUARD, AuthCoreModule } from '../../../src/common/auth/auth-core.module.js';
import { CLOCK, FixedClock } from '../../../src/common/auth/clock.js';
import { JwtService } from '../../../src/common/auth/jwt.service.js';
import { type AppConfig, loadAppConfig } from '../../../src/common/config/app-config.js';
import { ConfigModule } from '../../../src/common/config/config.module.js';
import { CryptoModule } from '../../../src/common/crypto/crypto.module.js';
import { sha256 } from '../../../src/common/crypto/random.js';
import { DRIZZLE, PG_POOL } from '../../../src/common/db/database.module.js';
import { IdempotencyInterceptor } from '../../../src/common/idempotency/idempotency.interceptor.js';
import { IdempotencyModule } from '../../../src/common/idempotency/idempotency.module.js';
import { newId } from '../../../src/common/ids/uuid.js';
import { LoggingModule } from '../../../src/common/logging/logging.module.js';
import { ProblemDetailsFilter } from '../../../src/common/problem-details/problem-details.filter.js';
import { RateLimitModule } from '../../../src/common/rate-limit/rate-limit.module.js';
import { RbacGuard } from '../../../src/common/rbac/rbac.guard.js';
import { RbacModule } from '../../../src/common/rbac/rbac.module.js';
import { DEFAULT_READ_ONLY_ALLOWLIST, READ_ONLY_ALLOWLIST } from '../../../src/common/read-only/read-only.allowlist.js';
import { ReadOnlyGuard } from '../../../src/common/read-only/read-only.guard.js';
import { createValidationPipe } from '../../../src/common/validation/validation.js';
import type { PosDatabase } from '../../../src/db/database.js';
import { customerLinks, customers, otpChallenges } from '../../../src/db/schema/index.js';
import { CustomerLinksModule } from '../../../src/customers/links/customer-links.module.js';
import { CustomerLinksService } from '../../../src/customers/links/customer-links.service.js';
import { ProfileModule } from '../../../src/profile/profile.module.js';
import {
  CUSTOMER_MATCHING_PORT,
  type CustomerMatchingPort,
  type CustomerMatchSummary,
  type RegistrationMatchInput,
} from '../../../src/registration/ports/customer-matching.port.js';
import { RegistrationModule } from '../../../src/registration/registration.module.js';
import { UsersModule } from '../../../src/users/users.module.js';
import { LogCapture } from '../../support/test-app.js';
import { FoundationDb } from '../../foundation/support/foundation-db.js';

export { FoundationDb, LogCapture };

/** Каталог текстов согласий (contracts/legal/consents_ru.md) — текущая версия всех видов. */
export const CONSENT_VERSION = '2026-10-01';

/**
 * Тестовый режим OTP 09 §5.8 (`AUTH_OTP_TEST_MODE`, только dev/staging): номера из `AUTH_OTP_TEST_PHONES` получают
 * фиксированный код `AUTH_OTP_TEST_CODE` без отправки SMS (смена номера — OtpService модуля auth).
 */
export const OTP_TEST_CODE = '246810';
export const OTP_TEST_PHONES = ['+996777000101', '+996777000102', '+996777000103', '+996777000104'] as const;

const secretsDir = mkdtempSync(join(tmpdir(), 'pos-reg-secrets-'));
let secretFiles: { pin: string; otp: string } | undefined;

/** Удалить временные файлы секретов (afterAll). */
export function cleanupSecrets(): void {
  rmSync(secretsDir, { recursive: true, force: true });
}

/**
 * Конфигурация тестового приложения: APP_ENV=dev, JWT — эфемерный Ed25519; `PIN_PEPPER` и `OTP_HMAC_SECRET` —
 * из файлов `*_FILE` (строка ≥ 32 байт, генерируется на запуск, как на тестовом контуре). Эфемерный pepper
 * (случайные байты) не используется: `@node-rs/argon2.verify` отвергает пароль не в UTF-8 — дефект фундамента
 * PinHasher, docs/stages/D_spec_questions.md (RG-07).
 */
export function harnessConfig(overrides: Record<string, string> = {}): AppConfig {
  if (!secretFiles) {
    const file = (name: string) => {
      const p = join(secretsDir, name);
      writeFileSync(p, randomBytes(32).toString('base64url'), { mode: 0o600 });
      return p;
    };
    secretFiles = { pin: file('pin_pepper'), otp: file('otp_hmac') };
  }
  return loadAppConfig({
    APP_ENV: 'dev',
    LOG_LEVEL: 'info',
    MIN_APP_VERSION: 'android=1.0.0,windows=1.0.0,ios=1.0.0',
    DATABASE_URL: 'postgres://unused:unused@127.0.0.1:1/unused',
    PIN_PEPPER_FILE: secretFiles.pin,
    OTP_HMAC_SECRET_FILE: secretFiles.otp,
    SMS_PROVIDER: 'fake',
    AUTH_OTP_TEST_MODE: 'true',
    AUTH_OTP_TEST_PHONES: OTP_TEST_PHONES.join(','),
    AUTH_OTP_TEST_CODE: OTP_TEST_CODE,
    ...overrides,
  });
}

/**
 * Заглушка порта привязки (сбой 1С/модуля customers): регистрация обязана завершиться с `customerMatch: none`.
 * Основной сценарий тестов — реальный `CustomerLinksService` модуля customers (`ports.matching: 'customers'`).
 */
export class FailingCustomerMatching implements CustomerMatchingPort {
  readonly calls: RegistrationMatchInput[] = [];

  proposeForUser(input: RegistrationMatchInput): Promise<CustomerMatchSummary> {
    this.calls.push(input);
    return Promise.reject(new Error('1С недоступна (тест)'));
  }
}

export interface HarnessOptions {
  readonly config?: AppConfig;
  /**
   * `customers` — реальный CustomerLinksService модуля customers (RM-D-005, поиск только по реплике) как
   * CUSTOMER_MATCHING_PORT и его маршруты `/registration/customer-match*`; объект — своя реализация порта.
   */
  readonly matching?: 'customers' | CustomerMatchingPort;
  readonly logs?: LogCapture;
  readonly clock?: FixedClock;
}

export interface Harness {
  readonly app: NestExpressApplication;
  readonly jwt: JwtService;
  readonly clock: FixedClock;
  readonly logs: LogCapture;
  readonly http: () => ReturnType<typeof request>;
}

/** Приложение как AppModule после интеграции этапа D: ReadOnly → Auth → RBAC; модули registration + profile. */
export async function createHarness(fdb: FoundationDb, options: HarnessOptions = {}): Promise<Harness> {
  const config = options.config ?? harnessConfig();
  const logs = options.logs ?? new LogCapture();
  const clock = options.clock ?? new FixedClock(new Date());
  const portProviders: Provider[] = [];
  const portImports: DynamicModule[] = [];
  if (options.matching === 'customers') {
    portImports.push(CustomerLinksModule.forRoot({ matching: { onec: false }, queueController: false }));
    portProviders.push({ provide: CUSTOMER_MATCHING_PORT, useExisting: CustomerLinksService });
  } else if (options.matching) {
    portProviders.push({ provide: CUSTOMER_MATCHING_PORT, useValue: options.matching });
  }

  @Global()
  @Module({
    providers: [
      { provide: PG_POOL, useValue: fdb.pool },
      { provide: DRIZZLE, useValue: fdb.db },
    ],
    exports: [PG_POOL, DRIZZLE],
  })
  class TestInfraModule {}

  /** Подключение порта привязки — как это сделает владелец интеграции customers (глобальный провайдер). */
  @Global()
  @Module({
    imports: portImports,
    providers: portProviders,
    exports: portProviders.map((p) => (p as { provide: symbol }).provide),
  })
  class TestPortsModule {}

  const imports: (DynamicModule | (new () => unknown))[] = [
    ConfigModule.forRoot(config),
    LoggingModule.forRoot(config, logs),
    TestInfraModule,
    TestPortsModule,
    RbacModule,
    CryptoModule,
    AuditModule,
    AuthCoreModule,
    RateLimitModule,
    UsersModule,
    IdempotencyModule,
    AuthModule,
    ProfileModule,
    RegistrationModule,
  ];

  @Module({
    imports,
    providers: [
      { provide: READ_ONLY_ALLOWLIST, useValue: DEFAULT_READ_ONLY_ALLOWLIST },
      { provide: APP_GUARD, useClass: ReadOnlyGuard },
      AUTH_APP_GUARD,
      // Как в app.module.ts: активность access-токена (`last_used_at`) — признак «сессия использовалась».
      AUTH_SESSION_ACTIVITY_GUARD,
      { provide: APP_GUARD, useClass: RbacGuard },
      { provide: APP_INTERCEPTOR, useClass: IdempotencyInterceptor },
      { provide: APP_FILTER, useClass: ProblemDetailsFilter },
      { provide: APP_PIPE, useFactory: createValidationPipe },
    ],
  })
  class HarnessRootModule {}

  const moduleRef = await Test.createTestingModule({ imports: [HarnessRootModule] })
    .overrideProvider(CLOCK)
    .useValue(clock)
    .compile();
  const app = moduleRef.createNestApplication<NestExpressApplication>({ bodyParser: false, bufferLogs: true });
  configureHttpApp(app);
  await app.init();
  return { app, jwt: app.get(JwtService), clock, logs, http: () => request(app.getHttpServer()) };
}

let phoneSeq = 0;
/** Уникальный номер КР (диапазон, не пересекающийся с test/foundation `testPhone`). */
export function regPhone(): string {
  phoneSeq += 1;
  return `+99655${String(phoneSeq + Math.floor(Math.random() * 100) * 10_000).padStart(7, '0')}`;
}

export interface SeededChallenge {
  readonly challengeId: string;
  readonly phone: string;
  readonly deviceKey: string;
  readonly token: string;
  readonly jti: string;
}

/**
 * Состояние после `/auth/otp/verify` → `registration_required` (модуль auth, RM-D-001): `otp_challenges`
 * `login_or_register` в статусе `verified` + `registration_token` (JWT `purpose=registration`, claims
 * `challengeId`, `deviceId`; хэш — в `registration_token_hash`).
 */
export async function seedRegistration(
  db: PosDatabase,
  jwt: JwtService,
  opts: {
    readonly phone?: string;
    readonly deviceKey?: string;
    readonly verifiedAt?: Date;
    readonly claims?: Record<string, unknown>;
    readonly ttlSeconds?: number;
  } = {},
): Promise<SeededChallenge> {
  const phone = opts.phone ?? regPhone();
  const deviceKey = opts.deviceKey ?? randomUUID();
  const verifiedAt = opts.verifiedAt ?? new Date();
  const challengeId = newId();
  const issued = await jwt.signPurpose('registration', {
    ttlSeconds: opts.ttlSeconds ?? 900,
    claims: { challengeId, deviceId: deviceKey, ...(opts.claims ?? {}) },
  });
  await db.insert(otpChallenges).values({
    id: challengeId,
    phoneE164: phone,
    purpose: 'login_or_register',
    codeHmac: randomBytes(32),
    salt: randomBytes(16),
    pepperVersion: 1,
    expiresAt: new Date(verifiedAt.getTime() + 300_000),
    status: 'verified',
    verifiedAt,
    registrationTokenHash: sha256(issued.token),
    registrationTokenExpiresAt: issued.expiresAt,
    deviceKey,
  });
  return { challengeId, phone, deviceKey, token: issued.token, jti: issued.jti };
}

export interface CompleteBodyOptions {
  readonly pin?: string | null;
  readonly biometricsEnabled?: boolean;
  readonly platform?: 'android' | 'ios' | 'windows';
  readonly biometricClass?: 'class3' | 'class2' | 'none' | 'windows_hello';
  readonly consents?: { kind: string; version: string }[];
  readonly activitySphere?: string | null;
  readonly birthYear?: number;
  readonly fullName?: string;
  readonly extra?: Record<string, unknown>;
}

export function completeBody(token: string, o: CompleteBodyOptions = {}): Record<string, unknown> {
  const security: Record<string, unknown> = {};
  if (o.pin !== null) security.pin = o.pin ?? '583920';
  if (o.biometricsEnabled !== undefined) security.biometricsEnabled = o.biometricsEnabled;
  return {
    registrationToken: token,
    fullName: o.fullName ?? 'Тестов Тест',
    birthYear: o.birthYear ?? 1990,
    ...(o.activitySphere !== undefined ? { activitySphere: o.activitySphere } : {}),
    security,
    consents: o.consents ?? [{ kind: 'personal_data', version: CONSENT_VERSION }],
    device: {
      name: 'Тестовый телефон',
      platform: o.platform ?? 'android',
      osVersion: '14',
      appVersion: '1.0.0+1',
      ...(o.biometricClass ? { biometricClass: o.biometricClass } : {}),
    },
    ...(o.extra ?? {}),
  };
}

export function postComplete(
  h: Harness,
  body: Record<string, unknown>,
  deviceKey: string,
  idempotencyKey: string | null = randomUUID(),
) {
  let r = h.http().post('/api/v1/registration/complete').set('X-Device-Id', deviceKey).send(body);
  if (idempotencyKey !== null) r = r.set('Idempotency-Key', idempotencyKey);
  return r;
}

/**
 * `stepUpToken` в формате `/auth/step-up` модуля auth (StepUpService): JWT `purpose=step_up`, claims `sid`,
 * `scope=[operation]`, `method`, `deviceId`, `pv` (permissionsVersion).
 */
export async function stepUpToken(
  jwt: JwtService,
  s: { readonly userId: string; readonly sid: string; readonly deviceKey: string },
  operation: string,
  method: 'pin' | 'otp' = 'pin',
  permissionsVersion = 1,
): Promise<string> {
  return (
    await jwt.signPurpose('step_up', {
      sub: s.userId,
      ttlSeconds: 900,
      claims: { sid: s.sid, scope: [operation], method, deviceId: s.deviceKey, pv: permissionsVersion },
    })
  ).token;
}

export async function seedCustomer(
  db: PosDatabase,
  name: string,
  phone: string,
  customerType: 'individual' | 'entrepreneur' | 'legal' = 'legal',
): Promise<string> {
  const rows = await db
    .insert(customers)
    .values({
      source: 'onec',
      name,
      customerType,
      primaryPhoneE164: phone,
      phonesNorm: [phone],
      onecRef: randomUUID(),
      syncedAt: new Date(),
      sourceHash: 'test',
    })
    .returning({ id: customers.id });
  const id = rows[0]?.id;
  if (!id) throw new Error('seedCustomer');
  return id;
}

export async function linksOf(db: PosDatabase, userId: string) {
  return db
    .select()
    .from(customerLinks)
    .where(
      and(
        eq(customerLinks.userId, userId),
        inArray(customerLinks.status, ['proposed', 'confirmed', 'conflict', 'rejected']),
      ),
    );
}

/** Типизированный доступ к массивам тела ответа supertest (`body` — any). */
export function list<T>(v: unknown): T[] {
  return Array.isArray(v) ? (v as T[]) : [];
}
