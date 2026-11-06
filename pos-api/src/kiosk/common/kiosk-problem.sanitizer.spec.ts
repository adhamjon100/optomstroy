import { describe, expect, it } from 'vitest';
import { toProblem } from '../../common/problem-details/problem-details.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { SalesDomainError } from '../../sales-domain/domain-error.js';
import {
  KIOSK_CONFLICT_FIELDS,
  KIOSK_ONEC_REJECTED_DETAIL,
  sanitizeKioskConflict,
  sanitizeKioskProblem,
} from './kiosk-problem.sanitizer.js';

/**
 * Очистка ответов-ошибок планшету (08 §2.4 «Коды и отказы планшета магазина» п. 3, §4.25.2; 11 SEC-141; P-002 §8.4
 * п. 5; ADR-115) — без БД; **тестовые данные** (идентификаторы и суммы вымышленные). Ответ проверяется и как
 * исключение, и как тело Problem, которое сохранит интерсептор идемпотентности (`toProblem`).
 */
const V1 = '0192f3a1-6c3e-7a1b-9f00-000000000a01';
const V2 = '0192f3a1-6c3e-7a1b-9f00-000000000a02';
const V3 = '0192f3a1-6c3e-7a1b-9f00-000000000a03';

function body(e: unknown): Record<string, unknown> {
  return toProblem(e, 'req-test', 'https://pos-test.example.kg').body;
}

function sanitized(e: unknown): ProblemException {
  const r = sanitizeKioskProblem(e);
  expect(r).toBeInstanceOf(ProblemException);
  return r as ProblemException;
}

describe('kiosk-problem.sanitizer: ответы планшету без цены карточки, остатков, current и текста 1С', () => {
  it('T-KIOSK-058 conflicts only variantId, kind, stockLevel: oldPrice/newPrice/available/requested/factor убраны', () => {
    const e = new ProblemException('STOCK_INSUFFICIENT', {
      detail: 'Корзина изменилась: проверьте цены и остатки.',
      conflicts: [
        {
          variantId: V1,
          kind: 'stock_insufficient',
          requested: { value: '5.000', unitId: 'u', baseValue: '5.000' },
          available: '2.000',
          stockLevel: 'low',
        },
        { variantId: V2, kind: 'qty_not_multiple', requested: { value: '3.000' }, factor: '2.000' },
        {
          variantId: V3,
          kind: 'price_changed',
          oldPrice: { amount: '100.00', currency: 'KGS' },
          newPrice: { amount: '80.00', currency: 'KGS' },
        },
      ],
    });
    const s = sanitized(e);
    expect(s.code).toBe('STOCK_INSUFFICIENT');
    expect(s.getStatus()).toBe(422);
    expect(s.detail).toBe('Корзина изменилась: проверьте цены и остатки.');
    expect(s.extensions.conflicts).toEqual([
      { variantId: V1, kind: 'stock_insufficient', stockLevel: 'low' },
      { variantId: V2, kind: 'qty_not_multiple' },
      { variantId: V3, kind: 'price_changed' },
    ]);
    const json = JSON.stringify(body(s));
    for (const k of ['oldPrice', 'newPrice', 'available', 'requested', 'factor', '80.00', '100.00']) {
      expect(json).not.toContain(k);
    }
    for (const c of s.extensions.conflicts as Record<string, unknown>[]) {
      expect(Object.keys(c).every((k) => (KIOSK_CONFLICT_FIELDS as readonly string[]).includes(k))).toBe(true);
    }
  });

  it('T-KIOSK-058 элемент conflicts: не объект → {}; stockLevel только если есть', () => {
    expect(sanitizeKioskConflict(null)).toEqual({});
    expect(sanitizeKioskConflict('x')).toEqual({});
    expect(sanitizeKioskConflict({ variantId: V1, kind: 'variant_unavailable', extra: 1 })).toEqual({
      variantId: V1,
      kind: 'variant_unavailable',
    });
  });

  it('409 VERSION_CONFLICT — без current (полная корзина CartService.assertVersion)', () => {
    const e = new ProblemException('VERSION_CONFLICT', {
      detail: 'Корзина изменена на другом устройстве.',
      current: { id: V1, rowVersion: 7, totals: { total: { amount: '152.00' } }, customer: { id: V2 } },
    });
    const s = sanitized(e);
    expect(s.getStatus()).toBe(409);
    expect(s.extensions).toEqual({});
    expect(body(s)).not.toHaveProperty('current');
    expect(JSON.stringify(body(s))).not.toContain('152.00');
  });

  it('422 ONEC_REJECTED — без onec и без текста 1С; нейтральный текст', () => {
    const e = new ProblemException('ONEC_REJECTED', {
      detail: '1С: превышен лимит долга клиента ООО «Тест»',
      onec: { code: 'POS_E_VALIDATION', message: 'превышен лимит долга клиента' },
    });
    const s = sanitized(e);
    expect(s.code).toBe('ONEC_REJECTED');
    expect(s.getStatus()).toBe(422);
    expect(s.detail).toBe(KIOSK_ONEC_REJECTED_DETAIL);
    const b = body(s);
    expect(b).not.toHaveProperty('onec');
    expect(JSON.stringify(b)).not.toContain('долга');
  });

  it('409 DEVICE_MISMATCH → 404 NOT_FOUND; ORDER_STATE_INVALID (possible_duplicate, cart_*) → 422 CART_EMPTY', () => {
    const dm = sanitized(new ProblemException('DEVICE_MISMATCH', { detail: 'Код запрошен на другом устройстве.' }));
    expect(dm.code).toBe('NOT_FOUND');
    expect(dm.getStatus()).toBe(404);
    const dup = sanitized(
      new ProblemException('ORDER_STATE_INVALID', {
        detail: 'Похожий заказ POS-2026-000001 создан минуту назад.',
        reason: 'possible_duplicate',
        possibleDuplicateOrderId: V1,
        possibleDuplicatePublicNumber: 'POS-2026-000001',
      }),
    );
    expect(dup.code).toBe('CART_EMPTY');
    expect(dup.getStatus()).toBe(422);
    expect(JSON.stringify(body(dup))).not.toMatch(/possible|POS-2026-000001/);
    const conv = sanitized(
      new ProblemException('ORDER_STATE_INVALID', {
        resource: 'cart',
        reason: 'cart_converted',
        currentStatus: 'converted',
      }),
    );
    expect(conv.code).toBe('CART_EMPTY');
    expect(conv.extensions).toEqual({});
  });

  it('PRICE_CHANGED preview_*: reason и conflicts [] остаются, суммы предпросмотра — нет', () => {
    const s = sanitized(
      new ProblemException('PRICE_CHANGED', {
        detail: 'Итоги изменились после предпросмотра — обновите оформление.',
        reason: 'preview_total_changed',
        conflicts: [],
        previewTotal: { amount: '100.00', currency: 'KGS' },
        total: { amount: '80.00', currency: 'KGS' },
      }),
    );
    expect(s.extensions).toEqual({ reason: 'preview_total_changed', conflicts: [] });
    const ok = new ProblemException('PRICE_CHANGED', { reason: 'preview_token_invalid', conflicts: [] });
    expect(sanitizeKioskProblem(ok)).toBe(ok);
  });

  it('коды кода и ключа: attemptsLeft, retryAfter и Retry-After сохраняются; прочее — как есть', () => {
    const inv = new ProblemException('OTP_INVALID', { detail: 'Неверный код. Осталось попыток: 3.', attemptsLeft: 3 });
    expect(sanitizeKioskProblem(inv)).toBe(inv);
    const locked = sanitized(new ProblemException('OTP_LOCKED', { retryAfter: 42, challengeExtra: 'x' }));
    expect(locked.extensions).toEqual({ retryAfter: 42 });
    expect(locked.headers['Retry-After']).toBe('42');
    const forb = new ProblemException('FORBIDDEN', { reason: 'kiosk_warehouse_unavailable' });
    expect(sanitizeKioskProblem(forb)).toBe(forb);
    const vf = new ProblemException('VALIDATION_FAILED', {
      status: 400,
      errors: [{ field: 'price', rule: 'forbidden_field', message: 'Поле не принимается' }],
    });
    expect(sanitizeKioskProblem(vf)).toBe(vf);
  });

  it('доменная ошибка продаж → Problem и очистка; программная ошибка — без изменений (500 INTERNAL)', () => {
    const d = sanitized(new SalesDomainError('VERSION_CONFLICT', 'Корзина изменена.', { current: { rowVersion: 3 } }));
    expect(d.code).toBe('VERSION_CONFLICT');
    expect(d.extensions).toEqual({});
    const bug = new Error('сбой');
    expect(sanitizeKioskProblem(bug)).toBe(bug);
  });
});
