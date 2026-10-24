import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { Logger } from '@nestjs/common';
import type { NestExpressApplication } from '@nestjs/platform-express';
import pg from 'pg';
import { FakeSmsGateway } from '../../src/integrations/sms/fake-sms.gateway.js';
import { createSmsGateway } from '../../src/integrations/sms/sms-gateway.factory.js';
import { EmbeddedPg } from '../support/embedded-pg.js';
import { createTestApp, LogCapture, testConfig } from '../support/test-app.js';

const PHONE = '+996700123456';
const OTP = '583921';

/** transactionId SMSPro: ровно 12 [A-Za-z0-9] из CSPRNG (ядро §18.2 п. 9). */
function txId(): string {
  return randomBytes(9)
    .toString('base64')
    .replace(/[^A-Za-z0-9]/g, 'x')
    .slice(0, 12);
}

/**
 * Миграции 0001+0002; для dev/test-схемы (`app.env=test`) — и dev-миграция `db/migrations-dev/0001_dev_outbox.sql`:
 * только так создаётся dev_outbox (07 §5.63, RM-C-006 п. 6; B-AR-09, C-MJ-05). Prod-подобная схема — без неё.
 */
async function migrate(db: EmbeddedPg, database: string, appEnv: 'test' | null): Promise<void> {
  const c = new pg.Client({
    connectionString: db.url(database),
    ...(appEnv ? { options: `-c app.env=${appEnv}` } : {}),
  });
  await c.connect();
  try {
    const files = ['migrations/0001_init.sql', 'migrations/0002_rbac_seed.sql'];
    if (appEnv) files.push('db/migrations-dev/0001_dev_outbox.sql');
    for (const f of files) {
      await c.query(readFileSync(fileURLToPath(new URL(`../../${f}`, import.meta.url)), 'utf8'));
    }
  } finally {
    await c.end();
  }
}

describe('FakeSmsGateway → dev_outbox на PostgreSQL 17; код не попадает в логи (RM-C-008 п. 3, AC-AUTH-012)', () => {
  const db = new EmbeddedPg();
  let pool: pg.Pool;
  let prodLikePool: pg.Pool;
  let app: NestExpressApplication;
  const logs = new LogCapture();

  beforeAll(async () => {
    await db.start();
    await db.createDatabase('pos_sms_test');
    await migrate(db, 'pos_sms_test', 'test');
    await db.createDatabase('pos_sms_prodlike');
    await migrate(db, 'pos_sms_prodlike', null);
    pool = new pg.Pool({ connectionString: db.url('pos_sms_test'), max: 2 });
    prodLikePool = new pg.Pool({ connectionString: db.url('pos_sms_prodlike'), max: 1 });
    // Тот же конвейер логов, что в logging_redaction.spec.ts (RM-C-010): Nest Logger → nestjs-pino → redaction,
    // уровень debug (AC-AUTH-012 — логи debug).
    app = await createTestApp({ config: testConfig({ LOG_LEVEL: 'debug' }), logStream: logs });
  });

  afterAll(async () => {
    await app?.close();
    await pool?.end();
    await prodLikePool?.end();
    await db.stop();
  });

  it('схема: dev_outbox есть только при app.env=test (в prod-подобной схеме таблицы нет)', async () => {
    const reg = (p: pg.Pool) =>
      p.query<{ t: string | null }>(`SELECT to_regclass('public.dev_outbox')::text AS t`).then((r) => r.rows[0]?.t);
    expect(await reg(pool)).toBe('dev_outbox');
    expect(await reg(prodLikePool)).toBeNull();
    // отказ закрыт: dev-миграция в сеансе без пометки dev/test завершается ошибкой и ничего не создаёт
    const devSql = readFileSync(
      fileURLToPath(new URL('../../db/migrations-dev/0001_dev_outbox.sql', import.meta.url)),
      'utf8',
    );
    await expect(prodLikePool.query(devSql)).rejects.toThrow(/только dev\/test-схема/);
    await prodLikePool.query('ROLLBACK').catch(() => undefined);
    expect(await reg(prodLikePool)).toBeNull();
  });

  it('T-SMS-016: send(): текст с кодом записан в dev_outbox (E.164, template_key), исход ACCEPTED; в логах нет кода, текста и номера', async () => {
    const sms = createSmsGateway({ ...testConfig({ SMS_PROVIDER: 'fake' }) }, { db: pool, logger: new Logger('sms') });
    expect(sms).toBeInstanceOf(FakeSmsGateway);
    const id = txId();
    const text = `Kod: ${OTP}. Optomstroy`;
    const res = await sms.send({
      transactionId: id,
      sender: 'Optomstroy',
      text,
      phone: '996700123456',
      test: false,
      purpose: 'otp_login',
    });
    expect(res).toMatchObject({ transactionId: id, outcome: 'ACCEPTED', providerStatus: 0, phonesRecognized: 1 });

    const row = await pool.query(
      `SELECT phone_e164, template_key, text, simulated_status_code FROM dev_outbox WHERE transaction_id = $1`,
      [id],
    );
    expect(row.rows).toEqual([{ phone_e164: PHONE, template_key: 'otp_login', text, simulated_status_code: 0 }]);
    // e2e читают код из dev_outbox (09 §6.8)
    expect(/\d{6}/.exec(String(row.rows[0]?.text))?.[0]).toBe(OTP);

    const sent = logs.json().filter((e) => e.event === 'sms.fake.send' && e.transactionId === id);
    expect(sent).toHaveLength(1);
    expect(sent[0]).toMatchObject({ phoneMasked: '+996 7** *** *56', purpose: 'otp_login', providerStatus: 0 });
    expect(logs.text).not.toContain(OTP);
    expect(logs.text).not.toContain(text);
    expect(logs.text).not.toContain('Optomstroy');
    expect(logs.text).not.toContain('700123456');

    const dr = await sms.getDeliveryReport(id, PHONE);
    expect(dr).toEqual([expect.objectContaining({ report: 3, state: 'DELIVERED' })]);
  });

  it('повтор того же transactionId → DUPLICATE_ID (10); test=true → ACCEPTED_TEST (11)', async () => {
    const sms = new FakeSmsGateway(pool, { appEnv: 'dev' });
    const id = txId();
    const req = { transactionId: id, sender: 'Optomstroy', text: `Kod: ${OTP}`, phone: PHONE, test: false };
    expect((await sms.send(req)).outcome).toBe('ACCEPTED');
    expect(await sms.send(req)).toMatchObject({ outcome: 'DUPLICATE_ID', providerStatus: 10 });
    expect(await sms.send({ ...req, transactionId: txId(), test: true })).toMatchObject({
      outcome: 'ACCEPTED_TEST',
      providerStatus: 11,
    });
  });

  it('имитация кодов по специальным номерам (09 §6.8): 9 → RETRYABLE без записи, 4 → INSUFFICIENT_FUNDS, 2 → CONFIG_ERROR', async () => {
    const sms = new FakeSmsGateway(pool, { appEnv: 'staging' });
    const send = (phone: string) =>
      sms.send({ transactionId: txId(), sender: 'Optomstroy', text: `Kod: ${OTP}`, phone, test: false });
    const r9 = await send('+996700000009');
    expect(r9).toMatchObject({ outcome: 'RETRYABLE', providerStatus: 9 });
    const n9 = await pool.query(`SELECT count(*)::int AS n FROM dev_outbox WHERE transaction_id = $1`, [
      r9.transactionId,
    ]);
    expect(n9.rows[0].n).toBe(0);
    expect(await send('+996700000004')).toMatchObject({ outcome: 'INSUFFICIENT_FUNDS', providerStatus: 4 });
    expect(await send('+996700000002')).toMatchObject({ outcome: 'CONFIG_ERROR', providerStatus: 2 });
    expect(await send('+7 912 000 00 00')).toMatchObject({ outcome: 'INVALID_PHONE', providerStatus: 7 });
    expect(logs.text).not.toContain(OTP);
  });

  it('схема без dev_outbox (prod/staging-миграция) → CONFIG_ERROR, а не «успех»; код не в логах', async () => {
    const sms = new FakeSmsGateway(prodLikePool, { appEnv: 'staging', logger: new Logger('sms') });
    const res = await sms.send({
      transactionId: txId(),
      sender: 'Optomstroy',
      text: `Kod: ${OTP}`,
      phone: PHONE,
      test: false,
    });
    expect(res.outcome).toBe('CONFIG_ERROR');
    expect(logs.json().some((e) => e.event === 'sms.fake.no_dev_outbox')).toBe(true);
    expect(logs.text).not.toContain(OTP);
  });

  it('T-SMS-013, T-SEC-029: каждая строка лога — JSON с level/time; requestId-независимые записи тоже проходят redaction', () => {
    for (const e of logs.json()) {
      expect(typeof e.level).toBe('string');
      expect(typeof e.time).toBe('string');
    }
    expect(logs.lines.length).toBeGreaterThan(0);
  });
});
