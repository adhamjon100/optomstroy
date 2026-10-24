import { Logger } from '@nestjs/common';
import { describe, expect, it, vi } from 'vitest';
import type { NotificationsPort } from '../../src/common/ports/index.js';
import type { OnecGateway } from '../../src/integrations/onec/onec-gateway.js';
import { ReturnsOnecService } from '../../src/returns/onec/returns-onec.service.js';
import {
  ReturnLinesNotLinkedError,
  returnRequestPayload,
  unlinkedReturnLines,
} from '../../src/returns/return-onec-payload.js';
import type { ReturnItemRow, ReturnRow, ShipmentLineRow } from '../../src/returns/returns.repository.js';

/**
 * Тело заявки на возврат для 1С и опрос статусов (**тестовые данные**, без БД): разбор 98 п. 74 — строка без ссылки 1С
 * на номенклатуру/характеристику в `ReturnCreateRequest` не попадает (`productRef` обязателен, ТЗ для 1С 6.17);
 * п. 71 — `X-Request-Id` опроса `GET /pos/v1/returns/{uuid}/status` — новый UUID на вызов, контекст — в журнале.
 */
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const PRODUCT_REF = 'a1b2c3d4-0000-4000-8000-000000000001';
const VARIANT_REF = 'a1b2c3d4-0000-4000-8000-000000000101';

const request = {
  id: '11111111-1111-4111-8111-111111111111',
  shipment_ref: '22222222-2222-4222-8222-222222222222',
  order_id: '33333333-3333-4333-8333-333333333333',
  customer_ref: '44444444-4444-4444-8444-444444444444',
  reason: 'defect',
  reason_comment: null,
} as unknown as ReturnRow;

function item(n: number, shipmentItemId: string): ReturnItemRow {
  return {
    shipment_item_id: shipmentItemId,
    onec_line_no: n,
    order_line_no: n,
    quantity: '2',
    product_name_snapshot: `Товар ${n}`,
  } as unknown as ReturnItemRow;
}

function line(id: string, productRef: string | null, variantRef: string | null, variantRefMissing = false) {
  return {
    id,
    product_ref: productRef,
    variant_ref: variantRef,
    variant_ref_missing: variantRefMissing,
  } as unknown as ShipmentLineRow;
}

describe('ReturnCreateRequest: строки без ссылки 1С (98 п. 74)', () => {
  const at = new Date('2026-10-24T04:00:00Z');

  it('все строки связаны → productRef — строка, variantRef — ссылка или null (вариант по умолчанию)', () => {
    const items = [item(1, 's1'), item(2, 's2')];
    const lines = [line('s1', PRODUCT_REF, VARIANT_REF), line('s2', PRODUCT_REF, null)];
    expect(unlinkedReturnLines(items, lines)).toEqual([]);
    expect(returnRequestPayload(request, items, lines, at)).toMatchObject({
      externalId: request.id,
      reasonText: 'Брак',
      requestedAt: '2026-10-24T10:00:00+06:00',
      lines: [
        { shipmentLineNumber: 1, productRef: PRODUCT_REF, variantRef: VARIANT_REF, quantity: '2.000' },
        { shipmentLineNumber: 2, productRef: PRODUCT_REF, variantRef: null, quantity: '2.000' },
      ],
    });
  });

  it('нет ссылки на номенклатуру / строка реализации не найдена / характеристика без ссылки → ошибка данных', () => {
    const items = [item(1, 's1'), item(2, 's2'), item(3, 'nope'), item(4, 's4')];
    const lines = [line('s1', PRODUCT_REF, null), line('s2', null, null), line('s4', PRODUCT_REF, null, true)];
    const expected = [
      { itemIndex: 1, orderLineNo: 2, shipmentLineNumber: 2, productName: 'Товар 2', missing: 'productRef' },
      { itemIndex: 2, orderLineNo: 3, shipmentLineNumber: 3, productName: 'Товар 3', missing: 'productRef' },
      { itemIndex: 3, orderLineNo: 4, shipmentLineNumber: 4, productName: 'Товар 4', missing: 'variantRef' },
    ];
    expect(unlinkedReturnLines(items, lines)).toEqual(expected);
    let err: unknown;
    try {
      returnRequestPayload(request, items, lines, at);
    } catch (e) {
      err = e;
    }
    expect(err).toBeInstanceOf(ReturnLinesNotLinkedError);
    expect((err as ReturnLinesNotLinkedError).lines).toEqual(expected);
    expect((err as Error).name).toBe('ReturnLinesNotLinkedError');
  });
});

describe('опрос статусов заявок: X-Request-Id — UUID на вызов (98 п. 71)', () => {
  function service(gateway: Partial<OnecGateway>, ids: string[]) {
    const db = {
      execute: vi.fn().mockResolvedValue({ rows: ids.map((id) => ({ id })) }),
      transaction: vi.fn(),
    };
    const notifications = { notify: vi.fn(), notifyRole: vi.fn() } as unknown as NotificationsPort;
    return new ReturnsOnecService(db as never, { ONEC_TIMEOUT_MS: 15_000 }, notifications, gateway as OnecGateway);
  }

  it('каждый вызов — свой UUID (не `returns.poll:<id>`); при сбое requestId и id заявки — в журнале', async () => {
    const ids = ['55555555-5555-4555-8555-555555555555', '66666666-6666-4666-8666-666666666666'];
    const seen: { id: string; requestId: string | undefined }[] = [];
    const getReturnRequestStatus = vi.fn((id: string, opts?: { requestId?: string }) => {
      seen.push({ id, requestId: opts?.requestId });
      return id === ids[0]
        ? Promise.resolve({ status: 200, body: { status: 'неизвестный' } })
        : Promise.reject(new Error('socket hang up'));
    });
    const warn = vi.spyOn(Logger.prototype, 'warn').mockImplementation(() => undefined);
    const debug = vi.spyOn(Logger.prototype, 'debug').mockImplementation(() => undefined);
    try {
      const out = await service({ getReturnRequestStatus }, ids).pollOpen();
      expect(out).toEqual({ checked: 2, changed: 0, failed: 1 });
      expect(seen.map((s) => s.id)).toEqual(ids);
      for (const s of seen) expect(s.requestId).toMatch(UUID_V4);
      expect(seen[0]?.requestId).not.toBe(seen[1]?.requestId);
      expect(debug).toHaveBeenCalledWith(
        { event: 'returns.poll', requestId: seen[0]?.requestId, returnRequestId: ids[0] },
        'returns.poll.request',
      );
      expect(warn).toHaveBeenCalledWith(
        {
          event: 'returns.poll',
          requestId: seen[1]?.requestId,
          returnRequestId: ids[1],
          err: 'Error: socket hang up',
        },
        'returns.poll.failed',
      );
    } finally {
      warn.mockRestore();
      debug.mockRestore();
    }
  });
});
