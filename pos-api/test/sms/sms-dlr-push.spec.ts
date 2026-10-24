import { Global, Module } from '@nestjs/common';
import type { NestExpressApplication } from '@nestjs/platform-express';
import request from 'supertest';
import type { AppConfig } from '../../src/common/config/app-config.js';
import { OTP_HMAC_SECRET_RING, parseSecretRing } from '../../src/common/crypto/index.js';
import { DRIZZLE } from '../../src/common/db/database.module.js';
import { PgBossService } from '../../src/common/jobs/pg-boss.service.js';
import { SMS_METRICS, SMS_TELEMETRY, type SmsTelemetry } from '../../src/integrations/sms/sms-telemetry.js';
import { SmsNotificationsModule, SmsOutboxRepository } from '../../src/notifications/sms/index.js';
import { FoundationDb } from '../foundation/support/foundation-db.js';
import { createTestApp, LogCapture, testConfig } from '../support/test-app.js';

/**
 * Push-DLR `POST /api/v1/integrations/smspro/dlr` (T-SMS-009, AC-AUTH-033; RM-D-002 п. 4–5): poll → 404;
 * push: IP вне `SMSPRO_DLR_ALLOWED_IPS` → 403, из списка → 200 ≤ 1 с и обновление `sms_outbox`; неизвестный `id`
 * → 200 и `sms_dlr_unknown_id_total`; повтор того же отчёта — идемпотентен; пустой список IP → 404.
 */
describe('push-DLR SMSPro: /integrations/smspro/dlr', () => {
  const db = new FoundationDb();
  const apps: NestExpressApplication[] = [];
  const logs = new LogCapture();

  const baseConfig = (over: Record<string, string> = {}): AppConfig =>
    testConfig({
      SMS_PROVIDER: 'smspro',
      SMSPRO_SENDER: 'Optomstroy',
      SMSPRO_LOGIN: 'dlr-test-login',
      SMSPRO_PASSWORD: 'dlr-test-password', // check-secrets: allow — тестовое значение
      ...over,
    });

  async function app(config: AppConfig): Promise<NestExpressApplication> {
    @Global()
    @Module({
      providers: [
        { provide: DRIZZLE, useValue: db.db },
        { provide: PgBossService, useValue: { instance: undefined } },
        { provide: OTP_HMAC_SECRET_RING, useValue: parseSecretRing('OTP_HMAC_SECRET', 'k'.repeat(40), 1, 'dev') },
      ],
      exports: [DRIZZLE, PgBossService, OTP_HMAC_SECRET_RING],
    })
    class SmsTestInfra {}
    const a = await createTestApp({ config, imports: [SmsTestInfra, SmsNotificationsModule], logStream: logs });
    apps.push(a);
    return a;
  }

  let seq = 0;
  async function sentRow(): Promise<{ id: string; pmid: string; number: string }> {
    seq += 1;
    const phone = `+99670${String(8_200_000 + seq).padStart(7, '0')}`;
    const pmid = `DLRPUSH${String(seq).padStart(5, '0')}`;
    const repo = new SmsOutboxRepository(db.db);
    const row = await repo.insert({
      phoneE164: phone,
      templateKey: 'otp_login',
      provider: 'smspro',
      providerMessageId: pmid,
    });
    await repo.markSent(row.id, new Date(), 'ACCEPTED');
    return { id: row.id, pmid, number: phone.slice(1) };
  }

  const report = (entries: { id: string; number: string; report: number }[]) =>
    `<?xml version="1.0" encoding="UTF-8" standalone="yes"?><report xmlns="http://Giper.mobi/schema/DeliveryReport">${entries
      .map(
        (e) =>
          `<dr><id>${e.id}</id><phone><number>${e.number}</number><report>${e.report}</report><sendTime>20261022160000</sendTime><rcvTime>20261022160009</rcvTime></phone></dr>`,
      )
      .join('')}</report>`;

  const post = (a: NestExpressApplication, body: string, ip = '203.0.113.5', type = 'application/xml') =>
    request(a.getHttpServer())
      .post('/api/v1/integrations/smspro/dlr')
      .set('X-Forwarded-For', ip)
      .set('Content-Type', type)
      .send(body);

  beforeAll(async () => {
    await db.start('pos_sms_dlr');
  });
  afterAll(async () => {
    for (const a of apps) await a.close();
    await db.stop();
  });

  it('SMSPRO_DLR_MODE=poll (по умолчанию) → 404; статус обновляется только опросом', async () => {
    const a = await app(baseConfig());
    const r = await sentRow();
    const res = await post(a, report([{ id: r.pmid, number: r.number, report: 3 }]));
    expect(res.status).toBe(404);
    expect(res.body.code).toBe('NOT_FOUND');
    const row = await db.pool.query('SELECT status FROM sms_outbox WHERE id = $1', [r.id]);
    expect(row.rows[0].status).toBe('sent');
  });

  it('push: пустой список IP → 404 (push выключен)', async () => {
    const a = await app({
      ...baseConfig({ SMSPRO_DLR_MODE: 'push', SMSPRO_DLR_ALLOWED_IPS: '203.0.113.5' }),
      SMSPRO_DLR_ALLOWED_IPS: ' ',
    });
    expect((await post(a, report([]))).status).toBe(404);
  });

  describe('SMSPRO_DLR_MODE=push, SMSPRO_DLR_ALLOWED_IPS=203.0.113.5,198.51.100.0/24', () => {
    let a: NestExpressApplication;
    let telemetry: SmsTelemetry;
    beforeAll(async () => {
      a = await app(baseConfig({ SMSPRO_DLR_MODE: 'push', SMSPRO_DLR_ALLOWED_IPS: '203.0.113.5, 198.51.100.0/24' }));
      telemetry = a.get<SmsTelemetry>(SMS_TELEMETRY, { strict: false });
    });

    it('IP из списка, известный id → 200 (пустое тело) ≤ 1 с, sms_outbox → delivered; повтор — идемпотентен', async () => {
      const r = await sentRow();
      const body = report([{ id: r.pmid, number: r.number, report: 3 }]);
      const t0 = Date.now();
      const res = await post(a, body);
      expect(Date.now() - t0).toBeLessThan(1000);
      expect(res.status).toBe(200);
      expect(res.text).toBe('');
      expect(res.headers['cache-control']).toBe('no-store');
      const row1 = (
        await db.pool.query('SELECT status, delivery_status, delivered_at, updated_at FROM sms_outbox WHERE id = $1', [
          r.id,
        ])
      ).rows[0];
      expect(row1).toMatchObject({ status: 'delivered', delivery_status: '3' });
      expect((row1.delivered_at as Date).toISOString()).toBe('2026-10-22T10:00:09.000Z');
      // повтор того же отчёта (вендор повторяет до 3 раз) — 200, строка не меняется
      const again = await post(a, body);
      expect(again.status).toBe(200);
      const row2 = (await db.pool.query('SELECT status, updated_at FROM sms_outbox WHERE id = $1', [r.id])).rows[0];
      expect(row2).toEqual({ status: 'delivered', updated_at: row1.updated_at });
      // подсеть из списка
      const r2 = await sentRow();
      expect((await post(a, report([{ id: r2.pmid, number: r2.number, report: 4 }]), '198.51.100.77')).status).toBe(
        200,
      );
      expect((await db.pool.query('SELECT status FROM sms_outbox WHERE id = $1', [r2.id])).rows[0].status).toBe(
        'failed',
      );
    });

    it('IP вне списка → 403, строка не меняется', async () => {
      const r = await sentRow();
      const res = await post(a, report([{ id: r.pmid, number: r.number, report: 3 }]), '192.0.2.10');
      expect(res.status).toBe(403);
      expect(res.body.code).toBe('FORBIDDEN');
      expect((await db.pool.query('SELECT status FROM sms_outbox WHERE id = $1', [r.id])).rows[0].status).toBe('sent');
    });

    it('неизвестный id (и чужой номер у известного id) → 200, запись не создана, sms_dlr_unknown_id_total +1', async () => {
      const before = telemetry.metrics.value(SMS_METRICS.dlrUnknownIdTotal);
      const r = await sentRow();
      const res = await post(
        a,
        report([
          { id: 'UNKNOWN00001', number: '996700000001', report: 3 },
          { id: r.pmid, number: '996555000000', report: 3 },
        ]),
      );
      expect(res.status).toBe(200);
      expect(telemetry.metrics.value(SMS_METRICS.dlrUnknownIdTotal)).toBe(before + 2);
      expect(
        (await db.pool.query(`SELECT 1 FROM sms_outbox WHERE provider_message_id = 'UNKNOWN00001'`)).rowCount,
      ).toBe(0);
      expect((await db.pool.query('SELECT status FROM sms_outbox WHERE id = $1', [r.id])).rows[0].status).toBe('sent');
    });

    it('не XML → 415; тело > 1 MB → 413; нечитаемый XML → 200 без изменений', async () => {
      expect((await post(a, '{"a":1}', '203.0.113.5', 'application/json')).status).toBe(415);
      const big = `<report>${'<dr><id>x</id></dr>'.repeat(70_000)}</report>`;
      const res = await post(a, big);
      expect(res.status).toBe(413);
      expect(res.body.code).toBe('PAYLOAD_TOO_LARGE');
      expect((await post(a, '<report><dr><id>broken')).status).toBe(200);
      expect((await post(a, report([]), '203.0.113.5', 'text/xml; charset=UTF-8')).status).toBe(200);
    });

    it('логи push-DLR: без полных номеров', () => {
      expect(logs.text).not.toMatch(/99670\d{7}/);
      expect(logs.text).not.toContain('dlr-test-password');
    });
  });
});
