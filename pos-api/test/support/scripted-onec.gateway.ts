import { FakeOnecGateway, type FakeOnecGatewayOptions } from '../../src/integrations/onec/fake-onec.gateway.js';
import { OnecError } from '../../src/integrations/onec/onec-error.js';
import type {
  OnecCallOptions,
  OnecJson,
  OnecJsonObject,
  OnecOperationId,
  OnecQrCancelReason,
  OnecQrCancelResponse,
  OnecQrCreateRequest,
  OnecQrCreateResponse,
  OnecQrPaymentStatus,
  OnecResult,
} from '../../src/integrations/onec/onec-gateway.js';

/**
 * Управляемый фейк 1С для тестов этапа F (**тестовые данные**, не реальная интеграция): поверх `FakeOnecGateway`
 * (фикстуры `contracts/onec/fixtures`) — сценарий ответов по операциям в порядке вызовов.
 *
 * ```ts
 * gw.script('createOrder', { error: 503 }, { delayMs: 7000 }, { fixture: 'orders-create.201' });
 * gw.script('createOrder', { error: 422, code: 'POS_E_VALIDATION' });      // бизнес-отказ → outbox failed
 * gw.script('createOrder', { fixture: 'orders-create.409.stock' });       // 409 из фикстуры
 * gw.always('checkCart', { transport: true });                            // 1С недоступна на каждый вызов
 * gw.qrPaidAfterPolls(2);                                                 // 2-й опрос статуса QR → paid
 * gw.qrPaidAfterPolls(1, { paidAmount: '100.00' });                       // оплачено другой суммой
 * ```
 * Шаги: `fixture` — ответ фикстуры (≥ 400 → `OnecError` с кодом из тела); `error` — `OnecError(status, code)`;
 * `transport` — сбой сети (`status 0`); `delayMs` — задержка (прерывается `opts.signal` → `OnecError` 0 `TIMEOUT`),
 * затем `then` или ответ по умолчанию; `hang` — ждать до прерывания `signal`; `respond` — произвольное тело.
 * Без шагов — поведение `FakeOnecGateway` (успешный сценарий). Журнал вызовов — `calls` (наследуется).
 */
export type OnecStep =
  | { readonly fixture: string }
  | { readonly error: number; readonly code?: string; readonly message?: string; readonly details?: unknown }
  | { readonly transport: true }
  | { readonly delayMs: number; readonly then?: OnecStep }
  | { readonly hang: true }
  | { readonly respond: { readonly status?: number; readonly body: OnecJson } };

const DEFAULT_ERROR_CODE: Readonly<Record<number, string>> = {
  400: 'POS_E_BAD_REQUEST',
  401: 'POS_E_UNAUTHORIZED',
  403: 'POS_E_FORBIDDEN',
  404: 'POS_E_NOT_FOUND',
  409: 'POS_E_STATE',
  422: 'POS_E_VALIDATION',
  423: 'POS_E_LOCKED',
  500: 'POS_E_INTERNAL',
  503: 'POS_E_MAINTENANCE',
};

interface QrIssued {
  readonly amount: string;
  readonly reference: string;
  readonly expiresAt: string;
}

export class ScriptedOnecGateway extends FakeOnecGateway {
  private readonly queues = new Map<OnecOperationId, OnecStep[]>();
  private readonly persistent = new Map<OnecOperationId, OnecStep>();
  private readonly qrIssued = new Map<string, QrIssued>();
  private readonly qrPolls = new Map<string, number>();
  private qrPlan: { readonly afterPolls: number; readonly paidAmount?: string; readonly reference?: string } | null =
    null;
  private qrSeq = 0;

  constructor(options: FakeOnecGatewayOptions = {}) {
    super(options);
  }

  /** Добавить шаги в очередь операции (используются по одному на вызов, затем — `always` или поведение по умолчанию). */
  script(operation: OnecOperationId, ...steps: OnecStep[]): this {
    const q = this.queues.get(operation) ?? [];
    q.push(...steps);
    this.queues.set(operation, q);
    return this;
  }

  /** Постоянный ответ операции (после исчерпания очереди). `null` — снять. */
  always(operation: OnecOperationId, step: OnecStep | null): this {
    if (step === null) this.persistent.delete(operation);
    else this.persistent.set(operation, step);
    return this;
  }

  /**
   * Оплата QR через N опросов: `getQrPaymentStatus` для каждого платежа отвечает `pending` на первых `n − 1` опросах и
   * `paid` начиная с n-го (сумма — выданная в `createQrPayment` или `paidAmount`; референс — выданный или `reference`).
   */
  qrPaidAfterPolls(n: number, opts: { readonly paidAmount?: string; readonly reference?: string } = {}): this {
    this.qrPlan = { afterPolls: Math.max(1, n), ...opts };
    return this;
  }

  /** Число опросов статуса QR по платежу. */
  qrPollCount(paymentExternalId: string): number {
    return this.qrPolls.get(paymentExternalId) ?? 0;
  }

  /** Вызовы операции (для проверок «обращений к 1С не было»). */
  callsOf(operation: OnecOperationId): readonly (readonly unknown[])[] {
    return this.calls.filter((c) => c.operation === operation).map((c) => c.args);
  }

  /** Сбросить сценарии, журнал и состояние QR. */
  override reset(): void {
    super.reset();
    this.queues.clear();
    this.persistent.clear();
    this.qrIssued.clear();
    this.qrPolls.clear();
    this.qrPlan = null;
  }

  override createOrder(request: OnecJsonObject, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return this.run('createOrder', opts, { externalId: request.externalId }, () => super.createOrder(request, opts));
  }

  override getOrderStatus(externalId: string, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return this.run('getOrderStatus', opts, { externalId }, () => super.getOrderStatus(externalId, opts));
  }

  override getOrderStatusBatch(
    externalIds: readonly string[],
    opts?: OnecCallOptions,
  ): Promise<OnecResult<OnecJsonObject>> {
    return this.run('getOrderStatusBatch', opts, {}, () => super.getOrderStatusBatch(externalIds, opts));
  }

  override cancelOrder(
    externalId: string,
    request: OnecJsonObject,
    opts?: OnecCallOptions,
  ): Promise<OnecResult<OnecJsonObject>> {
    return this.run('cancelOrder', opts, { externalId }, () => super.cancelOrder(externalId, request, opts));
  }

  override createPayment(request: OnecJsonObject, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return this.run('createPayment', opts, { externalId: request.externalId }, () =>
      super.createPayment(request, opts),
    );
  }

  override checkCart(request: OnecJsonObject, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return this.run('checkCart', opts, {}, () => super.checkCart(request, opts));
  }

  override getCustomerReceivables(ref: string, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return this.run('getCustomerReceivables', opts, { customerRef: ref }, () =>
      super.getCustomerReceivables(ref, opts),
    );
  }

  // Этап G (кассир): сценарии для клиентов и возвратов поверх синтетики `cashier` (или фикстур).
  override findCustomersByPhone(phone: string, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject[]>> {
    return this.run<OnecJsonObject[]>('findCustomersByPhone', opts, {}, () => super.findCustomersByPhone(phone, opts));
  }

  override createCustomer(request: OnecJsonObject, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return this.run('createCustomer', opts, { externalId: request.externalId }, () =>
      super.createCustomer(request, opts),
    );
  }

  override createReturnRequest(request: OnecJsonObject, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return this.run('createReturnRequest', opts, {}, () => super.createReturnRequest(request, opts));
  }

  override getReturnRequestStatus(externalId: string, opts?: OnecCallOptions): Promise<OnecResult<OnecJsonObject>> {
    return this.run('getReturnRequestStatus', opts, {}, () => super.getReturnRequestStatus(externalId, opts));
  }

  override async createQrPayment(
    request: OnecQrCreateRequest,
    opts?: OnecCallOptions,
  ): Promise<OnecResult<OnecQrCreateResponse>> {
    const r = await this.run<OnecQrCreateResponse>('createQrPayment', opts, { externalId: request.externalId }, () =>
      super.createQrPayment(request, opts),
    );
    // Выданный QR — по запросу (сумма) и с уникальным референсом на каждый выпуск (перевыпуск PAY-025).
    this.qrSeq += 1;
    const reference = `QR-TEST-${String(this.qrSeq).padStart(6, '0')}`;
    const body: OnecQrCreateResponse = { ...r.body, externalId: request.externalId, amount: request.amount, reference };
    this.qrIssued.set(request.externalId, { amount: request.amount, reference, expiresAt: body.expiresAt });
    this.qrPolls.set(request.externalId, 0);
    return { ...r, body };
  }

  override async getQrPaymentStatus(
    externalId: string,
    opts?: OnecCallOptions,
  ): Promise<OnecResult<OnecQrPaymentStatus>> {
    const polls = (this.qrPolls.get(externalId) ?? 0) + 1;
    this.qrPolls.set(externalId, polls);
    const issued = this.qrIssued.get(externalId);
    const plan = this.qrPlan;
    if (plan && !this.queues.get('getQrPaymentStatus')?.length && !this.persistent.has('getQrPaymentStatus')) {
      this.calls.push({ operation: 'getQrPaymentStatus', args: [externalId, opts] });
      const paid = polls >= plan.afterPolls;
      const f = this.fixture(paid ? 'payments-status.paid.200' : 'payments-status.pending.200');
      const base = f.body as unknown as OnecQrPaymentStatus;
      const amount = issued?.amount ?? base.amount;
      return {
        status: 200,
        body: {
          ...base,
          externalId,
          amount,
          reference: plan.reference ?? issued?.reference ?? base.reference,
          expiresAt: issued?.expiresAt ?? base.expiresAt,
          paidAmount: paid ? (plan.paidAmount ?? amount) : null,
          paidAt: paid ? base.paidAt : null,
        },
      };
    }
    const r = await this.run<OnecQrPaymentStatus>('getQrPaymentStatus', opts, { externalId }, () =>
      super.getQrPaymentStatus(externalId, opts),
    );
    return issued ? { ...r, body: { ...r.body, amount: issued.amount, reference: issued.reference } } : r;
  }

  override cancelQrPayment(
    externalId: string,
    reason: OnecQrCancelReason,
    opts?: OnecCallOptions,
  ): Promise<OnecResult<OnecQrCancelResponse>> {
    return this.run('cancelQrPayment', opts, { externalId }, () => super.cancelQrPayment(externalId, reason, opts));
  }

  private nextStep(operation: OnecOperationId): OnecStep | undefined {
    const q = this.queues.get(operation);
    if (q && q.length > 0) return q.shift();
    return this.persistent.get(operation);
  }

  private run<T = OnecJsonObject>(
    operation: OnecOperationId,
    opts: OnecCallOptions | undefined,
    bind: Record<string, OnecJson | undefined>,
    fallback: () => Promise<OnecResult<T>>,
  ): Promise<OnecResult<T>> {
    const step = this.nextStep(operation);
    if (!step) return fallback();
    // Сценарный вызов фиксируется в журнале (ответ по умолчанию пишет журнал сам).
    this.calls.push({ operation, args: [bind, opts] });
    return this.exec<T>(operation, step, opts, bind, fallback);
  }

  private async exec<T>(
    operation: OnecOperationId,
    step: OnecStep,
    opts: OnecCallOptions | undefined,
    bind: Record<string, OnecJson | undefined>,
    fallback: () => Promise<OnecResult<T>>,
  ): Promise<OnecResult<T>> {
    if ('delayMs' in step) {
      await sleep(step.delayMs, opts?.signal, operation);
      if (step.then) return this.exec<T>(operation, step.then, opts, bind, fallback);
      // Ответ по умолчанию после задержки (без повторной записи в журнал — запись уже сделана).
      const before = this.calls.length;
      const r = await fallback();
      this.calls.splice(before, this.calls.length - before);
      return r;
    }
    if ('hang' in step) {
      await sleep(10 * 60_000, opts?.signal, operation);
      throw new OnecError(operation, 0, 'TIMEOUT', 'ответ 1С не получен (hang)');
    }
    if ('transport' in step) throw new OnecError(operation, 0, 'TRANSPORT', 'сбой сети (сценарий теста)');
    if ('error' in step) {
      throw new OnecError(
        operation,
        step.error,
        step.code ?? DEFAULT_ERROR_CODE[step.error] ?? 'POS_E_INTERNAL',
        step.message ?? `ошибка 1С ${step.error} (сценарий теста)`,
        step.details,
      );
    }
    if ('respond' in step) return { status: step.respond.status ?? 200, body: step.respond.body as T };
    const f = this.fixture(step.fixture);
    const status = f.status ?? 200;
    const body = isObject(f.body) ? f.body : {};
    if (status >= 400) {
      throw new OnecError(
        operation,
        status,
        typeof body.code === 'string' ? body.code : 'POS_E_INTERNAL',
        typeof body.message === 'string' ? body.message : 'ошибка 1С (фикстура)',
        body.details,
      );
    }
    let out: OnecJson = f.body;
    if (isObject(out)) {
      const bound: Record<string, OnecJson> = { ...out };
      for (const [k, v] of Object.entries(bind)) if (v !== undefined && k in bound) bound[k] = v;
      out = bound;
    }
    return { status, body: out as T };
  }
}

function isObject(v: unknown): v is { [key: string]: OnecJson } {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

function sleep(ms: number, signal: AbortSignal | undefined, operation: OnecOperationId): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(new OnecError(operation, 0, 'TIMEOUT', 'запрос к 1С прерван по таймауту'));
    const t = setTimeout(() => {
      signal?.removeEventListener('abort', onAbort);
      resolve();
    }, ms);
    const onAbort = () => {
      clearTimeout(t);
      reject(new OnecError(operation, 0, 'TIMEOUT', 'запрос к 1С прерван по таймауту'));
    };
    signal?.addEventListener('abort', onAbort, { once: true });
  });
}
