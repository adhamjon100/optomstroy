import { copyFileSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { loadMigratorEnv } from '../../src/db/migrator-config.js';
import { MIGRATIONS_SCHEMA } from '../../src/db/migrator.js';
import { run } from '../../src/migrate.js';
import { EmbeddedPg } from '../support/embedded-pg.js';
import { schemaFingerprint } from './support/catalog.js';
import { MIGRATIONS_DIR } from './support/paths.js';

/**
 * Вход по лицу на всех платформах (15 ADR-116; пакет LF-2-01): миграция `0024_face_login.sql` на PostgreSQL 17
 * (embedded) настоящим мигратором `src/migrate.ts` — 07 §5.9, §5.66, §12.2, DATA-306, DATA-308; 12 T-DATA-003:
 * - обновление работающей БД: 0001…0023 с сессиями всех прежних видов и причин отзыва (в том числе `refresh_replay`
 *   0003 и `kiosk_revoked` 0022) → применяется только 0024, прежние строки допустимы, новые CHECK проверены на них
 *   (`convalidated`), у прежних сессий `weak_reauth_due_at IS NULL`;
 * - перечни CHECK `sessions.revoke_reason` и `hello_keys.*` = contracts/enums.json (как check_enum_triangle.py [3]);
 * - один файл expand без `ALTER TYPE` (новых значений enum-типов нет), повторный migrate — 0 изменений.
 * Негативные сценарии ограничений 0024 — `test/sql/check_ddl_behavior.sql`, раздел 7 (ddl-behavior.db-spec.ts).
 * Запуск: `npm run test:db` (или `npx vitest run --config test/db/vitest.config.ts test/db/face-login-schema.db-spec.ts`).
 */
const FACE_FILE = '0024_face_login.sql';
const BEFORE = '0023';
const ALL_MIGRATIONS = readdirSync(MIGRATIONS_DIR)
  .filter((n) => /^\d{4}_[a-z0-9_]+\.sql$/.test(n))
  .sort();
const SCHEMAS = ['public', MIGRATIONS_SCHEMA, 'catalog_sync'];
const ENUMS_JSON = fileURLToPath(new URL('../../../contracts/enums.json', import.meta.url));

const STAFF = '00000000-0000-7000-8000-000000000301';
const CUSTOMER = '00000000-0000-7000-8000-000000000302';
const STAFF_DEVICE = '00000000-0000-7000-8000-0000000003d1';
const CUSTOMER_DEVICE = '00000000-0000-7000-8000-0000000003d2';
/** Причины отзыва до 0024 (0001 + `refresh_replay` 0003 + `kiosk_revoked` 0022) — все на прежних строках. */
const LEGACY_REASONS = [
  'logout',
  'logout_all',
  'reuse_detected',
  'admin',
  'phone_changed',
  'role_changed',
  'expired',
  'device_revoked',
  'blocked',
  'session_limit',
  'device_mismatch',
  'biometric_invalidated',
  'refresh_replay',
  'kiosk_revoked',
];

const silent = { info: () => undefined, warn: () => undefined };

interface CheckList {
  readonly name: string;
  readonly values: string[];
}

function checkList(name: string): string[] {
  const enums = JSON.parse(readFileSync(ENUMS_JSON, 'utf8')) as { checkLists: CheckList[] };
  const list = enums.checkLists.find((c) => c.name === name);
  if (!list) throw new Error(`contracts/enums.json: нет checkLists ${name}`);
  return list.values;
}

describe('LF-2-01: схема входа по лицу — 0024_face_login.sql (07 §5.9, §5.66, §12.2; ADR-116)', () => {
  const db = new EmbeddedPg();
  const name = 'pos_face_login_schema';
  const tmp = mkdtempSync(join(tmpdir(), 'pos-face-login-'));
  const legacyDir = join(tmp, 'migrations-legacy');
  let env: ReturnType<typeof loadMigratorEnv>;
  let upgradeApplied: readonly string[] = [];

  const withDb = async <T>(fn: (c: pg.Client) => Promise<T>): Promise<T> => {
    const c = new pg.Client({ connectionString: db.url(name) });
    await c.connect();
    try {
      return await fn(c);
    } finally {
      await c.end();
    }
  };

  beforeAll(async () => {
    await db.start();
    await db.createDatabase(name);
    env = loadMigratorEnv({ APP_ENV: 'dev', LOG_LEVEL: 'silent', DATABASE_URL: db.url(name) });
    // 1) работающая БД до входа по лицу: миграции ≤ 0023 и сессии всех прежних видов (стандартные, семья S)
    mkdirSync(legacyDir, { recursive: true });
    for (const f of ALL_MIGRATIONS.filter((n) => n.slice(0, 4) <= BEFORE)) {
      copyFileSync(join(MIGRATIONS_DIR, f), join(legacyDir, f));
    }
    await run(env, { seed: false, migrationsDir: legacyDir }, silent);
    await withDb(async (c) => {
      await c.query(`
        INSERT INTO users (id, phone_e164, kind, status) VALUES
          ('${STAFF}', '+996700000301', 'staff', 'active'), ('${CUSTOMER}', '+996700000302', 'customer', 'active');
        INSERT INTO devices (id, user_id, device_key, platform, biometric_enrolled_at) VALUES
          ('${STAFF_DEVICE}', '${STAFF}', '3f2b8c1e-1a2b-4c3d-8e4f-5a6b7c8d9e41', 'windows', NULL),
          ('${CUSTOMER_DEVICE}', '${CUSTOMER}', '3f2b8c1e-1a2b-4c3d-8e4f-5a6b7c8d9e42', 'android', now());
        INSERT INTO sessions (user_id, device_id, family_id, refresh_hash, kind, expires_at, idle_expires_at, amr)
          VALUES ('${CUSTOMER}', '${CUSTOMER_DEVICE}', gen_random_uuid(), '\\x0c01', 'biometric', now() + interval '30 days',
                  now() + interval '14 days', '{sms,bio}'),
                 ('${STAFF}', '${STAFF_DEVICE}', gen_random_uuid(), '\\x0c02', 'standard', now() + interval '7 days',
                  now() + interval '24 hours', '{sms}');
      `);
      let n = 3;
      for (const reason of LEGACY_REASONS) {
        await c.query(
          `INSERT INTO sessions (user_id, device_id, family_id, refresh_hash, expires_at, idle_expires_at, revoked_at,
                                 revoke_reason)
           VALUES ($1, $2, gen_random_uuid(), $3, now(), now(), now(), $4)`,
          [STAFF, STAFF_DEVICE, Buffer.from([0x0c, n++]), reason],
        );
      }
    });
    // 2) обновление до текущего каталога миграций
    upgradeApplied = (await run(env, { seed: false }, silent)).applied;
  });

  afterAll(async () => {
    await db.stop();
    rmSync(tmp, { recursive: true, force: true });
  });

  it('DATA-308: 0024 — следующий файл после 0023, один файл expand без ALTER TYPE; при обновлении применяется первым', () => {
    const sql = readFileSync(join(MIGRATIONS_DIR, FACE_FILE), 'utf8');
    expect(ALL_MIGRATIONS.indexOf(FACE_FILE)).toBe(ALL_MIGRATIONS.findIndex((f) => f.startsWith(BEFORE)) + 1);
    expect(sql.split('\n').filter((l) => !l.trimStart().startsWith('--'))).not.toContainEqual(
      expect.stringMatching(/ALTER TYPE|DROP TABLE|DROP COLUMN|CONCURRENTLY/i),
    );
    expect(upgradeApplied).toEqual(ALL_MIGRATIONS.filter((f) => f.slice(0, 4) > BEFORE));
    expect(upgradeApplied[0]).toBe(FACE_FILE);
  });

  it('DATA-306, DATA-308: прежние сессии допустимы, новые CHECK проверены на них; weak_reauth_due_at у всех прежних — NULL', async () => {
    await withDb(async (c) => {
      const constraints = [
        'sessions_weak_reauth_chk',
        'sessions_revoke_reason_chk',
        'hello_keys_public_key_len_chk',
        'hello_keys_algorithm_chk',
        'hello_keys_source_chk',
        'hello_keys_revoke_reason_chk',
        'hello_keys_revoked_chk',
        'hello_keys_challenge_chk',
        'hello_keys_user_id_fk',
        'hello_keys_device_id_fk',
        'hello_keys_challenge_session_id_fk',
      ];
      const valid = await c.query<{ conname: string; convalidated: boolean }>(
        `SELECT conname, convalidated FROM pg_constraint WHERE conname = ANY($1) ORDER BY conname`,
        [constraints],
      );
      expect(valid.rows).toEqual([...constraints].sort().map((conname) => ({ conname, convalidated: true })));
      const rows = await c.query<{ kind: string; reason: string | null; weak: Date | null }>(
        `SELECT kind::text, revoke_reason AS reason, weak_reauth_due_at AS weak FROM sessions ORDER BY refresh_hash`,
      );
      expect(rows.rows).toHaveLength(2 + LEGACY_REASONS.length);
      expect(rows.rows.every((r) => r.weak === null)).toBe(true);
      expect(rows.rows.map((r) => r.reason).filter((r) => r !== null)).toEqual(LEGACY_REASONS);
      const tables = await c.query<{ n: number; hk: number }>(
        `SELECT (SELECT count(*)::int FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relkind IN ('r','p')) AS n,
                (SELECT count(*)::int FROM hello_keys) AS hk`,
      );
      expect(tables.rows[0]).toEqual({ n: 66, hk: 0 }); // + hello_keys; dev/test-схема (dev_outbox есть)
      const idx = await c.query<{ indexname: string; indexdef: string }>(
        `SELECT indexname, indexdef FROM pg_indexes WHERE schemaname = 'public'
           AND indexname IN ('hello_keys_device_live_uq', 'hello_keys_user_live_idx', 'devices_device_key_idx')
         ORDER BY indexname`,
      );
      expect(idx.rows.map((r) => r.indexname)).toEqual([
        'devices_device_key_idx',
        'hello_keys_device_live_uq',
        'hello_keys_user_live_idx',
      ]);
      expect(idx.rows.find((r) => r.indexname === 'hello_keys_device_live_uq')?.indexdef).toMatch(
        /UNIQUE INDEX .* WHERE \(revoked_at IS NULL\)/,
      );
    });
  });

  it('перечни CHECK = contracts/enums.json: session_revoke_reason (+ biometric_weak_disabled), hello_key_algorithm, hello_key_source, hello_key_revoke_reason', async () => {
    await withDb(async (c) => {
      const listOf = async (con: string): Promise<string[]> => {
        const d = (
          await c.query<{ d: string }>(`SELECT pg_get_constraintdef(oid) AS d FROM pg_constraint WHERE conname = $1`, [
            con,
          ])
        ).rows[0]?.d;
        return [...(d ?? '').matchAll(/'([A-Za-z0-9_]+)'::text/g)].map((m) => m[1] ?? '').sort();
      };
      const sorted = (v: string[]) => [...v].sort();
      expect(await listOf('sessions_revoke_reason_chk')).toEqual(sorted(checkList('session_revoke_reason')));
      expect(checkList('session_revoke_reason')).toEqual([...LEGACY_REASONS, 'biometric_weak_disabled']);
      expect(await listOf('hello_keys_algorithm_chk')).toEqual(sorted(checkList('hello_key_algorithm')));
      expect(await listOf('hello_keys_source_chk')).toEqual(sorted(checkList('hello_key_source')));
      expect(await listOf('hello_keys_revoke_reason_chk')).toEqual(sorted(checkList('hello_key_revoke_reason')));
    });
  });

  it('повторный migrate — 0 изменений (журнал и отпечаток схемы)', async () => {
    const before = await withDb((c) => schemaFingerprint(c, SCHEMAS));
    const again = await run(env, { seed: false }, silent);
    expect(again.applied).toEqual([]);
    expect(again.devApplied).toEqual([]);
    expect(await withDb((c) => schemaFingerprint(c, SCHEMAS))).toEqual(before);
  });
});
