import { Global, Inject, Injectable, Module } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import fc from 'fast-check';
import PDFDocument from 'pdfkit';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import {
  CREDIT_DECISION_SERVICE,
  NOTIFICATIONS_PORT,
  PAYMENTS_PORT,
  type PaymentsPort,
  PortNotBoundError,
  SALES_PORT_TOKENS,
  SalesPortRegistry,
  SYSTEM_ACTOR,
} from '../../src/common/ports/index.js';
import { OnecError } from '../../src/integrations/onec/onec-error.js';
import { bindSalesPort, createSalesPortRegistry } from '../../src/sales-domain/sales-ports.module.js';
import { createFakeSalesRegistry, InMemoryNotifications } from '../support/sales-ports.fakes.js';
import { ScriptedOnecGateway } from '../support/scripted-onec.gateway.js';

describe('SalesPortRegistry — позднее связывание портов (06 §7.4)', () => {
  it('прокси непривязанного порта: метод бросает PortNotBoundError; служебные свойства не трогают реализацию', async () => {
    const r = new SalesPortRegistry();
    const p = r.proxy(PAYMENTS_PORT);
    expect((p as unknown as { then?: unknown }).then).toBeUndefined();
    await expect(Promise.resolve(p)).resolves.toBe(p); // Nest ждёт значение фабрики — прокси не thenable
    expect(() => p.listForOrder('x')).toThrow(PortNotBoundError);
  });

  it('bind → вызов уходит в реализацию; повторная привязка другой реализацией — ошибка; replace — для тестов', async () => {
    const r = new SalesPortRegistry();
    const a = new InMemoryNotifications();
    r.bind(NOTIFICATIONS_PORT, a);
    const p = r.proxy(NOTIFICATIONS_PORT);
    await p.notify(null, { userId: 'u', kind: 'system', severity: 'info', title: 't', body: 'b', dedupeKey: 'k' });
    expect(a.items).toHaveLength(1);
    expect(() => r.bind(NOTIFICATIONS_PORT, new InMemoryNotifications())).toThrow(/уже привязан/);
    const b = new InMemoryNotifications();
    r.replace(NOTIFICATIONS_PORT, b);
    await p.notify(null, { userId: 'u', kind: 'system', severity: 'info', title: 't', body: 'b', dedupeKey: 'k' });
    expect(b.items).toHaveLength(1);
  });

  it('долг по умолчанию — fail-closed CREDIT_BLOCKED до этапа G (RM-F-003 п. 3); customer — forbidden_role', async () => {
    const r = createSalesPortRegistry();
    const credit = r.proxy(CREDIT_DECISION_SERVICE);
    expect(
      await credit.check(null, {
        actor: { ...SYSTEM_ACTOR, userId: 'u', roles: ['senior_seller'] },
        customerId: 'c',
        total: '1.00',
        override: null,
      }),
    ).toMatchObject({
      allowed: false,
      code: 'CREDIT_BLOCKED',
    });
    expect(
      await credit.check(null, {
        actor: { userId: 'u', roles: ['customer'], isCustomer: true },
        customerId: 'c',
        total: '1.00',
        override: null,
      }),
    ).toMatchObject({
      allowed: false,
      code: 'FORBIDDEN',
      creditReason: 'forbidden_role',
    });
  });

  it('Nest: bindSalesPort в модуле-владельце + @Inject(TOKEN) в потребителе без импорта модуля-владельца', async () => {
    @Injectable()
    class PaymentsImpl implements Partial<PaymentsPort> {
      listForOrder(orderId: string) {
        return Promise.resolve([{ orderId } as never]);
      }
    }
    @Injectable()
    class OrdersConsumer {
      constructor(@Inject(PAYMENTS_PORT) readonly payments: PaymentsPort) {}
    }
    const registry = createSalesPortRegistry();
    @Global()
    @Module({
      providers: [
        { provide: SalesPortRegistry, useValue: registry },
        ...SALES_PORT_TOKENS.map((t) => ({ provide: t, useFactory: () => registry.proxy(t) })),
      ],
      exports: [SalesPortRegistry, ...SALES_PORT_TOKENS],
    })
    class PortsTestModule {}
    @Module({ providers: [...bindSalesPort(PAYMENTS_PORT, PaymentsImpl as never)] })
    class PaymentsOwner {}
    @Module({ providers: [OrdersConsumer], exports: [OrdersConsumer] })
    class OrdersOwner {}
    const ref = await Test.createTestingModule({ imports: [PortsTestModule, PaymentsOwner, OrdersOwner] }).compile();
    await ref.init();
    expect(registry.isBound(PAYMENTS_PORT)).toBe(true);
    expect(await ref.get(OrdersConsumer).payments.listForOrder('o-1')).toEqual([{ orderId: 'o-1' }]);
    await ref.close();
  });

  it('createFakeSalesRegistry подменяет все порты, кроме keep', () => {
    const r = createSalesPortRegistry();
    const real = new InMemoryNotifications();
    r.bind(NOTIFICATIONS_PORT, real);
    const fakes = createFakeSalesRegistry(r, [NOTIFICATIONS_PORT]);
    expect(r.get(NOTIFICATIONS_PORT)).toBe(real);
    expect(r.get(PAYMENTS_PORT)).toBe(fakes.payments);
    expect(fakes.notifications).not.toBe(real);
  });
});

describe('ScriptedOnecGateway — управляемые ответы 1С (тестовые данные)', () => {
  const order = { externalId: '0192f5a0-0000-7000-8000-000000000001' };

  it('по умолчанию — успешные фикстуры; externalId переносится из запроса', async () => {
    const gw = new ScriptedOnecGateway();
    const r = await gw.createOrder(order);
    expect(r.status).toBe(201);
    expect(r.body.externalId).toBe(order.externalId);
  });

  it('очередь шагов: 503 → 409 (фикстура) → 422 → транспорт → успех', async () => {
    const gw = new ScriptedOnecGateway();
    gw.script(
      'createOrder',
      { error: 503 },
      { fixture: 'orders-create.409.stock' },
      { error: 422, code: 'POS_E_VALIDATION' },
      { transport: true },
    );
    const codes: string[] = [];
    for (let i = 0; i < 4; i++) {
      try {
        await gw.createOrder(order);
      } catch (e) {
        codes.push(`${(e as OnecError).status}:${(e as OnecError).code}`);
      }
    }
    expect(codes).toEqual(['503:POS_E_MAINTENANCE', '409:POS_E_STOCK', '422:POS_E_VALIDATION', '0:TRANSPORT']);
    expect((await gw.createOrder(order)).status).toBe(201);
    expect(gw.callsOf('createOrder')).toHaveLength(5);
  });

  it('задержка прерывается signal (таймаут 6000 мс у вызывающего → TIMEOUT); hang до abort', async () => {
    const gw = new ScriptedOnecGateway();
    gw.script('checkCart', { delayMs: 5_000 }).script('createOrder', { hang: true });
    const ac = new AbortController();
    setTimeout(() => ac.abort(), 30);
    await expect(gw.checkCart({}, { signal: ac.signal })).rejects.toMatchObject({ code: 'TIMEOUT', status: 0 });
    const ac2 = new AbortController();
    setTimeout(() => ac2.abort(), 30);
    await expect(gw.createOrder(order, { signal: ac2.signal })).rejects.toMatchObject({ code: 'TIMEOUT' });
    gw.script('checkCart', { delayMs: 10 });
    expect((await gw.checkCart({})).status).toBe(200);
  });

  it('always — постоянный ответ; null — снять', async () => {
    const gw = new ScriptedOnecGateway();
    gw.always('getQrPaymentStatus', { error: 503, code: 'POS_E_QR_UNAVAILABLE' });
    await expect(gw.getQrPaymentStatus('p')).rejects.toBeInstanceOf(OnecError);
    await expect(gw.getQrPaymentStatus('p')).rejects.toMatchObject({ retryable: true });
    gw.always('getQrPaymentStatus', null);
    expect((await gw.getQrPaymentStatus('p')).body.status).toBe('pending');
  });

  it('QR: сумма из запроса, уникальный референс на каждый выпуск; оплата на N-м опросе; другая сумма', async () => {
    const gw = new ScriptedOnecGateway().qrPaidAfterPolls(2);
    const req = {
      externalId: 'pay-1',
      orderExternalId: order.externalId,
      orderRef: null,
      customerRef: null,
      amount: '4465.00',
      currency: 'KGS',
      purpose: 'Оплата заказа (тест)',
      requestedTtlSeconds: 900,
      cashierUserCode: 'T',
    };
    const q1 = await gw.createQrPayment(req);
    const q2 = await gw.createQrPayment(req);
    expect(q1.body.amount).toBe('4465.00');
    expect(q1.body.reference).not.toBe(q2.body.reference);
    const s1 = await gw.getQrPaymentStatus('pay-1');
    expect([s1.body.status, s1.body.paidAmount]).toEqual(['pending', null]);
    const s2 = await gw.getQrPaymentStatus('pay-1');
    expect([s2.body.status, s2.body.paidAmount, s2.body.reference]).toEqual(['paid', '4465.00', q2.body.reference]);
    expect(gw.qrPollCount('pay-1')).toBe(2);
    gw.qrPaidAfterPolls(1, { paidAmount: '100.00' });
    await gw.createQrPayment({ ...req, externalId: 'pay-2' });
    expect((await gw.getQrPaymentStatus('pay-2')).body.paidAmount).toBe('100.00');
  });

  it('reset очищает сценарии и журнал', async () => {
    const gw = new ScriptedOnecGateway();
    gw.always('createOrder', { error: 503 });
    gw.reset();
    expect((await gw.createOrder(order)).status).toBe(201);
    expect(gw.calls).toHaveLength(1);
  });
});

describe('зависимости этапа F: fast-check и pdfkit с кириллическим шрифтом Inter', () => {
  it('fast-check 4.x загружается', () => {
    expect(fc.__version.startsWith('4.')).toBe(true);
  });

  it('pdfkit + Inter (OFL) — PDF с кириллицей рендерится ≤ 2 с', async () => {
    const font = (f: string) => fileURLToPath(new URL(`../../assets/fonts/${f}`, import.meta.url));
    const t0 = Date.now();
    const doc = new PDFDocument({ size: 'A4', margin: 40, info: { Title: 'Счёт на оплату (тест)' } });
    const chunks: Buffer[] = [];
    doc.on('data', (c: Buffer) => chunks.push(c));
    const done = new Promise<void>((resolve) => doc.on('end', () => resolve()));
    doc.registerFont('Inter', font('Inter-Regular.ttf'));
    doc.registerFont('Inter-Bold', font('Inter-Bold.ttf'));
    doc.font('Inter-Bold').fontSize(14).text('Счёт на оплату № POS-2026-000001');
    doc.font('Inter').fontSize(10).text('Нефискальный документ. Итого: 16 007,50 сом');
    doc.end();
    await done;
    const pdf = Buffer.concat(chunks);
    expect(pdf.subarray(0, 5).toString()).toBe('%PDF-');
    expect(pdf.toString('latin1')).toContain('/FontFile2'); // встроен TrueType-шрифт (подмножество Inter)
    expect(Date.now() - t0).toBeLessThan(2_000);
  });
});
