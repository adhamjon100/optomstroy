import { MoneyMath } from '../../common/money/money-math.js';
import { Money, type Quantity } from '../../common/money/money.js';
import { SalesDomainError } from '../domain-error.js';
import { normalizePercent } from './percent.js';

/**
 * Движок цен корзины/заказа (07 §7.3, 10 §11.1, MNY-001…MNY-008; D-19, D-23). Сервер — источник истины: клиент
 * никогда не передаёт цены и итоги. Цена строки — по виду цены корзины (выбор — `resolvePriceListId`, цены — из
 * каталога этапа E через порт `CatalogPricingPort`); формулы — только `MoneyMath` из `common/money` (C-CR-01:
 * распределение ручной скидки с коррекцией в **последней по `line_no`** строке с ненулевой базой).
 *
 * Порядок (10 §11.1): (1) `line_subtotal = round_half_up(unit_price × quantity, 2)` (`quantity` — число упаковок,
 * если цена за упаковку); (2) скидка клиента 1С `c` % построчно без коррекции; (3) ручная скидка документа `p` % к
 * остатку после (2) с распределением по строкам; (4) `total = subtotal − discount_total = Σ line_total`.
 * Округление наличных (Q-016) — отдельно, по `app_settings.cash_rounding` (R1: `none`).
 */
export interface PricingLineInput {
  readonly lineNo: number;
  readonly variantId: string;
  readonly packagingId: string | null;
  /** Количество в единицах цены: базовых единицах или упаковках (если цена за упаковку). */
  readonly quantity: Quantity;
  readonly unitPrice: Money;
}

export type CashRoundingSetting = 'none' | 'to_som';

export interface CartPricingInput {
  readonly lines: readonly PricingLineInput[];
  /** Скидка клиента 1С (`customers.discount_percent` / `discount_rules.source=onec`); `null` — нет (DISC-007). */
  readonly customerDiscountPercent: string | null;
  /** Ручная скидка документа (уже проверенная политикой `checkManualDiscount`), `"0"` — нет. */
  readonly manualDiscountPercent: string;
  /** `app_settings.cash_rounding` (по умолчанию `none`, Q-016); применяется только к оплате наличными. */
  readonly cashRounding?: CashRoundingSetting;
}

export interface PricedLine {
  readonly lineNo: number;
  readonly variantId: string;
  readonly packagingId: string | null;
  readonly quantity: Quantity;
  readonly unitPrice: Money;
  readonly lineSubtotal: Money;
  readonly customerDiscountAmount: Money;
  readonly manualDiscountAmount: Money;
  readonly discountAmount: Money;
  readonly lineTotal: Money;
}

export interface PricedCart {
  readonly lines: readonly PricedLine[];
  readonly subtotal: Money;
  /** Каноническая строка `Percent` (`"5.00"`), `"0.00"` — нет. */
  readonly customerDiscountPercent: string;
  readonly manualDiscountPercent: string;
  readonly customerDiscountTotal: Money;
  readonly manualDiscountTotal: Money;
  readonly discountTotal: Money;
  readonly total: Money;
  /** Разница округления наличных (`totalToPay − total`), `0.00` при `none`. */
  readonly cashRoundingDelta: Money;
  readonly totalToPay: Money;
}

const sum = (xs: readonly Money[]): Money => xs.reduce((a, b) => a.plus(b), Money.ZERO);

export function priceCart(input: CartPricingInput): PricedCart {
  const seen = new Set<number>();
  for (const l of input.lines) {
    if (!Number.isInteger(l.lineNo) || l.lineNo < 1 || seen.has(l.lineNo)) {
      throw new SalesDomainError('VALIDATION_FAILED', 'Номера строк корзины должны быть уникальны и ≥ 1.', {}, 422);
    }
    seen.add(l.lineNo);
    if (l.unitPrice.isNegative()) throw new SalesDomainError('VALIDATION_FAILED', 'Цена не может быть < 0.', {}, 422);
    if (l.quantity.isZero()) throw new SalesDomainError('VALIDATION_FAILED', 'Количество должно быть > 0.', {}, 422);
  }
  // Коррекция копеек — в последней по line_no строке (07 §7.3 п. 4): порядок строк — по line_no.
  const lines = [...input.lines].sort((a, b) => a.lineNo - b.lineNo);
  const customerPercent = normalizePercent(input.customerDiscountPercent ?? '0');
  const manualPercent = normalizePercent(input.manualDiscountPercent);
  const subtotals = lines.map((l) => MoneyMath.lineTotal(l.unitPrice, l.quantity));
  const split = MoneyMath.twoStageDiscount(subtotals, customerPercent, manualPercent);
  const priced: PricedLine[] = lines.map((l, i) => {
    const lineSubtotal = subtotals[i] ?? Money.ZERO;
    const customerDiscountAmount = split.customer[i] ?? Money.ZERO;
    const manualDiscountAmount = split.manual[i] ?? Money.ZERO;
    const discountAmount = customerDiscountAmount.plus(manualDiscountAmount);
    return {
      lineNo: l.lineNo,
      variantId: l.variantId,
      packagingId: l.packagingId,
      quantity: l.quantity,
      unitPrice: l.unitPrice,
      lineSubtotal,
      customerDiscountAmount,
      manualDiscountAmount,
      discountAmount,
      lineTotal: split.lineTotals[i] ?? lineSubtotal.minus(discountAmount),
    };
  });
  const subtotal = sum(subtotals);
  const customerDiscountTotal = sum(split.customer);
  const manualDiscountTotal = sum(split.manual);
  const discountTotal = customerDiscountTotal.plus(manualDiscountTotal);
  const total = split.total;
  const rounding = MoneyMath.cashRounding(total, input.cashRounding === 'to_som' ? 'to_som_half_up' : 'none');
  return {
    lines: priced,
    subtotal,
    customerDiscountPercent: customerPercent,
    manualDiscountPercent: manualPercent,
    customerDiscountTotal,
    manualDiscountTotal,
    discountTotal,
    total,
    cashRoundingDelta: rounding.delta,
    totalToPay: rounding.rounded,
  };
}

/**
 * Инварианты, которые обязаны выполняться для любого результата (и проверяются CHECK/триггером БД, 07 §7.5):
 * Σ line_total = total = subtotal − discount_total; discount = customer + manual (по строкам и итогу);
 * 0 ≤ discount_amount ≤ line_subtotal; все суммы ≥ 0. Возвращает список нарушений (пустой — всё верно).
 */
export function pricingInvariantViolations(p: PricedCart): string[] {
  const v: string[] = [];
  if (!sum(p.lines.map((l) => l.lineTotal)).equals(p.total)) v.push('sum(lineTotal) != total');
  if (!p.subtotal.minus(p.discountTotal).equals(p.total)) v.push('subtotal - discountTotal != total');
  if (!p.customerDiscountTotal.plus(p.manualDiscountTotal).equals(p.discountTotal)) v.push('discount split');
  if (!sum(p.lines.map((l) => l.lineSubtotal)).equals(p.subtotal)) v.push('sum(lineSubtotal) != subtotal');
  for (const l of p.lines) {
    if (!l.customerDiscountAmount.plus(l.manualDiscountAmount).equals(l.discountAmount)) {
      v.push(`line ${l.lineNo}: discount split`);
    }
    if (!l.lineSubtotal.minus(l.discountAmount).equals(l.lineTotal)) v.push(`line ${l.lineNo}: total`);
    if (l.discountAmount.isNegative() || l.discountAmount.compare(l.lineSubtotal) > 0) {
      v.push(`line ${l.lineNo}: discount out of [0, subtotal]`);
    }
    if (l.lineTotal.isNegative()) v.push(`line ${l.lineNo}: negative total`);
  }
  if (p.total.isNegative() || p.discountTotal.isNegative()) v.push('negative totals');
  return v;
}
