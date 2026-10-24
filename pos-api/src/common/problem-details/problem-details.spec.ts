import { Body, Controller, Get, HttpException, NotFoundException, Post } from '@nestjs/common';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { IsString, MaxLength } from 'class-validator';
import request from 'supertest';
import { createTestApp, testConfig } from '../../../test/support/test-app.js';
import { PROBLEM_CODE_HTTP_STATUS, PROBLEM_CODE_VALUES } from '../enums.js';
import { Public } from '../rbac/rbac.decorators.js';
import { codeToKebab, problemTypeUri, toProblem } from './problem-details.js';
import { ProblemException } from './problem.exception.js';
import { PROBLEM_TITLES_RU } from './problem-titles.ru.js';

class EchoDto {
  @IsString()
  @MaxLength(5)
  name!: string;
}

@Public()
@Controller('probe')
class ProbeController {
  @Get('price')
  price(): never {
    throw new ProblemException('PRICE_CHANGED', {
      detail: 'Цены 2 позиций корзины изменились.',
      conflicts: [{ variantId: 'v1', kind: 'price_changed', oldPrice: '2350.00', newPrice: '2410.00' }],
    });
  }

  @Get('boom')
  boom(): never {
    throw new Error('SELECT * FROM users WHERE phone = +996700123456 — секретная деталь');
  }

  @Get('nest-404')
  nest404(): never {
    throw new NotFoundException('internal path /var/app');
  }

  @Get('rate')
  rate(): never {
    throw new ProblemException('OTP_RATE_LIMITED', { retryAfter: 42 });
  }

  @Post('echo')
  echo(@Body() body: EchoDto): EchoDto {
    return body;
  }
}

const RID = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f55';

describe('problem-details (RFC 9457, 08 §2.4)', () => {
  it('каждый code из 08 §2.4 имеет заголовок ru и HTTP-статус', () => {
    for (const code of PROBLEM_CODE_VALUES) {
      expect(PROBLEM_TITLES_RU[code], code).toBeTruthy();
      expect(PROBLEM_CODE_HTTP_STATUS[code].length, code).toBeGreaterThan(0);
    }
  });

  it('ProblemException → тело с type/title/status/instance/code/requestId и расширениями', () => {
    const p = toProblem(
      new ProblemException('PRICE_CHANGED', { detail: 'd', conflicts: [] }),
      RID,
      'https://api.x.kg/',
    );
    expect(p.status).toBe(422);
    expect(p.body).toEqual({
      type: 'https://api.x.kg/problems/price-changed',
      title: 'Цены изменились',
      status: 422,
      detail: 'd',
      instance: `urn:request:${RID}`,
      code: 'PRICE_CHANGED',
      requestId: RID,
      conflicts: [],
    });
  });

  it('статус вне перечня кода запрещён; VALIDATION_FAILED допускает 400 и 422', () => {
    expect(() => new ProblemException('PRICE_CHANGED', { status: 400 })).toThrow(/недопустим/);
    expect(new ProblemException('VALIDATION_FAILED', { status: 400 }).getStatus()).toBe(400);
    expect(new ProblemException('VALIDATION_FAILED').getStatus()).toBe(400);
    expect(new ProblemException('VALIDATION_FAILED', { status: 422 }).getStatus()).toBe(422);
  });

  it('неизвестная ошибка → 500 INTERNAL без утечки текста/стека; HttpException Nest → код по статусу', () => {
    const p = toProblem(new Error('SQL: secret'), RID, 'https://h');
    expect(p.status).toBe(500);
    expect(p.body.code).toBe('INTERNAL');
    expect(p.body.detail).toBe(`Внутренняя ошибка. Код обращения: ${RID}`);
    expect(JSON.stringify(p.body)).not.toContain('secret');
    expect(toProblem(new HttpException('x', 413), RID, 'https://h').body.code).toBe('PAYLOAD_TOO_LARGE');
    // C-MN-01: прочие статусы Nest — по ближайшему коду 08 §2.4, статус — из перечня кода
    const conflict = toProblem(new HttpException('x', 409), RID, 'https://h');
    expect([conflict.status, conflict.body.code]).toEqual([409, 'VERSION_CONFLICT']);
    const locked = toProblem(new HttpException('x', 423), RID, 'https://h');
    expect([locked.status, locked.body.code]).toEqual([403, 'FORBIDDEN']);
    const teapot = toProblem(new HttpException('x', 418), RID, 'https://h');
    expect([teapot.status, teapot.body.code, teapot.internal]).toEqual([400, 'VALIDATION_FAILED', false]);
    const precondition = toProblem(new HttpException('x', 412), RID, 'https://h');
    expect(precondition.body.code).toBe('VALIDATION_FAILED');
    const unavailable = toProblem(new HttpException('x', 503), RID, 'https://h');
    expect([unavailable.status, unavailable.body.code, unavailable.internal]).toEqual([500, 'INTERNAL', true]);
    expect(unavailable.body.detail).toBe(`Внутренняя ошибка. Код обращения: ${RID}`);
    expect(toProblem(new HttpException('x', 422), RID, 'https://h').status).toBe(422);
    expect(codeToKebab('IDEMPOTENCY_KEY_REUSED')).toBe('idempotency-key-reused');
    expect(problemTypeUri('https://a/', 'NOT_FOUND')).toBe('https://a/problems/not-found');
  });

  describe('ProblemDetailsFilter (HTTP)', () => {
    let app: NestExpressApplication;

    beforeAll(async () => {
      app = await createTestApp({
        config: testConfig({ PUBLIC_BASE_URL: 'https://api.optomstroy.test' }),
        controllers: [ProbeController],
      });
    });

    afterAll(async () => {
      await app.close();
    });

    it('application/problem+json, instance = urn:request:<X-Request-Id>, Content-Language: ru', async () => {
      const res = await request(app.getHttpServer()).get('/api/v1/probe/price').set('X-Request-Id', RID);
      expect(res.status).toBe(422);
      expect(res.headers['content-type']).toMatch(/^application\/problem\+json/);
      expect(res.headers['content-language']).toBe('ru');
      expect(res.headers['x-request-id']).toBe(RID);
      expect(res.body).toMatchObject({
        type: 'https://api.optomstroy.test/problems/price-changed',
        code: 'PRICE_CHANGED',
        instance: `urn:request:${RID}`,
        requestId: RID,
      });
      expect(res.body.conflicts).toHaveLength(1);
    });

    it('500: только нейтральный detail, без SQL и телефона', async () => {
      const res = await request(app.getHttpServer()).get('/api/v1/probe/boom');
      expect(res.status).toBe(500);
      expect(res.body.code).toBe('INTERNAL');
      expect(res.text).not.toMatch(/SELECT|996700123456|секретная/);
      expect(res.body.detail).toBe(`Внутренняя ошибка. Код обращения: ${res.headers['x-request-id']}`);
    });

    it('исключения Nest и неизвестный маршрут → NOT_FOUND без внутреннего текста', async () => {
      const a = await request(app.getHttpServer()).get('/api/v1/probe/nest-404');
      expect(a.body.code).toBe('NOT_FOUND');
      expect(a.text).not.toContain('/var/app');
      const b = await request(app.getHttpServer()).get('/api/v1/nope');
      expect(b.status).toBe(404);
      expect(b.body.code).toBe('NOT_FOUND');
    });

    it('retryAfter дублируется заголовком Retry-After', async () => {
      const res = await request(app.getHttpServer()).get('/api/v1/probe/rate');
      expect(res.status).toBe(429);
      expect(res.headers['retry-after']).toBe('42');
      expect(res.body.retryAfter).toBe(42);
    });

    it('DTO: лишнее поле и нарушение правила → 400 VALIDATION_FAILED с errors[]', async () => {
      const res = await request(app.getHttpServer())
        .post('/api/v1/probe/echo')
        .send({ name: 'toolong', price: '1.00' });
      expect(res.status).toBe(400);
      expect(res.body.code).toBe('VALIDATION_FAILED');
      const rules = (res.body.errors as { field: string; rule: string }[]).map((e) => `${e.field}:${e.rule}`);
      expect(rules).toContain('price:additional_properties');
      expect(rules).toContain('name:maxLength');
    });

    it('битый JSON → 400 VALIDATION_FAILED; тело > 1 MB → 413 PAYLOAD_TOO_LARGE', async () => {
      const bad = await request(app.getHttpServer())
        .post('/api/v1/probe/echo')
        .set('Content-Type', 'application/json')
        .send('{"name":');
      expect(bad.status).toBe(400);
      expect(bad.body.code).toBe('VALIDATION_FAILED');
      const big = await request(app.getHttpServer())
        .post('/api/v1/probe/echo')
        .send({ name: 'x'.repeat(1_100_000) });
      expect(big.status).toBe(413);
      expect(big.body.code).toBe('PAYLOAD_TOO_LARGE');
    });
  });
});
