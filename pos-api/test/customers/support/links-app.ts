import { randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Global, Module } from '@nestjs/common';
import { APP_FILTER, APP_GUARD, APP_PIPE } from '@nestjs/core';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { Test } from '@nestjs/testing';
import { sql } from 'drizzle-orm';
import { configureHttpApp } from '../../../src/bootstrap/create-app.js';
import { AppVersionModule } from '../../../src/common/app-version/app-version.module.js';
import { AuditModule } from '../../../src/common/audit/audit.module.js';
import { AUTH_APP_GUARD, AuthCoreModule } from '../../../src/common/auth/auth-core.module.js';
import { JwtService } from '../../../src/common/auth/jwt.service.js';
import { type AppConfig, loadAppConfig } from '../../../src/common/config/app-config.js';
import { ConfigModule } from '../../../src/common/config/config.module.js';
import { CryptoModule } from '../../../src/common/crypto/crypto.module.js';
import { generateOpaqueToken, sha256 } from '../../../src/common/crypto/random.js';
import { DRIZZLE, PG_POOL } from '../../../src/common/db/database.module.js';
import { LoggingModule } from '../../../src/common/logging/logging.module.js';
import { ProblemDetailsFilter } from '../../../src/common/problem-details/problem-details.filter.js';
import { RateLimitModule } from '../../../src/common/rate-limit/rate-limit.module.js';
import { RbacGuard } from '../../../src/common/rbac/rbac.guard.js';
import { RbacModule } from '../../../src/common/rbac/rbac.module.js';
import { DEFAULT_READ_ONLY_ALLOWLIST, READ_ONLY_ALLOWLIST } from '../../../src/common/read-only/read-only.allowlist.js';
import { ReadOnlyGuard } from '../../../src/common/read-only/read-only.guard.js';
import { SettingsModule } from '../../../src/common/settings/settings.module.js';
import { createValidationPipe } from '../../../src/common/validation/validation.js';
import { CustomerLinksModule } from '../../../src/customers/links/customer-links.module.js';
import { CUSTOMER_SELF_SERVICE_FLAG, type SelfServiceFlag } from '../../../src/customers/links/self-service.flag.js';
import type { PosDatabase } from '../../../src/db/database.js';
import { FakeOnecGateway } from '../../../src/integrations/onec/fake-onec.gateway.js';
import { ONEC_GATEWAY } from '../../../src/integrations/onec/onec-gateway.js';
import { PublicSettingsModule } from '../../../src/settings/public-settings.module.js';
import { DevicesRepository } from '../../../src/users/devices.repository.js';
import { SessionsRepository } from '../../../src/users/sessions.repository.js';
import { UserProfilesRepository } from '../../../src/users/user-profiles.repository.js';
import { UserRolesRepository } from '../../../src/users/user-roles.repository.js';
import { UsersModule } from '../../../src/users/users.module.js';
import { UsersRepository } from '../../../src/users/users.repository.js';
import type { RoleCode, UserKind, UserStatusValue } from '../../../src/users/users.types.js';
import { FoundationDb } from '../../foundation/support/foundation-db.js';
import { pemPair, publicSet, testSecret } from '../../foundation/support/keys.js';
import { LogCapture } from '../../support/test-app.js';

/** Переключаемый флаг CUSTOMER_SELF_SERVICE (по умолчанию true — ядро §24.2). */
export class MutableFlag implements SelfServiceFlag {
  value = true;
  enabled(): boolean {
    return this.value;
  }
}

export interface Actor {
  readonly userId: string;
  readonly phone: string;
  readonly deviceKey: string;
  readonly sessionId: string;
  readonly role: RoleCode | null;
  readonly token: string;
}

export interface CardInput {
  readonly name: string;
  readonly type?: 'individual' | 'entrepreneur' | 'legal';
  readonly primaryPhone?: string | null;
  readonly phones?: readonly string[];
  readonly source?: 'onec' | 'pos';
  /** `true` — карточка из полной синхронизации 1С (onec_ref + synced_at). */
  readonly synced?: boolean;
  readonly balance?: string;
}

let phoneSeq = 0;
/** Уникальный номер +99677XXXXXXX (не пересекается с testPhone() фундамента и фикстурой 1С). */
export function nextPhone(): string {
  phoneSeq += 1;
  return `+99677${String(phoneSeq).padStart(7, '0')}`;
}

/**
 * Nest-приложение этапа D для тестов RM-D-005 / RM-D-015: фундамент (Config, Logging, БД, Rbac, Crypto, Audit,
 * AuthCore, RateLimit, Users, Settings, AppVersion) + CustomerLinksModule + PublicSettingsModule; порядок guard'ов —
 * ReadOnly → Auth → RBAC, как в app.module после интеграции. 1С — FakeOnecGateway (фикстуры contracts/onec).
 */
export class LinksTestApp {
  readonly fdb = new FoundationDb();
  readonly logs = new LogCapture();
  readonly flag = new MutableFlag();
  readonly onec = new FakeOnecGateway();
  readonly secretsDir = mkdtempSync(join(tmpdir(), 'pos-links-secrets-'));
  app!: NestExpressApplication;
  jwt!: JwtService;
  config!: AppConfig;

  get db(): PosDatabase {
    return this.fdb.db;
  }

  async start(dbName: string, env: Record<string, string> = {}): Promise<this> {
    await this.fdb.start(dbName);
    const k = pemPair();
    const file = (name: string, content: string) => {
      const p = join(this.secretsDir, name);
      writeFileSync(p, content, { mode: 0o600 });
      return p;
    };
    this.config = loadAppConfig({
      APP_ENV: 'staging',
      PUBLIC_BASE_URL: 'https://pos-test.example.kg',
      LOG_LEVEL: 'info',
      MIN_APP_VERSION: 'android=1.2.0,windows=1.2.0',
      DATABASE_URL_FILE: file('database_url', this.fdb.url),
      JWT_PRIVATE_KEY_FILE: file('jwt_private.pem', k.privatePem),
      JWT_PUBLIC_KEY_FILE: file('jwt_public.json', publicSet({ 'stg-links': k })),
      JWT_KEY_ID: 'stg-links',
      PIN_PEPPER_FILE: file('pin_pepper', testSecret()),
      OTP_HMAC_SECRET_FILE: file('otp_hmac', testSecret()),
      ONEC_MODE: 'fixtures',
      ...env,
    });
    const fdb = this.fdb;

    @Global()
    @Module({
      providers: [
        { provide: PG_POOL, useValue: fdb.pool },
        { provide: DRIZZLE, useValue: fdb.db },
      ],
      exports: [PG_POOL, DRIZZLE],
    })
    class TestDbModule {}

    @Module({
      imports: [
        ConfigModule.forRoot(this.config),
        LoggingModule.forRoot(this.config, this.logs),
        TestDbModule,
        RbacModule,
        CryptoModule,
        AuditModule,
        AuthCoreModule,
        RateLimitModule,
        UsersModule,
        SettingsModule,
        AppVersionModule,
        CustomerLinksModule.forRoot({ matching: { onec: true } }),
        PublicSettingsModule,
      ],
      providers: [
        { provide: READ_ONLY_ALLOWLIST, useValue: DEFAULT_READ_ONLY_ALLOWLIST },
        { provide: APP_GUARD, useClass: ReadOnlyGuard },
        AUTH_APP_GUARD,
        { provide: APP_GUARD, useClass: RbacGuard },
        { provide: APP_FILTER, useClass: ProblemDetailsFilter },
        { provide: APP_PIPE, useFactory: createValidationPipe },
      ],
    })
    class LinksRootModule {}

    const moduleRef = await Test.createTestingModule({ imports: [LinksRootModule] })
      .overrideProvider(ONEC_GATEWAY)
      .useValue(this.onec)
      .overrideProvider(CUSTOMER_SELF_SERVICE_FLAG)
      .useValue(this.flag)
      .compile();
    this.app = moduleRef.createNestApplication<NestExpressApplication>({ bodyParser: false, bufferLogs: true });
    configureHttpApp(this.app);
    await this.app.init();
    this.jwt = this.app.get(JwtService);
    return this;
  }

  async stop(): Promise<void> {
    await this.app?.close();
    await this.fdb.stop();
    rmSync(this.secretsDir, { recursive: true, force: true });
  }

  /** Пользователь с ролью (или без — pending_activation), устройством, сессией и access-токеном. */
  async actor(
    opts: {
      readonly kind?: UserKind;
      readonly role?: RoleCode | null;
      readonly status?: UserStatusValue;
      readonly phone?: string;
      readonly fullName?: string;
    } = {},
  ): Promise<Actor> {
    const kind = opts.kind ?? (opts.role === 'customer' ? 'customer' : 'staff');
    const role = opts.role === undefined ? (kind === 'customer' ? 'customer' : 'seller') : opts.role;
    const phone = opts.phone ?? nextPhone();
    const users = new UsersRepository(this.db);
    const user = await users.create({
      phoneE164: phone,
      kind,
      status: opts.status ?? 'active',
      phoneVerifiedAt: new Date(),
    });
    if (role) await new UserRolesRepository(this.db).assignRole(user.id, role, null);
    if (opts.fullName) await new UserProfilesRepository(this.db).create({ userId: user.id, fullName: opts.fullName });
    const deviceKey = randomUUID();
    const device = await new DevicesRepository(this.db).upsert({ userId: user.id, deviceKey, platform: 'android' });
    const session = await new SessionsRepository(this.db).create({
      userId: user.id,
      deviceId: device.id,
      refreshHash: sha256(generateOpaqueToken()),
      expiresAt: new Date(Date.now() + 7 * 24 * 3600_000),
      idleExpiresAt: new Date(Date.now() + 24 * 3600_000),
    });
    const { token } = await this.jwt.signAccess({
      sub: user.id,
      kind,
      roles: role ? [role] : [],
      permissionsVersion: user.permissionsVersion,
      deviceId: deviceKey,
      sid: session.id,
    });
    return { userId: user.id, phone, deviceKey, sessionId: session.id, role, token };
  }

  /** stepUpToken (как выдаёт POST /auth/step-up, RM-D-003): привязан к sub, sid, deviceId и scope. */
  async stepUp(a: Actor, scope: readonly string[] = ['customer.link.resolve'], method = 'pin'): Promise<string> {
    const pv = (
      await this.db.execute<{ v: number }>(sql`SELECT permissions_version AS v FROM users WHERE id = ${a.userId}::uuid`)
    ).rows[0].v;
    const t = await this.jwt.signPurpose('step_up', {
      sub: a.userId,
      ttlSeconds: 900,
      claims: { sid: a.sessionId, deviceId: a.deviceKey, scope: [...scope], method, pv },
    });
    return t.token;
  }

  /** Карточка клиента в реплике `customers` (+ снимок долга в `receivables`, если задан `balance`). */
  async card(input: CardInput): Promise<string> {
    const synced = input.synced ?? (input.source ?? 'onec') === 'onec';
    const phones = [...new Set([...(input.primaryPhone ? [input.primaryPhone] : []), ...(input.phones ?? [])])];
    const res = await this.db.execute<{ id: string }>(sql`
      INSERT INTO customers (onec_ref, onec_code, source, name, customer_type, primary_phone_e164, phones_norm,
                             synced_at, source_hash, onec_status)
      VALUES (${synced ? randomUUID() : null}::uuid, ${synced ? `T-${randomUUID().slice(0, 8)}` : null},
              ${input.source ?? 'onec'}, ${input.name}, ${input.type ?? 'individual'}, ${input.primaryPhone ?? null},
              ${`{${phones.join(',')}}`}::text[], ${synced ? new Date().toISOString() : null}::timestamptz,
              ${synced ? 'test' : null}, ${input.source === 'pos' ? 'pending' : 'n_a'})
      RETURNING id`);
    const id = res.rows[0].id;
    if (input.balance !== undefined) {
      await this.db.execute(sql`
        INSERT INTO receivables (customer_id, balance, overdue_amount, onec_snapshot_at, synced_at, source_hash)
        VALUES (${id}, ${input.balance}::numeric, 0, now(), now(), 'test')`);
    }
    return id;
  }

  /** Секундный контакт карточки (второй телефон ЮЛ) в `customer_contacts`. */
  async contact(customerId: string, phone: string, primary = false): Promise<void> {
    await this.db.execute(sql`
      INSERT INTO customer_contacts (customer_id, kind, value, value_norm, is_primary)
      VALUES (${customerId}, 'phone', ${phone}, ${phone}, ${primary})`);
  }

  /** Привязка напрямую (для сценариев SEC-130). */
  async link(
    userId: string,
    customerId: string,
    status: 'proposed' | 'conflict' | 'confirmed' | 'rejected',
    phone: string,
  ): Promise<string> {
    const res = await this.db.execute<{ id: string }>(sql`
      INSERT INTO customer_links (user_id, customer_id, status, match_method, matched_phone_e164, confirmed_at)
      VALUES (${userId}, ${customerId}, ${status}, 'phone', ${phone}, ${status === 'confirmed' ? new Date().toISOString() : null}::timestamptz)
      RETURNING id`);
    return res.rows[0].id;
  }

  async linkStatus(id: string): Promise<string> {
    const res = await this.db.execute<{ status: string }>(sql`SELECT status FROM customer_links WHERE id = ${id}`);
    return res.rows[0].status;
  }

  async auditRows(entityId: string): Promise<Record<string, unknown>[]> {
    const res = await this.db.execute<Record<string, unknown>>(sql`
      SELECT action, actor_user_id, actor_role, step_up_method, reason, before, after, result
        FROM audit_logs WHERE entity_id = ${entityId} ORDER BY seq`);
    return res.rows;
  }
}
