import type { ReturnReason } from '../common/enums.js';
import { qty3 } from './returns.presenter.js';
import type { ReturnItemRow, ReturnRow, ShipmentLineRow } from './returns.repository.js';

const BISHKEK_OFFSET_MS = 6 * 3_600_000;

/** Момент `DateTime` контракта 1С: ISO 8601 со смещением `+06:00` (ONEC-058). */
export function bishkekIso(d: Date): string {
  return `${new Date(d.getTime() + BISHKEK_OFFSET_MS).toISOString().slice(0, 19)}+06:00`;
}

/** Подписи причин (10 RET-004) — текст причины для 1С, если кассир не указал комментарий. */
export const RETURN_REASON_RU: Readonly<Record<ReturnReason, string>> = {
  defect: 'Брак',
  wrong_item: 'Пересорт',
  not_suitable: 'Не подошёл',
  surplus: 'Излишек',
  seller_error: 'Ошибка продавца',
  other: 'Иное',
};

/** Строка заявки, которую нельзя передать в 1С: у товара (или характеристики) строки реализации нет ссылки 1С. */
export interface UnlinkedReturnLine {
  /** Индекс строки в заявке (`items[i]` ответа). */
  readonly itemIndex: number;
  /** Номер строки заказа POS (`items[].orderLineNo` запроса/ответа). */
  readonly orderLineNo: number;
  /** Номер строки реализации (`ReturnLine.shipmentLineNumber`). */
  readonly shipmentLineNumber: number;
  readonly productName: string;
  /** Чего нет: `productRef` — номенклатуры 1С, `variantRef` — характеристики 1С у варианта не по умолчанию. */
  readonly missing: 'productRef' | 'variantRef';
}

/**
 * Ошибка данных заявки (разбор 98 п. 74; ТЗ для 1С 6.17: `lines[].productRef` обязателен): строки без ссылки 1С на
 * номенклатуру или характеристику. Заявка с такими строками в outbox не ставится — `null` вместо ссылки 1С отклонила бы
 * (или, для характеристики, исказила бы) заявку.
 */
export class ReturnLinesNotLinkedError extends Error {
  constructor(readonly lines: readonly UnlinkedReturnLine[]) {
    super(`return request: ${lines.length} line(s) without 1C refs`);
    this.name = 'ReturnLinesNotLinkedError';
  }
}

/** Строки заявки без ссылок 1С (`[]` — все строки можно передать). */
export function unlinkedReturnLines(
  items: readonly ReturnItemRow[],
  lines: readonly ShipmentLineRow[],
): UnlinkedReturnLine[] {
  const byId = new Map(lines.map((l) => [l.id, l]));
  const out: UnlinkedReturnLine[] = [];
  items.forEach((i, itemIndex) => {
    const l = byId.get(i.shipment_item_id);
    const missing = !l?.product_ref ? 'productRef' : l.variant_ref_missing ? 'variantRef' : null;
    if (missing) {
      out.push({
        itemIndex,
        orderLineNo: Number(i.order_line_no), // money-double: allow — номер строки документа
        shipmentLineNumber: Number(i.onec_line_no), // money-double: allow — номер строки документа
        productName: i.product_name_snapshot,
        missing,
      });
    }
  });
  return out;
}

/**
 * Тело `POST /pos/v1/returns` (контракт 1С `ReturnCreateRequest`; 05 §6.3, ONEC-048): заявка на основании
 * реализации, строки — номера строк реализации (`shipmentLineNumber`), количество — строка с тремя знаками.
 * `externalId` = `return_requests.id` (ключ идемпотентности 1С; канал записи подставляет его же — 07 §5.55).
 * Строка без ссылки 1С на номенклатуру/характеристику — `ReturnLinesNotLinkedError` (`productRef` всегда строка).
 */
export function returnRequestPayload(
  r: ReturnRow,
  items: readonly ReturnItemRow[],
  lines: readonly ShipmentLineRow[],
  requestedAt: Date,
): Record<string, unknown> {
  const unlinked = unlinkedReturnLines(items, lines);
  if (unlinked.length > 0) throw new ReturnLinesNotLinkedError(unlinked);
  const byId = new Map(lines.map((l) => [l.id, l]));
  return {
    externalId: r.id,
    shipmentRef: r.shipment_ref,
    orderExternalId: r.order_id,
    customerRef: r.customer_ref,
    reasonCode: r.reason,
    reasonText: r.reason_comment ?? RETURN_REASON_RU[r.reason],
    requestedAt: bishkekIso(requestedAt),
    lines: items.map((i) => {
      // Строка есть и связана с 1С — проверено `unlinkedReturnLines` выше.
      const l = byId.get(i.shipment_item_id) as ShipmentLineRow & { product_ref: string };
      return {
        shipmentLineNumber: Number(i.onec_line_no), // money-double: allow — номер строки документа
        productRef: l.product_ref,
        variantRef: l.variant_ref,
        quantity: qty3(i.quantity),
      };
    }),
  };
}
