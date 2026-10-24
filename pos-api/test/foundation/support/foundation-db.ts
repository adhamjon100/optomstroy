import { randomUUID } from 'node:crypto';
import pg from 'pg';
import { createDatabase, type PosDatabase } from '../../../src/db/database.js';
import { DevicesRepository } from '../../../src/users/devices.repository.js';
import { SessionsRepository } from '../../../src/users/sessions.repository.js';
import { UserRolesRepository } from '../../../src/users/user-roles.repository.js';
import { UsersRepository } from '../../../src/users/users.repository.js';
import type { RoleCode, SessionRow, UserKind, UserStatusValue } from '../../../src/users/users.types.js';
import { generateOpaqueToken, sha256 } from '../../../src/common/crypto/random.js';
import { allMigrations } from '../../support/catalog-fixture.js';
import { EmbeddedPg } from '../../support/embedded-pg.js';

/**
 * Все forward-only миграции `migrations/NNNN_*.sql` по порядку (этапы B–E): приложение AppModule этапа E (каталог,
 * поиск, офлайн-API) обращается к объектам 0004+ (`search_words`, `catalog_sync.deletions`), поэтому наборы
 * фундамента и e2e работают на полной схеме, как прод.
 */
export const MIGRATIONS: readonly string[] = allMigrations();

/** Одноразовая БД со всеми миграциями (0001 + 0002 + 0003 авторизации DQ-01…DQ-03 + объекты этапа E). */
export class FoundationDb {
  readonly pg = new EmbeddedPg();
  pool!: pg.Pool;
  db!: PosDatabase;
  url = '';

  async start(name: string): Promise<this> {
    await this.pg.start();
    await this.pg.createDatabase(name);
    await this.pg.migrate(name, MIGRATIONS);
    this.url = this.pg.url(name);
    this.pool = new pg.Pool({ connectionString: this.url, max: 30 });
    this.db = createDatabase(this.pool);
    return this;
  }

  async stop(): Promise<void> {
    await this.pool?.end().catch(() => undefined);
    await this.pg.stop();
  }

  /** Отдельное соединение (SET ROLE, отключение триггера суперпользователем). */
  async client(): Promise<pg.Client> {
    const c = new pg.Client({ connectionString: this.url });
    await c.connect();
    return c;
  }
}

let phoneSeq = 0;

/** Уникальный тестовый номер КР (+996 7XX XXX XXX). */
export function testPhone(): string {
  phoneSeq += 1;
  return `+99670${String(phoneSeq).padStart(7, '0')}`;
}

export interface SeededSubject {
  readonly userId: string;
  readonly deviceRowId: string;
  readonly deviceKey: string;
  readonly session: SessionRow;
  readonly refreshToken: string;
}

/** Пользователь + роль + устройство + сессия (данные для AuthGuard и репозиториев). */
export async function seedSubject(
  db: PosDatabase,
  opts: {
    readonly kind?: UserKind;
    readonly role?: RoleCode;
    readonly status?: UserStatusValue;
    readonly expiresInMs?: number;
  } = {},
): Promise<SeededSubject> {
  const users = new UsersRepository(db);
  const roles = new UserRolesRepository(db);
  const devices = new DevicesRepository(db);
  const sessions = new SessionsRepository(db);
  const kind = opts.kind ?? 'staff';
  const user = await users.create({ phoneE164: testPhone(), kind, status: opts.status ?? 'active' });
  await roles.assignRole(user.id, opts.role ?? (kind === 'customer' ? 'customer' : 'seller'), null);
  const deviceKey = randomUUID();
  const device = await devices.upsert({ userId: user.id, deviceKey, platform: 'android' });
  const refreshToken = generateOpaqueToken();
  const now = Date.now();
  const session = await sessions.create({
    userId: user.id,
    deviceId: device.id,
    refreshHash: sha256(refreshToken),
    expiresAt: new Date(now + (opts.expiresInMs ?? 7 * 24 * 3600_000)),
    idleExpiresAt: new Date(now + 24 * 3600_000),
  });
  return { userId: user.id, deviceRowId: device.id, deviceKey, session, refreshToken };
}
