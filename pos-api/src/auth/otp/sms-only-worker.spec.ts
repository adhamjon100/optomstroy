import type { DynamicModule } from '@nestjs/common';
import { DOMAIN_MODULES } from '../../app.module.js';
import type { AppConfig } from '../../common/config/app-config.js';
import { AuthModule } from '../auth.module.js';
import { OTP_PROVIDER } from './otp.provider.js';
import { OtpService } from './otp.service.js';
import { QueuedSmsOtpProvider } from './queued-sms-otp.provider.js';

/**
 * ADR-124 п. 1: SMS приложения отправляет только pos-worker (pos-api → `sms_outbox` → задание `sms.send` → pos-worker
 * → SMSPro). Процесс API подключает AuthModule.withQueuedSms(): порт OTP_PROVIDER — QueuedSmsOtpProvider, который
 * только пишет `sms_outbox` и ставит задание в той же транзакции; шлюз SMSPro из API не вызывается.
 * 12: T-SMS-021 (единственный канал SMS — pos-worker; при smspro тестового кода нет).
 */
describe('ADR-124: SMS только через pos-worker', () => {
  it('API: OTP_PROVIDER → QueuedSmsOtpProvider (AuthModule.withQueuedSms)', () => {
    const auth = DOMAIN_MODULES.find((m): m is DynamicModule => 'module' in m && m.module === AuthModule);
    expect(auth).toBeDefined();
    expect(auth!.providers).toContainEqual({ provide: OTP_PROVIDER, useExisting: QueuedSmsOtpProvider });
  });

  it('второй рубеж ADR-124 п. 4: при SMS_PROVIDER=smspro номер не считается тестовым (тестового кода нет)', () => {
    const PHONE = '+996700000001';
    const mk = (SMS_PROVIDER: 'smspro' | 'fake') =>
      new OtpService(
        {} as never,
        {} as never,
        {
          APP_ENV: 'staging',
          SMS_PROVIDER,
          AUTH_OTP_TEST_MODE: true,
          AUTH_OTP_TEST_CODE: '135790',
          AUTH_OTP_TEST_PHONES: PHONE,
        } as AppConfig,
        {} as never,
        {} as never,
        {} as never,
        {} as never,
        {} as never,
        {} as never,
        {} as never,
      );
    expect(mk('fake').isTestPhone(PHONE)).toBe(true);
    expect(mk('smspro').isTestPhone(PHONE)).toBe(false);
  });
});
