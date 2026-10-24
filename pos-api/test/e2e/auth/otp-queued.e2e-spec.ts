import { OTP_PROVIDER } from '../../../src/auth/otp/otp.provider.js';
import { QueuedSmsOtpProvider } from '../../../src/auth/otp/queued-sms-otp.provider.js';
import {
  SMS_DELIVERY_LISTENER,
  type SmsDeliveryListener,
} from '../../../src/notifications/sms/sms-delivery.listener.js';
import { AuthE2e, freshDevice, freshIp, freshPhone } from './support/auth-e2e.js';

/**
 * Интеграция с SMS-контуром RM-D-002 (notifications/sms): `AuthModule.withQueuedSms()` — `sms_outbox(queued)` и
 * задание `sms.send` в транзакции выпуска кода (09 §4.2), текст в задании зашифрован; итог доставки `failed`
 * через порт `SMS_DELIVERY_LISTENER` → челлендж `failed_delivery`, квота номера возвращается (09 §6.8).
 */
describe('auth/otp e2e: доставка через очередь pos-worker (AuthModule.withQueuedSms)', () => {
  const t = new AuthE2e();
  beforeAll(async () => {
    await t.start('auth_otp_queued', {}, {}, 'queued');
  });
  afterAll(async () => {
    await t.stop();
  });

  it('OTP_PROVIDER = QueuedSmsOtpProvider; request → 202, sms_outbox queued + задание sms.send в той же транзакции, без открытого кода', async () => {
    expect(t.app.get(OTP_PROVIDER)).toBeInstanceOf(QueuedSmsOtpProvider);
    const dev = freshDevice();
    const r = await t.otpRequest(freshPhone(), dev, freshIp());
    expect(r.status).toBe(202);
    const ch = await t.pool.query('SELECT sms_outbox_id, status FROM otp_challenges WHERE id = $1', [
      r.body.challengeId,
    ]);
    expect(ch.rows[0].status).toBe('sent');
    const sms = await t.pool.query('SELECT id, status, otp_challenge_id FROM sms_outbox WHERE id = $1', [
      ch.rows[0].sms_outbox_id,
    ]);
    expect(sms.rows[0]).toMatchObject({ status: 'queued', otp_challenge_id: r.body.challengeId });
    const job = t.publishedJobs.at(-1);
    expect(job).toMatchObject({ queue: 'sms.send', inTx: true, data: { smsOutboxId: sms.rows[0].id } });
    expect(JSON.stringify(job?.data)).not.toMatch(/Kod: \d{6}/);
    const st = await t.http.get(`/api/v1/auth/otp/challenges/${r.body.challengeId}`).set('X-Device-Id', dev);
    expect(st.body.delivery).toBe('queued');
  });

  it('SMS_DELIVERY_LISTENER: итог failed → failed_delivery, квота номера возвращена; статус → failed', async () => {
    const phone = freshPhone();
    const dev = freshDevice();
    const r = await t.otpRequest(phone, dev, freshIp());
    const ch = await t.pool.query('SELECT sms_outbox_id FROM otp_challenges WHERE id = $1', [r.body.challengeId]);
    const before = await t.pool.query<{ n: number }>(
      `SELECT coalesce(sum(count), 0)::int AS n FROM rate_limit_counters WHERE scope = 'otp_phone_15m'`,
    );
    const listener = t.app.get<SmsDeliveryListener>(SMS_DELIVERY_LISTENER);
    await t.fdb.db.transaction((tx) =>
      listener.onSendSettled(
        {
          smsOutboxId: ch.rows[0].sms_outbox_id as string,
          otpChallengeId: r.body.challengeId as string,
          status: 'failed',
          outcome: 'PERMANENT',
        },
        tx,
      ),
    );
    const row = await t.pool.query('SELECT status FROM otp_challenges WHERE id = $1', [r.body.challengeId]);
    expect(row.rows[0].status).toBe('failed_delivery');
    const after = await t.pool.query<{ n: number }>(
      `SELECT coalesce(sum(count), 0)::int AS n FROM rate_limit_counters WHERE scope = 'otp_phone_15m'`,
    );
    expect(after.rows[0].n).toBe(before.rows[0].n - 1);
    const st = await t.http.get(`/api/v1/auth/otp/challenges/${r.body.challengeId}`).set('X-Device-Id', dev);
    expect(st.body).toMatchObject({ delivery: 'failed', resendAfterSec: 0 });
    // failed_delivery не мешает новому запросу сразу (cooldown не применяется к недоставленному коду)
    expect((await t.otpRequest(phone, dev, freshIp())).status).toBe(202);
  });
});
