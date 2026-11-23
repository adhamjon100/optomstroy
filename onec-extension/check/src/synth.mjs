// Синтетические данные записи «ПРОВЕРКА POS» (§1.6). Тела собираются из образцов *.request.json 1.2.0.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { selftestGuid } from './util.mjs';
import { isoBishkek, hhmmss, yearBishkek } from './report/time.mjs';

export const SELFTEST_USER = '5e1f7e57-0000-4000-8000-000000000001';
export const LIMITS = { Клиент: 3, Платеж: 2, Заказ: 2, ОплатаQR: 1 };

export class Synth {
  constructor(samplesDir) {
    this.dir = samplesDir;
    this.cache = new Map();
  }

  sample(name) {
    if (!this.cache.has(name)) {
      const j = JSON.parse(fs.readFileSync(path.join(this.dir, name), 'utf8'));
      this.cache.set(name, j.body);
    }
    return structuredClone(this.cache.get(name));
  }

  /** Телефон +996000 + 6 случайных цифр: код оператора 000 не выдаётся — с настоящими клиентами не совпадёт. */
  phone() {
    return '+996000' + String(crypto.randomInt(0, 1e6)).padStart(6, '0');
  }

  /** Номер POS из диапазона проверок POS-YYYY-99NNNN. */
  publicNumber() {
    return `POS-${yearBishkek()}-99${String(crypto.randomInt(0, 1e4)).padStart(4, '0')}`;
  }

  customer({ phone = this.phone(), externalId = selftestGuid(), failOnDuplicate = true } = {}) {
    const b = this.sample('customers-create.request.json');
    b.externalId = externalId;
    b.name = `ПРОВЕРКА POS клиент ${hhmmss()} (удалить)`;
    b.fullName = null;
    b.phone = phone;
    b.taxId = null;
    b.kind = 'individual';
    b.priceListRef = null;
    b.comment = `ПРОВЕРКА POS: создано программой проверки API ${isoBishkek().slice(0, 10)}, можно удалить`;
    b.dedupe = { byPhone: true, failOnDuplicate };
    return b;
  }

  payment({ customerRef, externalId = selftestGuid(), orderExternalId = null, allocations = undefined } = {}) {
    const b = this.sample('payments-create.request.json');
    b.externalId = externalId;
    b.kind = 'cash';
    b.amount = '1.00';
    b.currency = 'KGS';
    b.customerRef = customerRef;
    b.orderExternalId = orderExternalId;
    b.orderRef = null;
    b.receivedAt = isoBishkek();
    b.cashierUserCode = 'system';
    b.post = false;
    b.bankReference = null;
    if (allocations) b.allocations = allocations; else delete b.allocations;
    return b;
  }

  order({ productRef, warehouseRef, priceListRef = null, externalId = selftestGuid() } = {}) {
    const b = this.sample('orders-create.request.retail.json');
    const num = this.publicNumber();
    b.externalId = externalId;
    b.createdAt = isoBishkek();
    b.createdByUserCode = SELFTEST_USER;
    b.customer = { ref: null, contractorRef: null, agreementRef: null };
    b.warehouseRef = warehouseRef;
    b.organizationRef = null;
    b.priceListRef = priceListRef;
    b.paymentMethod = 'cash';
    b.paymentTerms = 'prepayment';
    b.delivery = { method: 'pickup', address: null, receiverName: null, receiverPhone: null, desiredFrom: null, desiredTo: null, courierComment: null };
    b.discountPercent = '0.00';
    b.comment = `POS ${externalId} · ${num} · ПРОВЕРКА POS (удалить)`;
    b.lines = [{
      lineNumber: 1, productRef, variantRef: null, packagingRef: null, quantity: '1.000', packQuantity: null,
      price: '1.00', discountPercent: '0.00', amount: '1.00', supplyOption: (b.lines?.[0]?.supplyOption) || 'from_stock',
    }];
    b.totals = { subtotal: '1.00', discount: '0.00', total: '1.00', currency: 'KGS' };
    b.clientChecks = { pricesSnapshotAt: null, stockSnapshotAt: null };
    return { body: b, publicNumber: num };
  }

  qr({ orderExternalId, publicNumber, externalId = selftestGuid() } = {}) {
    const b = this.sample('payments-qr.request.json');
    b.externalId = externalId;
    b.orderExternalId = orderExternalId;
    b.orderRef = null;
    b.customerRef = null;
    b.amount = '1.00';
    b.currency = 'KGS';
    b.purpose = `Оплата заказа ${publicNumber || this.publicNumber()}`;
    b.requestedTtlSeconds = 900;
    b.cashierUserCode = 'system';
    return b;
  }

  check({ productRef, warehouseRef, priceListRef = null, lines = 2, quantity = '1.000', customerRef = null, paymentMethod = 'cash' } = {}) {
    const b = this.sample('check.request.json');
    b.customerRef = customerRef;
    b.priceListRef = priceListRef;
    b.warehouseRef = warehouseRef;
    b.paymentMethod = paymentMethod;
    b.calculateDiscounts = false;
    b.lines = Array.from({ length: lines }, (_, i) => ({
      productRef, variantRef: null, packagingRef: null, quantity: i === 0 ? quantity : '1.000',
    }));
    return b;
  }

  returnRequest({ customerRef, productRef, externalId = selftestGuid() } = {}) {
    const b = this.sample('returns-create.request.json');
    b.externalId = externalId;
    b.shipmentRef = crypto.randomUUID();
    b.orderExternalId = null;
    b.customerRef = customerRef;
    b.reasonCode = 'other';
    b.reasonText = 'ПРОВЕРКА POS: несуществующая реализация, документ создаваться не должен';
    b.requestedAt = isoBishkek();
    b.lines = [{ shipmentLineNumber: 1, productRef, variantRef: null, quantity: '1.000' }];
    return b;
  }
}
