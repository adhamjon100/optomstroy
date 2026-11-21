import { copyFileSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import pg from 'pg';
import { loadMigratorEnv } from '../../src/db/migrator-config.js';
import { MIGRATIONS_SCHEMA, readSqlDir } from '../../src/db/migrator.js';
import { run } from '../../src/migrate.js';
import { EmbeddedPg } from '../support/embedded-pg.js';
import { schemaFingerprint } from './support/catalog.js';
import { MIGRATIONS_DIR } from './support/paths.js';

/**
 * P-002 «Планшет магазина» (ADR-115), задача TAB-1-01, часть «БД»: миграции `0021_kiosk_enum_values.sql` и
 * `0022_kiosk_schema.sql` на PostgreSQL 17 (embedded) настоящим мигратором `src/migrate.ts`:
 * - правило разделения миграций (07 §12.2, DATA-305): файл с новыми значениями enum — только
 *   `ALTER TYPE … ADD VALUE IF NOT EXISTS`, литералы — в следующих файлах;
 * - обновление работающей БД: 0001…0020 с данными прежних каналов (staff, customer) → 0021/0022 — применяются только
 *   новые файлы, прежние строки остаются допустимыми, CHECK-перечни дополнены без потери значений, повтор — 0 изменений;
 * - 12 T-KIOSK-025: CHECK канала `orders_kiosk_channel_chk` и признак `kiosk_customer_match`; маскирование номера под
 *   `pos_app` после submit (DATA-303).
 * Негативные сценарии всех ограничений 0022 — `test/sql/check_ddl_behavior.sql`, раздел 6 (ddl-behavior.db-spec.ts).
 * Запуск: `npm run test:db` (или `npx vitest run --config test/db/vitest.config.ts test/db/kiosk-schema.db-spec.ts`).
 */
const RUN_SQL_MODULE = new URL('../../../tools/pg/run-sql.mjs', import.meta.url).href;
type SplitSql = (text: string) => { sql: string }[];

const ENUM_FILE = '0021_kiosk_enum_values.sql';
const SCHEMA_FILE = '0022_kiosk_schema.sql';
/** Последняя миграция до режима планшета (база эпохи веб-демо — demo/web/backend/demo-config.mjs EPOCH_MIGRATION_BASE). */
const LEGACY_BASE = '0020';
const ALL_MIGRATIONS = readdirSync(MIGRATIONS_DIR)
  .filter((n) => /^\d{4}_[a-z0-9_]+\.sql$/.test(n))
  .sort();
const SCHEMAS = ['public', MIGRATIONS_SCHEMA, 'catalog_sync'];

const STAFF = '00000000-0000-7000-8000-000000000201';
const CUSTOMER_USER = '00000000-0000-7000-8000-000000000202';
const KIOSK_USER = '00000000-0000-7000-8000-000000000203';
const STAFF_DEVICE = '00000000-0000-7000-8000-0000000002d1';
const KIOSK_DEVICE = '00000000-0000-7000-8000-0000000002d2';
const WAREHOUSE = '00000000-0000-7000-8000-0000000002a1';
const PRICE_LIST = '00000000-0000-7000-8000-0000000002a2';
const CUSTOMER = '00000000-0000-7000-8000-0000000002c1';
const KIOSK_ORDER_ID = '00000000-0000-7000-8000-0000000002e3';

/** Заявка с планшета, проходящая все CHECK (наличные, самовывоз, номер подтверждён кодом kiosk_order). */
const KIOSK_ORDER: Readonly<Record<string, string | null>> = {
  public_number: 'POS-2026-000290',
  status: 'draft',
  customer_id: CUSTOMER,
  created_by_user_id: KIOSK_USER,
  created_via: 'kiosk',
  warehouse_id: WAREHOUSE,
  price_list_id: PRICE_LIST,
  subtotal: '100.00',
  total: '100.00',
  payment_method: 'cash',
  delivery_method: 'pickup',
  kiosk_customer_match: 'single',
  receiver_phone_e164: '+996700000203',
};

interface Rejection {
  readonly code: string | undefined;
  readonly constraint: string | undefined;
}

const silent = { info: () => undefined, warn: () => undefined };

async function insertOrder(c: pg.ClientBase, overrides: Record<string, string | null>): Promise<void> {
  const row = { ...KIOSK_ORDER, ...overrides };
  const cols = Object.keys(row);
  await c.query(
    `INSERT INTO orders (${cols.join(', ')}) VALUES (${cols.map((_, i) => `$${i + 1}`).join(', ')})`,
    Object.values(row),
  );
}

/** Выполняет запрос и возвращает код и имя ограничения отказа; успех — ошибка теста. */
async function rejection(fn: () => Promise<unknown>): Promise<Rejection> {
  try {
    await fn();
  } catch (e) {
    const err = e as { code?: string; constraint?: string };
    return { code: err.code, constraint: err.constraint };
  }
  throw new Error('ожидался отказ ограничения БД');
}

describe('TAB-1-01: схема «Планшета магазина» — 0021/0022 (07 §5.65, §12.2; ADR-115)', () => {
  const db = new EmbeddedPg();
  const name = 'pos_kiosk_schema';
  const tmp = mkdtempSync(join(tmpdir(), 'pos-kiosk-schema-'));
  const legacyDir = join(tmp, 'migrations-legacy');
  let env: ReturnType<typeof loadMigratorEnv>;
  let legacyApplied: readonly string[] = [];
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
    // 1) работающая БД до режима планшета: только миграции ≤ 0020 (+ dev-миграция dev_outbox) и данные прежних каналов
    mkdirSync(legacyDir, { recursive: true });
    for (const f of ALL_MIGRATIONS.filter((n) => n.slice(0, 4) <= LEGACY_BASE)) {
      copyFileSync(join(MIGRATIONS_DIR, f), join(legacyDir, f));
    }
    legacyApplied = (await run(env, { seed: false, migrationsDir: legacyDir }, silent)).applied;
    await withDb(async (c) => {
      await c.query(`
        INSERT INTO users (id, phone_e164, kind, status) VALUES
          ('${STAFF}', '+996700000201', 'staff', 'active'), ('${CUSTOMER_USER}', '+996700000202', 'customer', 'active');
        INSERT INTO devices (id, user_id, device_key, platform)
          VALUES ('${STAFF_DEVICE}', '${STAFF}', '3f2b8c1e-1a2b-4c3d-8e4f-5a6b7c8d9e21', 'windows');
        INSERT INTO warehouses (id, synced_at, source_hash, name, is_default_for_pos)
          VALUES ('${WAREHOUSE}', now(), 'h', 'Основной', true);
        INSERT INTO price_lists (id, synced_at, source_hash, name, is_default) VALUES ('${PRICE_LIST}', now(), 'h', 'Розничная', true);
        INSERT INTO customers (id, source, name, customer_type, phones_norm)
          VALUES ('${CUSTOMER}', 'pos', 'ООО Ромашка', 'legal', '{+996555000211}');
        -- сотрудник: в долг, с ручной скидкой и доставкой; клиент: заявка по QR — оба канала не меняются (паритет)
        INSERT INTO orders (public_number, status, customer_id, created_by_user_id, created_via, warehouse_id, price_list_id,
                            subtotal, manual_discount_total, discount_total, total, payment_method, delivery_method,
                            delivery_address, delivery_recipient_phone_e164)
          VALUES ('POS-2026-000201', 'draft', '${CUSTOMER}', '${STAFF}', 'staff', '${WAREHOUSE}', '${PRICE_LIST}',
                  100.00, 10.00, 10.00, 90.00, 'credit', 'delivery', 'г. Бишкек, ул. Токтогула, 1', '+996700000204');
        INSERT INTO orders (public_number, status, customer_id, created_by_user_id, created_via, warehouse_id, price_list_id,
                            subtotal, total, payment_method, delivery_method)
          VALUES ('POS-2026-000202', 'draft', '${CUSTOMER}', '${CUSTOMER_USER}', 'customer', '${WAREHOUSE}', '${PRICE_LIST}',
                  50.00, 50.00, 'qr_bakai', 'pickup');
        INSERT INTO sessions (user_id, device_id, family_id, refresh_hash, expires_at, idle_expires_at, revoked_at, revoke_reason)
          VALUES ('${STAFF}', '${STAFF_DEVICE}', gen_random_uuid(), '\\x0b01', now() + interval '30 days',
                  now() + interval '14 days', now(), 'refresh_replay');
        INSERT INTO otp_challenges (phone_e164, purpose, code_hmac, salt, pepper_version, expires_at, status)
          VALUES ('+996700000201', 'login_or_register', '\\x01', '\\x01', 1, now() + interval '5 minutes', 'sent');
        INSERT INTO rate_limit_counters (scope, subject, window_start, count, window_end)
          VALUES ('admin_user_1m', '${STAFF}', date_trunc('minute', now()), 1, date_trunc('minute', now()) + interval '1 minute');
        INSERT INTO sms_outbox (phone_e164, template_key, provider, provider_message_id)
          VALUES ('+996700000201', 'otp_login', 'fake', 'LEGACY000201');
      `);
    });
    // 2) обновление до текущего каталога миграций
    upgradeApplied = (await run(env, { seed: false }, silent)).applied;
  });

  afterAll(async () => {
    await db.stop();
    rmSync(tmp, { recursive: true, force: true });
  });

  it('DATA-305: 0021 — только ALTER TYPE … ADD VALUE IF NOT EXISTS (4 значения 07 §6.1), литералы — с 0022', async () => {
    const { splitSql } = (await import(RUN_SQL_MODULE)) as { splitSql: SplitSql };
    const statements = (file: string): string[] =>
      splitSql(readFileSync(join(MIGRATIONS_DIR, file), 'utf8')).map((s) => s.sql.replace(/\s+/g, ' ').trim());
    expect(statements(ENUM_FILE)).toEqual([
      "ALTER TYPE user_kind ADD VALUE IF NOT EXISTS 'kiosk'",
      "ALTER TYPE role_code ADD VALUE IF NOT EXISTS 'kiosk'",
      "ALTER TYPE otp_purpose ADD VALUE IF NOT EXISTS 'kiosk_order'",
      "ALTER TYPE notification_kind ADD VALUE IF NOT EXISTS 'kiosk_order'",
    ]);
    // Общее правило для всех миграций: файл с ADD VALUE не содержит других операторов; мигратор применяет его своей
    // транзакцией (без директивы no-transaction), значения фиксируются до следующего файла.
    for (const f of readSqlDir(MIGRATIONS_DIR)) {
      const stmts = statements(f.name);
      if (stmts.some((s) => /\bADD VALUE\b/i.test(s))) {
        expect(
          stmts.every((s) => /^ALTER TYPE \w+ ADD VALUE IF NOT EXISTS '[a-z_]+'$/.test(s)),
          f.name,
        ).toBe(true);
        expect(f.transactional, f.name).toBe(true);
      }
    }
    expect(statements(SCHEMA_FILE).some((s) => /^ALTER TYPE/i.test(s))).toBe(false);
    expect(ALL_MIGRATIONS.indexOf(SCHEMA_FILE)).toBe(ALL_MIGRATIONS.indexOf(ENUM_FILE) + 1);
  });

  it('обновление 0001…0020 → 0021/0022: применены только новые файлы, данные прежних каналов допустимы', async () => {
    expect(legacyApplied).toEqual(ALL_MIGRATIONS.filter((f) => f.slice(0, 4) <= LEGACY_BASE));
    expect(upgradeApplied).toEqual(ALL_MIGRATIONS.filter((f) => f.slice(0, 4) > LEGACY_BASE));
    expect(upgradeApplied.slice(0, 2)).toEqual([ENUM_FILE, SCHEMA_FILE]);
    await withDb(async (c) => {
      const enums = await c.query<{ t: string; v: string[] }>(
        `SELECT t, (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e WHERE e.enumtypid = t::regtype) AS v
           FROM unnest(ARRAY['user_kind','role_code','otp_purpose','notification_kind']) AS t`,
      );
      expect(Object.fromEntries(enums.rows.map((r) => [r.t, r.v.at(-1)]))).toEqual({
        user_kind: 'kiosk',
        role_code: 'kiosk',
        otp_purpose: 'kiosk_order',
        notification_kind: 'kiosk_order',
      });
      expect(enums.rows.find((r) => r.t === 'user_kind')?.v).toEqual(['staff', 'customer', 'kiosk']);
      const tables = await c.query<{ n: number }>(
        `SELECT count(*)::int AS n FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relkind IN ('r','p')`,
      );
      // 64 + store_tablets (0022) + hello_keys (0024_face_login.sql, ADR-116 — обновление идёт до текущего каталога);
      // dev/test-схема: dev_outbox есть
      expect(tables.rows[0]?.n).toBe(66);

      // Новые CHECK проверены на существующих строках (convalidated), прежние строки на месте и без признаков kiosk
      const constraints = [
        'users_kiosk_phone_chk',
        'sessions_revoke_reason_chk',
        'rate_limit_counters_scope_chk',
        'sms_outbox_template_key_chk',
        'otp_challenges_kiosk_tablet_id_fk',
        'otp_challenges_cart_id_fk',
        'otp_challenges_kiosk_chk',
        'orders_created_via_chk',
        'orders_kiosk_customer_match_chk',
        'orders_pd_notice_sha256_chk',
        'orders_receiver_phone_masked_chk',
        'orders_kiosk_channel_chk',
        'orders_kiosk_match_chk',
        'orders_receiver_phone_masked_null_chk',
      ];
      const valid = await c.query<{ conname: string; convalidated: boolean }>(
        `SELECT conname, convalidated FROM pg_constraint WHERE conname = ANY($1) ORDER BY conname`,
        [constraints],
      );
      expect(valid.rows).toEqual([...constraints].sort().map((conname) => ({ conname, convalidated: true })));
      const legacy = await c.query(
        `SELECT public_number, created_via, kiosk_customer_match, pd_notice_version, pd_notice_sha256, receiver_phone_masked
           FROM orders ORDER BY public_number`,
      );
      expect(legacy.rows).toEqual([
        {
          public_number: 'POS-2026-000201',
          created_via: 'staff',
          kiosk_customer_match: null,
          pd_notice_version: null,
          pd_notice_sha256: null,
          receiver_phone_masked: null,
        },
        {
          public_number: 'POS-2026-000202',
          created_via: 'customer',
          kiosk_customer_match: null,
          pd_notice_version: null,
          pd_notice_sha256: null,
          receiver_phone_masked: null,
        },
      ]);
      const otp = await c.query(`SELECT purpose::text, kiosk_tablet_id, cart_id, notice_version FROM otp_challenges`);
      expect(otp.rows).toEqual([
        { purpose: 'login_or_register', kiosk_tablet_id: null, cart_id: null, notice_version: null },
      ]);

      // CHECK-перечни дополнены: прежние значения сохранены (0003/0001), новые добавлены (07 §6.1.1)
      const def = async (con: string): Promise<string> =>
        (
          await c.query<{ d: string }>(`SELECT pg_get_constraintdef(oid) AS d FROM pg_constraint WHERE conname = $1`, [
            con,
          ])
        ).rows[0]?.d ?? '';
      const lists: Record<string, string[]> = {
        sessions_revoke_reason_chk: [
          'logout',
          'device_mismatch',
          'biometric_invalidated',
          'refresh_replay',
          'kiosk_revoked',
        ],
        rate_limit_counters_scope_chk: [
          'otp_phone_15m',
          'admin_user_1m',
          'otp_kiosk_tablet_1h',
          'otp_kiosk_tablet_24h',
        ],
        sms_outbox_template_key_chk: ['otp_login', 'otp_customer_link', 'otp_kiosk_order'],
        orders_created_via_chk: ['staff', 'customer', 'kiosk'],
      };
      for (const [con, values] of Object.entries(lists)) {
        const d = await def(con);
        for (const v of values) expect(d, con).toContain(`'${v}'`);
      }
      // dev_outbox (db/migrations-dev) не меняется: FakeSmsGateway пишет otp_login (ADR-115 п. 25)
      expect(await def('dev_outbox_template_key_chk')).not.toContain('otp_kiosk_order');
    });
  });

  it('повторный migrate — 0 изменений (журнал и отпечаток схемы)', async () => {
    const before = await withDb((c) => schemaFingerprint(c, SCHEMAS));
    const again = await run(env, { seed: false }, silent);
    expect(again.applied).toEqual([]);
    expect(again.devApplied).toEqual([]);
    expect(await withDb((c) => schemaFingerprint(c, SCHEMAS))).toEqual(before);
  });

  it('T-KIOSK-025: CHECK канала kiosk — только наличные и самовывоз, без ручной скидки и долга; скидка клиента 1С допустима', async () => {
    await withDb(async (c) => {
      await c.query(`INSERT INTO users (id, kind, status) VALUES ($1, 'kiosk', 'active')`, [KIOSK_USER]);
      await c.query(
        `INSERT INTO devices (id, user_id, device_key, platform) VALUES ($1, $2, '3f2b8c1e-1a2b-4c3d-8e4f-5a6b7c8d9e22', 'android')`,
        [KIOSK_DEVICE, KIOSK_USER],
      );
      const channel = { code: '23514', constraint: 'orders_kiosk_channel_chk' };
      const variants: Record<string, Record<string, string | null>> = {
        credit: { payment_method: 'credit' },
        qr: { payment_method: 'qr_bakai' },
        discountPercent: { discount_percent: '5.00' },
        manualDiscount: { manual_discount_total: '10.00', discount_total: '10.00', total: '90.00' },
        discountApproval: { discount_approved_by_user_id: STAFF },
        creditApproval: { credit_approved_by_user_id: STAFF },
        delivery: {
          delivery_method: 'delivery',
          delivery_address: 'г. Бишкек, ул. Токтогула, 1',
          delivery_recipient_phone_e164: '+996700000203',
        },
      };
      for (const [label, overrides] of Object.entries(variants)) {
        expect(await rejection(() => insertOrder(c, overrides)), label).toEqual(channel);
      }
      // kiosk_customer_match — ровно у канала kiosk (orders_kiosk_match_chk), значения — single|ambiguous|none
      expect(await rejection(() => insertOrder(c, { kiosk_customer_match: null }))).toEqual({
        code: '23514',
        constraint: 'orders_kiosk_match_chk',
      });
      expect(
        await rejection(() =>
          insertOrder(c, { created_via: 'staff', created_by_user_id: STAFF, receiver_phone_e164: null }),
        ),
      ).toEqual({ code: '23514', constraint: 'orders_kiosk_match_chk' });
      expect(await rejection(() => insertOrder(c, { kiosk_customer_match: 'several' }))).toEqual({
        code: '23514',
        constraint: 'orders_kiosk_customer_match_chk',
      });

      // Допустимая заявка: наличные, самовывоз, скидка клиента 1С 5 % (Р-05 (а)); принята сервером (submitting)
      await insertOrder(c, {
        id: KIOSK_ORDER_ID,
        status: 'submitting',
        onec_sync_state: 'pending',
        submitted_at: new Date().toISOString(),
        device_id: KIOSK_DEVICE,
        customer_discount_percent: '5.00',
        customer_discount_total: '5.00',
        discount_total: '5.00',
        total: '95.00',
        pd_notice_version: '2026-11-04',
        pd_notice_sha256: 'a'.repeat(64),
      });
      const row = await c.query(
        `SELECT created_via, payment_method::text, delivery_method::text, customer_discount_total, manual_discount_total, total
           FROM orders WHERE id = $1`,
        [KIOSK_ORDER_ID],
      );
      expect(row.rows).toEqual([
        {
          created_via: 'kiosk',
          payment_method: 'cash',
          delivery_method: 'pickup',
          customer_discount_total: '5.00',
          manual_discount_total: '0.00',
          total: '95.00',
        },
      ]);
    });
  });

  it('DATA-303: маскирование номера заявки kiosk под pos_app после submit (E.164 → NULL, маска — отдельным столбцом)', async () => {
    await withDb(async (c) => {
      await c.query('BEGIN');
      try {
        // как запрос приложения: роль pos_app, row_version + 1 (07 §8.3); заморозка финансовых полей не мешает
        await c.query('SET LOCAL ROLE pos_app');
        const masked = await c.query(
          `UPDATE orders SET receiver_phone_e164 = NULL, row_version = row_version + 1,
                  receiver_phone_masked = '+996 ' || substr(receiver_phone_e164, 5, 1) || '** *** *' || right(receiver_phone_e164, 2)
            WHERE created_via = 'kiosk' AND receiver_phone_e164 IS NOT NULL RETURNING receiver_phone_masked`,
        );
        expect(masked.rows).toEqual([{ receiver_phone_masked: '+996 7** *** *03' }]);
        const again = await c.query(
          `UPDATE orders SET receiver_phone_e164 = NULL, row_version = row_version + 1
            WHERE created_via = 'kiosk' AND receiver_phone_e164 IS NOT NULL`,
        );
        expect(again.rowCount).toBe(0);
        await c.query('COMMIT');
      } catch (e) {
        await c.query('ROLLBACK');
        throw e;
      }
      const after = await c.query(
        `SELECT receiver_phone_e164, receiver_phone_masked, submitted_at IS NOT NULL AS submitted FROM orders WHERE id = $1`,
        [KIOSK_ORDER_ID],
      );
      expect(after.rows).toEqual([
        { receiver_phone_e164: null, receiver_phone_masked: '+996 7** *** *03', submitted: true },
      ]);
      // Маска в столбце E.164 по-прежнему отклоняется (CHECK E.164 не ослаблен, 07 §5.37)
      expect(
        await rejection(() =>
          c.query(`UPDATE orders SET receiver_phone_e164 = '+996 7** *** *03' WHERE id = $1`, [KIOSK_ORDER_ID]),
        ),
      ).toEqual({ code: '23514', constraint: 'orders_receiver_phone_e164_chk' });
    });
  });
});
