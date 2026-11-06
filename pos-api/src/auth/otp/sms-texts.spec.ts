import { FixedClock } from '../../common/auth/clock.js';
import type { AppConfig } from '../../common/config/app-config.js';
import { countSmsParts } from '../../integrations/sms/fake-sms.gateway.js';
import { type SendRequest, SMS_TEMPLATE_KEYS, type SmsGateway } from '../../integrations/sms/sms-gateway.js';
import type { SmsOutboxService } from '../../notifications/sms/sms-outbox.service.js';
import type { OtpChallengesRepository } from './otp-challenges.repository.js';
import { OtpCircuitBreaker } from './otp-circuit-breaker.js';
import { SmsOtpProvider } from './otp.provider.js';
import { QueuedSmsOtpProvider } from './queued-sms-otp.provider.js';
import type { SmsOutboxRepository } from './sms-outbox.repository.js';
import { KIOSK_ORDER_SMS_TEMPLATE, textFor } from './sms-texts.js';

/**
 * Тексты SMS с кодом (09 §6.7, SMS-036; Р-21 (а); ADR-115 п. 17) — **тестовые данные**: коды и номер `+996 555 000 xxx`
 * вымышлены. Код `kiosk_order` — свой текст-константа (цель и «никому не сообщайте»), одна часть SMS; остальные ключи —
 * прежний `SMS_OTP_TEMPLATE` (паритет текста входа). Оба способа доставки собирают текст одной функцией `textFor`.
 */
const LOGIN_TEMPLATE = 'Kod: {code}. Optomstroy'; // значение по умолчанию env.schema.ts (SMS_OTP_TEMPLATE)
const PHONE = '+996555000417';
const CODE = '204816';

function config(template = LOGIN_TEMPLATE): AppConfig {
  return {
    SMS_OTP_TEMPLATE: template,
    SMSPRO_RETRY_MAX: 0,
    SMSPRO_SENDER: 'Optomstroy',
    SMSPRO_TEST_FLAG: false,
    APP_ENV: 'dev',
    SMSPRO_CB_OPEN_MINUTES: 5,
  } as unknown as AppConfig;
}

describe('тексты SMS кода (09 §6.7; Р-21 (а))', () => {
  it('T-KIOSK-037 texts differ, kiosk text 1 part (countSmsParts): цель «для заявки с планшета», «Никому не сообщайте»', () => {
    const kiosk = textFor('otp_kiosk_order', CODE, LOGIN_TEMPLATE);
    const login = textFor('otp_login', CODE, LOGIN_TEMPLATE);
    expect(kiosk).toBe(`Оптомстрой: код ${CODE} для заявки с планшета. Никому не сообщайте`);
    expect(kiosk).not.toBe(login);
    expect(kiosk).toContain('для заявки с планшета');
    expect(kiosk).toContain('Никому не сообщайте');
    // 65 символов при 6 цифрах, кириллица → UCS-2, одна часть из 70 (длина постоянна — проверка тестом, не при старте)
    expect(kiosk).toHaveLength(65);
    expect(countSmsParts(kiosk)).toBe(1);
    for (const c of ['000000', '999999', '123456']) {
      expect(countSmsParts(textFor('otp_kiosk_order', c, LOGIN_TEMPLATE))).toBe(1);
    }
    // текст — константа кода, а не переменная окружения: SMS_OTP_TEMPLATE на него не влияет
    expect(textFor('otp_kiosk_order', CODE, 'Другой шаблон {code}')).toBe(kiosk);
    expect(KIOSK_ORDER_SMS_TEMPLATE.split('{code}')).toHaveLength(2);
  });

  it('паритет: вход, step-up, смена номера и привязка — прежний SMS_OTP_TEMPLATE (текст входа не меняется)', () => {
    expect(textFor('otp_login', CODE, LOGIN_TEMPLATE)).toBe(`Kod: ${CODE}. Optomstroy`);
    for (const key of SMS_TEMPLATE_KEYS.filter((k) => k !== 'otp_kiosk_order')) {
      expect(textFor(key, CODE, LOGIN_TEMPLATE), key).toBe(LOGIN_TEMPLATE.replace('{code}', CODE));
      expect(textFor(key, CODE, 'Код {code}'), key).toBe(`Код ${CODE}`);
    }
    // спецсимволы замены String.replace в шаблоне не раскрываются
    expect(textFor('otp_login', CODE, '$& {code} $1')).toBe(`$& ${CODE} $1`);
  });

  it('QueuedSmsOtpProvider (очередь pos-worker) кладёт в задание текст textFor', async () => {
    const texts: string[] = [];
    const outbox = {
      enqueue: (input: { text: string }) => {
        texts.push(input.text);
        return Promise.resolve({ id: 'sms-1', providerMessageId: 'AbCdEf123456', status: 'queued' as const });
      },
    } as unknown as SmsOutboxService;
    const p = new QueuedSmsOtpProvider(outbox, config());
    const at = new Date('2026-11-04T09:00:00Z');
    await p.prepare({ challengeId: 'c-1', phoneE164: PHONE, templateKey: 'otp_kiosk_order' }, CODE, at, {} as never);
    await p.prepare({ challengeId: 'c-2', phoneE164: PHONE, templateKey: 'otp_login' }, CODE, at, {} as never);
    expect(texts).toEqual([textFor('otp_kiosk_order', CODE, LOGIN_TEMPLATE), `Kod: ${CODE}. Optomstroy`]);
  });

  it('SmsOtpProvider (отправка процессом pos-api) отдаёт шлюзу текст textFor; purpose — ключ шаблона', async () => {
    const sent: SendRequest[] = [];
    const gateway = {
      provider: 'fake',
      send: (req: SendRequest) => {
        sent.push(req);
        return Promise.resolve({
          transactionId: req.transactionId,
          outcome: 'ACCEPTED',
          providerStatus: 0,
          phonesRecognized: 1,
          smsParts: countSmsParts(req.text),
          latencyMs: 1,
          attempt: 1,
        });
      },
    } as unknown as SmsGateway;
    const outbox = { recordResult: () => Promise.resolve() } as unknown as SmsOutboxRepository;
    const challenges = {} as OtpChallengesRepository;
    const clock = new FixedClock(new Date('2026-11-04T09:00:00Z'));
    const p = new SmsOtpProvider(gateway, config(), clock, outbox, challenges, new OtpCircuitBreaker(clock), {
      retryDelayMs: 0,
    });
    const prepared = { smsOutboxId: 'sms-1', transactionId: 'AbCdEf123456' };
    p.dispatch(prepared, { challengeId: 'c-1', phoneE164: PHONE, templateKey: 'otp_kiosk_order' }, CODE);
    p.dispatch(prepared, { challengeId: 'c-2', phoneE164: PHONE, templateKey: 'otp_login' }, CODE);
    await p.drain();
    expect(sent.map((r) => [r.purpose, r.text])).toEqual([
      ['otp_kiosk_order', textFor('otp_kiosk_order', CODE, LOGIN_TEMPLATE)],
      ['otp_login', `Kod: ${CODE}. Optomstroy`],
    ]);
  });
});
