import { randomBytes, randomUUID } from 'node:crypto';
import { Money } from '../../../common/money/money.js';
import {
  BankApiError,
  type BankOperation,
  type BankQrApi,
  type BankQrCreated,
  type BankQrCreateRequest,
  type BankQrState,
  type BankQrStatus,
} from './bank-qr-api.js';
import { signWebhook, WEBHOOK_SIGNATURE_HEADER, WEBHOOK_TIMESTAMP_HEADER } from './webhook-signature.js';

/** Сдвиг Бишкека (UTC+6, без летнего времени) — граница «дня» выписки. */
const BISHKEK_OFFSET_MS = 6 * 3600_000;
/** Песочница держит в памяти не больше этого числа QR и операций (старые вытесняются первыми). */
const SANDBOX_MAX_ITEMS = 10_000;

interface SandboxQr {
  readonly reference: string;
  readonly merchantPaymentId: string;
  readonly merchantOrderId: string | null;
  readonly amount: string;
  readonly issuedAt: Date;
  readonly expiresAt: Date;
  status: BankQrStatus;
}

export interface SandboxPayInput {
  /** Референс QR (`QrInfo.bankReference`). */
  readonly reference: string;
  /** Сумма оплаты; по умолчанию — сумма QR. Меньше/больше суммы QR — частичная/лишняя оплата (`amount_mismatch`). */
  readonly amount?: string | null;
  /** Принять оплату истёкшего QR (поздняя оплата, `late_payment`); по умолчанию — отказ, как у банка. */
  readonly allowExpired?: boolean;
}

/** Подписанный вебхук, сформированный песочницей (08 §6): сырое тело и заголовки подписи. */
export interface SandboxSignedWebhook {
  readonly rawBody: Buffer;
  readonly headers: Readonly<Record<string, string>>;
  readonly eventId: string;
}

export interface SandboxPayResult {
  readonly operation: BankOperation;
  /** `null` — секрет вебхука не задан (вебхук не отправляется; оплату найдёт опрос статуса или сверка). */
  readonly webhook: SandboxSignedWebhook | null;
}

export interface SandboxBankQrApiOptions {
  /** Секрет HMAC вебхука (`QR_WEBHOOK_SECRET_FILE`) — общий у «банка» и нашего обработчика. */
  readonly webhookSecret?: string | null;
  readonly now?: () => Date;
}

function bishkekDay(d: Date): string {
  return new Date(d.getTime() + BISHKEK_OFFSET_MS).toISOString().slice(0, 10);
}

/**
 * Песочница банка (`BANK_QR_ADAPTER=sandbox`; ADR-123, P-004) — **тестовая реализация** `BankQrApi`, не API
 * настоящего банка. Нужна для тестов, веб-демо и тестового стенда на Windows-сервере, где нельзя ставить отдельную
 * службу: живёт в памяти процесса pos-api (после перезапуска выданные QR забываются — их платежи разбирает кассир или
 * перевыпуск QR). Возможности:
 * - выдача динамического QR с суммой и сроком; повтор на том же платеже, пока QR действует, — тот же QR; перевыпуск
 *   после отмены/истечения — новый референс;
 * - статус и отмена по платежу (последний выпуск);
 * - служебная «оплата» (`pay`): полная, частичная или лишняя сумма, при `allowExpired` — оплата истёкшего QR; оплата
 *   записывается операцией дня и, если задан секрет, оформляется **подписанным** вебхуком (08 §6);
 * - список операций за день — для ежедневной сверки QR.
 * Строка QR — заведомо не платёжная (`SANDBOX-QR|…`): реальным приложением банка не оплачивается.
 */
export class SandboxBankQrApi implements BankQrApi {
  readonly adapter = 'sandbox' as const;
  private readonly qrs = new Map<string, SandboxQr>();
  private readonly byPayment = new Map<string, string[]>();
  private readonly operations: (BankOperation & { readonly merchantPaymentId: string })[] = [];
  private readonly now: () => Date;
  private readonly webhookSecret: string | null;

  constructor(options: SandboxBankQrApiOptions = {}) {
    this.now = options.now ?? (() => new Date());
    this.webhookSecret = options.webhookSecret ?? null;
  }

  createQr(req: BankQrCreateRequest): Promise<BankQrCreated> {
    const amount = Money.of(req.amount);
    if (amount.compare(Money.ZERO) <= 0) {
      return Promise.reject(
        new BankApiError('INVALID_AMOUNT', false, 'Песочница банка: сумма QR должна быть > 0', 422),
      );
    }
    const now = this.now();
    const current = this.latest(req.merchantPaymentId);
    if (current) this.refresh(current, now);
    // Пока QR платежа действует и сумма та же — повтор возвращает его же (идемпотентность по платежу).
    if (current && current.status === 'pending' && current.amount === amount.toString()) {
      return Promise.resolve(this.created(current));
    }
    if (current && current.status === 'paid') {
      return Promise.reject(new BankApiError('ALREADY_PAID', false, 'Песочница банка: платёж уже оплачен', 409));
    }
    if (current && current.status === 'pending') current.status = 'cancelled';
    const qr: SandboxQr = {
      reference: `SBX-${randomBytes(6).toString('hex').toUpperCase()}`,
      merchantPaymentId: req.merchantPaymentId,
      merchantOrderId: req.merchantOrderId,
      amount: amount.toString(),
      issuedAt: now,
      expiresAt: new Date(now.getTime() + Math.max(60, req.ttlSeconds) * 1000),
      status: 'pending',
    };
    this.qrs.set(qr.reference, qr);
    this.byPayment.set(req.merchantPaymentId, [...(this.byPayment.get(req.merchantPaymentId) ?? []), qr.reference]);
    this.prune();
    return Promise.resolve(this.created(qr));
  }

  getStatus(merchantPaymentId: string): Promise<BankQrState | null> {
    const qr = this.latest(merchantPaymentId);
    if (!qr) return Promise.resolve(null);
    this.refresh(qr, this.now());
    return Promise.resolve(this.state(qr));
  }

  cancel(merchantPaymentId: string): Promise<BankQrState | null> {
    const qr = this.latest(merchantPaymentId);
    if (!qr) return Promise.resolve(null);
    this.refresh(qr, this.now());
    if (qr.status === 'pending') qr.status = 'cancelled';
    return Promise.resolve(this.state(qr));
  }

  listOperations(day: string): Promise<readonly BankOperation[]> {
    return Promise.resolve(this.operations.filter((o) => bishkekDay(new Date(o.paidAt)) === day));
  }

  /** Есть ли у песочницы QR с этим референсом (служебный маршрут — 404 вместо 409). */
  knows(reference: string): boolean {
    return this.qrs.has(reference);
  }

  /**
   * Служебная «оплата» QR (только тестовый контур: маршрут `POST /sandbox/bank/qr/{reference}/pay` при
   * `APP_ENV≠prod`). Ошибки — `BankApiError` (`UNKNOWN_REFERENCE` 404, `QR_CANCELLED`/`QR_EXPIRED`/`ALREADY_PAID` 409).
   */
  pay(input: SandboxPayInput): SandboxPayResult {
    const qr = this.qrs.get(input.reference);
    if (!qr)
      throw new BankApiError('UNKNOWN_REFERENCE', false, 'Песочница банка: QR с таким референсом не выдавался', 404);
    const now = this.now();
    this.refresh(qr, now);
    if (qr.status === 'paid') throw new BankApiError('ALREADY_PAID', false, 'Песочница банка: QR уже оплачен', 409);
    if (qr.status === 'cancelled') throw new BankApiError('QR_CANCELLED', false, 'Песочница банка: QR отменён', 409);
    if (qr.status === 'expired' && !input.allowExpired) {
      throw new BankApiError('QR_EXPIRED', false, 'Песочница банка: срок QR истёк (allowExpired=true — оплатить)', 409);
    }
    const amount = Money.of(input.amount ?? qr.amount);
    if (amount.compare(Money.ZERO) <= 0) {
      throw new BankApiError('INVALID_AMOUNT', false, 'Песочница банка: сумма оплаты должна быть > 0', 422);
    }
    qr.status = 'paid';
    const operation = {
      operationId: `SBX-OP-${randomBytes(6).toString('hex').toUpperCase()}`,
      reference: qr.reference,
      merchantPaymentId: qr.merchantPaymentId,
      merchantOrderId: qr.merchantOrderId,
      amount: amount.toString(),
      currency: 'KGS' as const,
      paidAt: now.toISOString(),
    };
    this.operations.push(operation);
    this.prune();
    return { operation, webhook: this.webhookSecret ? this.signedEvent(operation, now) : null };
  }

  /** Вебхук песочницы по операции (08 §6, тело `PaymentsQrWebhookEvent`); `eventId` — новый при каждом вызове. */
  signedEvent(op: BankOperation, at: Date = this.now()): SandboxSignedWebhook | null {
    if (!this.webhookSecret) return null;
    const eventId = `sbx-evt-${randomUUID()}`;
    const body = {
      eventId,
      eventType: 'payment.succeeded',
      reference: op.reference,
      operationId: op.operationId,
      ...(op.merchantOrderId ? { merchantOrderId: op.merchantOrderId } : {}),
      amount: op.amount,
      currency: op.currency,
      paidAt: op.paidAt,
      payer: { masked: 'SANDBOX ***' },
    };
    const rawBody = Buffer.from(JSON.stringify(body), 'utf8');
    const timestamp = String(Math.floor(at.getTime() / 1000));
    return {
      rawBody,
      eventId,
      headers: {
        'content-type': 'application/json',
        [WEBHOOK_TIMESTAMP_HEADER]: timestamp,
        [WEBHOOK_SIGNATURE_HEADER]: signWebhook(this.webhookSecret, timestamp, rawBody),
      },
    };
  }

  private latest(merchantPaymentId: string): SandboxQr | null {
    const refs = this.byPayment.get(merchantPaymentId);
    const ref = refs?.at(-1);
    return ref ? (this.qrs.get(ref) ?? null) : null;
  }

  private refresh(qr: SandboxQr, now: Date): void {
    if (qr.status === 'pending' && qr.expiresAt <= now) qr.status = 'expired';
  }

  private created(qr: SandboxQr): BankQrCreated {
    return {
      reference: qr.reference,
      payload: `SANDBOX-QR|ref=${qr.reference}|amount=${qr.amount}|currency=KGS|exp=${qr.expiresAt.toISOString()}`,
      amount: qr.amount,
      issuedAt: qr.issuedAt.toISOString(),
      expiresAt: qr.expiresAt.toISOString(),
    };
  }

  private state(qr: SandboxQr): BankQrState {
    const paid = [...this.operations].reverse().find((o) => o.merchantPaymentId === qr.merchantPaymentId) ?? null;
    return {
      status: paid ? 'paid' : qr.status,
      reference: qr.reference,
      amount: qr.amount,
      expiresAt: qr.expiresAt.toISOString(),
      paidReference: paid?.reference ?? null,
      paidAmount: paid?.amount ?? null,
      paidAt: paid?.paidAt ?? null,
      operationId: paid?.operationId ?? null,
    };
  }

  private prune(): void {
    while (this.qrs.size > SANDBOX_MAX_ITEMS) {
      const oldest = this.qrs.keys().next().value;
      if (oldest === undefined) break;
      const qr = this.qrs.get(oldest);
      this.qrs.delete(oldest);
      if (qr) {
        const rest = (this.byPayment.get(qr.merchantPaymentId) ?? []).filter((r) => r !== oldest);
        if (rest.length > 0) this.byPayment.set(qr.merchantPaymentId, rest);
        else this.byPayment.delete(qr.merchantPaymentId);
      }
    }
    if (this.operations.length > SANDBOX_MAX_ITEMS)
      this.operations.splice(0, this.operations.length - SANDBOX_MAX_ITEMS);
  }
}
