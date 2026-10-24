import { IncomingMessage, ServerResponse } from 'node:http';
import { Socket } from 'node:net';
import { Body, Controller, Logger, Post, Query } from '@nestjs/common';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { IsOptional, IsString } from 'class-validator';
import request from 'supertest';
import { createTestApp, LogCapture } from '../../../test/support/test-app.js';
import { Public } from '../rbac/rbac.decorators.js';
import { ipPrefix, maskPhone, maskPhonesInText, REDACTED, sanitizeLogValue } from './redaction.js';

const PHONE = '+996700123456';
const OTP = '583921';
/** Тестовое значение «пароля» собирается в рантайме, чтобы не выглядеть секретом для scripts/check_secrets.py. */
const FAKE_PWD = ['fake', 'pwd', 'value'].join('-');

class OtpRequestDto {
  @IsString()
  phone!: string;

  @IsOptional()
  @IsString()
  purpose?: string;
}

/** Имитация `POST /auth/otp/request` (реальный модуль auth — этап D): типичные ошибки логирования ПДн. */
@Public()
@Controller('auth/otp')
class OtpProbeController {
  private readonly logger = new Logger('auth');

  @Post('request')
  requestOtp(@Body() dto: OtpRequestDto, @Query('debug') _debug?: string): { challengeId: string } {
    const challengeId = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f55';
    this.logger.log({ event: 'auth.otp.sent', phone: dto.phone, code: OTP, otp: OTP, challengeId }, 'auth.otp.sent');
    this.logger.log(`OTP ${OTP} sent to ${dto.phone}`);
    this.logger.warn({
      event: 'sms.provider.error',
      err: new Error(`SMSPro rejected ${dto.phone}`),
      text: `Kod: ${OTP}`,
    });
    this.logger.log({ smsBody: { to: dto.phone, password: FAKE_PWD, authorization: 'Bearer abc.def' } }, 'sms.request');
    return { challengeId };
  }
}

describe('logging redaction (RM-C-010, SEC-062, SEC-063)', () => {
  let app: NestExpressApplication;
  const logs = new LogCapture();

  beforeAll(async () => {
    app = await createTestApp({ controllers: [OtpProbeController], logStream: logs });
  });

  afterAll(async () => {
    await app.close();
  });

  it('лог запроса OTP не содержит номера телефона целиком и кода; requestId совпадает с ответом', async () => {
    const res = await request(app.getHttpServer())
      .post(`/api/v1/auth/otp/request?phone=${encodeURIComponent(PHONE)}`)
      .set('Authorization', 'Bearer header.payload.signature')
      .send({ phone: PHONE, purpose: 'login' });
    expect(res.status).toBe(201);
    const requestId = String(res.headers['x-request-id']);

    const text = logs.text;
    expect(text).not.toContain(PHONE);
    expect(text).not.toContain('996700123456');
    expect(text).not.toContain('700123456');
    expect(text).not.toContain(OTP);
    expect(text).not.toContain(FAKE_PWD);
    expect(text).not.toContain('header.payload.signature');
    expect(text).not.toContain('abc.def');
    expect(text).toContain('+996 7** *** *56');

    const entries = logs.json();
    const mine = entries.filter((e) => e.requestId === requestId);
    const events = mine.map((e) => e.event ?? e.msg);
    expect(events).toContain('auth.otp.sent');
    expect(events).toContain('http.request');
    for (const e of entries.filter((x) => x.event === 'auth.otp.sent' || x.msg === 'http.request')) {
      expect(e.requestId).toBe(requestId);
    }
    // Каждая строка — валидный JSON с level и time (SEC-061).
    for (const e of entries) {
      expect(typeof e.level).toBe('string');
      expect(typeof e.time).toBe('string');
    }
  });

  it('EQ-SRCH-16: запись http.request — только поля сериализаторов req/res (без заголовков, тел и ПДн)', async () => {
    const res = await request(app.getHttpServer())
      .post(`/api/v1/auth/otp/request?phone=${encodeURIComponent(PHONE)}`)
      .set('Authorization', 'Bearer srch16.payload.signature')
      .set('Cookie', 'sid=srch16-cookie')
      .set('X-Step-Up-Token', 'srch16-step-up')
      .set('X-App-Version', '1.4.2')
      .set('X-Platform', 'android')
      .send({ phone: PHONE });
    const requestId = String(res.headers['x-request-id']);
    const line = logs.json().find((e) => e.requestId === requestId && e.msg === 'http.request');
    expect(line).toBeDefined();
    const req = line?.req as Record<string, unknown>;
    expect(Object.keys(req).sort()).toEqual(['appVersion', 'ipPrefix', 'method', 'platform', 'url'].sort());
    expect(req).toMatchObject({ method: 'POST', appVersion: '1.4.2', platform: 'android' });
    expect(String(req.url)).toContain('+996 7** *** *56');
    expect(line?.res).toEqual({ statusCode: 201 });
    const raw = JSON.stringify(line);
    for (const leak of ['srch16.payload.signature', 'srch16-cookie', 'srch16-step-up', '700123456', 'headers']) {
      expect(raw).not.toContain(leak);
    }
  });

  it('входящий X-Request-Id (UUID) возвращается эхом и попадает в логи; не-UUID заменяется', async () => {
    const rid = '0192f3a1-6c3e-7a1b-9f00-000000000001';
    const res = await request(app.getHttpServer())
      .post('/api/v1/auth/otp/request')
      .set('X-Request-Id', rid)
      .send({ phone: PHONE });
    expect(res.headers['x-request-id']).toBe(rid);
    expect(logs.json().some((e) => e.requestId === rid && e.msg === 'http.request')).toBe(true);

    const injected = await request(app.getHttpServer())
      .post('/api/v1/auth/otp/request')
      .set('X-Request-Id', 'x"},{"event":"fake')
      .send({ phone: PHONE });
    expect(injected.headers['x-request-id']).toMatch(/^[0-9a-f-]{36}$/);
    expect(logs.text).not.toContain('"event":"fake"');
  });
});

describe('redaction helpers', () => {
  it('маска телефона SEC-063: первая и две последние цифры национального номера', () => {
    expect(maskPhone('+996700123400')).toBe('+996 7** *** *00');
    expect(maskPhone('0555 12 34 56')).toBe('+996 5** *** *56');
    expect(maskPhone('12')).toBe('***');
    expect(maskPhonesInText('call +996 700 123 456 now, id 0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f55')).toBe(
      'call +996 7** *** *56 now, id 0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f55',
    );
  });

  it('денай-лист ключей и машинные коды', () => {
    const out = sanitizeLogValue({
      code: '123456',
      error: { code: 'PRICE_CHANGED' },
      refreshToken: 'r',
      pin: '1234',
      newPin: '9999',
      fullName: 'Иванов Иван',
      receivableTotal: '100.00',
      nested: [{ phone: '+996700123456', apiKey: 'k' }],
      requestId: 'abc',
    }) as Record<string, unknown>;
    expect(out.code).toBe(REDACTED);
    expect(out.error).toEqual({ code: 'PRICE_CHANGED' });
    expect(out.refreshToken).toBe(REDACTED);
    expect(out.pin).toBe(REDACTED);
    expect(out.newPin).toBe(REDACTED);
    expect(out.fullName).toBe(REDACTED);
    expect(out.receivableTotal).toBe(REDACTED);
    expect(out.nested).toEqual([{ phone: '+996 7** *** *56', apiKey: REDACTED }]);
    expect(out.requestId).toBe('abc');
  });

  it('EQ-SRCH-16: req/res верхнего уровня не копируются; сырые HTTP-объекты глубже — только метка', () => {
    const req = new IncomingMessage(new Socket());
    req.headers = { authorization: 'Bearer secret.jwt.value', cookie: 'sid=1' };
    const res = new ServerResponse(req);
    // Обход объекта ответа выдал бы себя чтением этого свойства (глубокая копия — 8–10 % CPU на запрос).
    let touched = 0;
    Object.defineProperty(res, 'probe', {
      enumerable: true,
      get: () => {
        touched += 1;
        return 'x';
      },
    });
    const out = sanitizeLogValue({ req, res, responseTime: 3 }) as Record<string, unknown>;
    expect(out.req).toBe(req);
    expect(out.res).toBe(res);
    expect(out.responseTime).toBe(3);
    expect(touched).toBe(0);

    const nested = sanitizeLogValue({ ctx: { req, res }, err: { res }, request: req }) as Record<string, unknown>;
    expect(nested.ctx).toEqual({ req: '[IncomingMessage]', res: '[ServerResponse]' });
    expect(nested.err).toEqual({ res: '[ServerResponse]' });
    expect(nested.request).toBe('[IncomingMessage]');
    expect(JSON.stringify(nested)).not.toContain('secret.jwt.value');
    expect(touched).toBe(0);
  });

  it('усечение IP для ipPrefix', () => {
    expect(ipPrefix('::ffff:192.168.10.77')).toBe('192.168.10.0/24');
    expect(ipPrefix('2001:db8:abcd:12::1')).toBe('2001:db8:abcd::/48');
  });
});
