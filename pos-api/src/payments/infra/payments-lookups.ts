import { Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import type { DbExecutor } from '../../common/audit/db-executor.js';
import type { OrderStatus, PaymentMethod } from '../../common/enums.js';
import { rows } from './sql-executor.js';

/** Заказ для проверок доступа и чтения (без блокировки; блокировка под платёж — `OrderStatusPort.lockForPayment`). */
export interface OrderReadView {
  readonly orderId: string;
  readonly publicNumber: string;
  readonly status: OrderStatus;
  readonly paymentMethod: PaymentMethod;
  readonly customerId: string;
  readonly createdByUserId: string;
  readonly onecRef: string | null;
  readonly customerOnecRef: string | null;
  readonly total: string;
  readonly paidAmount: string;
  readonly isPaid: boolean;
}

export interface CreditCustomerFacts {
  readonly exists: boolean;
  readonly isRetailDefault: boolean;
  readonly hasOnecRef: boolean;
  readonly creditAllowed: boolean;
}

export interface UserRefView {
  readonly id: string;
  readonly displayName: string;
  readonly role?: string;
}

/**
 * Чтения чужих таблиц, нужные модулю `payments` без изменения (06 §7.4: запись — только владельцы): заказ (доступ
 * `own`, номер для назначения платежа и журнала), карточка клиента (шаг 1 PAY-031 при начальном платеже `credit`),
 * пользователь (`Payment.confirmedBy`, без телефона — 08 §3.5).
 */
@Injectable()
export class PaymentsLookups {
  async order(tx: DbExecutor, orderId: string): Promise<OrderReadView | null> {
    const r = await rows<{
      id: string;
      public_number: string;
      status: OrderStatus;
      payment_method: PaymentMethod;
      customer_id: string;
      created_by_user_id: string;
      onec_ref: string | null;
      customer_onec_ref: string | null;
      total: string;
      paid_amount: string;
      is_paid: boolean;
    }>(
      tx,
      sql`SELECT o.id, o.public_number, o.status::text AS status, o.payment_method::text AS payment_method,
                 o.customer_id, o.created_by_user_id, o.onec_ref, c.onec_ref AS customer_onec_ref,
                 o.total::text AS total, o.paid_amount::text AS paid_amount, o.is_paid
            FROM orders o LEFT JOIN customers c ON c.id = o.customer_id
           WHERE o.id = ${orderId}::uuid`,
    );
    const o = r[0];
    if (!o) return null;
    return {
      orderId: o.id,
      publicNumber: o.public_number,
      status: o.status,
      paymentMethod: o.payment_method,
      customerId: o.customer_id,
      createdByUserId: o.created_by_user_id,
      onecRef: o.onec_ref,
      customerOnecRef: o.customer_onec_ref,
      total: o.total,
      paidAmount: o.paid_amount,
      isPaid: o.is_paid,
    };
  }

  /**
   * Карточка клиента, к которой пользователь-покупатель привязан со статусом `confirmed` (`customer_links`), иначе
   * `null`: при подтверждённой привязке «свои» заказы покупателя — также заказы его карточки 1С (10 CUST-025,
   * матрица §3 строка 29; 11 SEC-030). Режим клиента, RM-G-014.
   */
  async confirmedCustomerId(tx: DbExecutor, userId: string): Promise<string | null> {
    const r = await rows<{ customer_id: string }>(
      tx,
      sql`SELECT customer_id FROM customer_links WHERE user_id = ${userId}::uuid AND status = 'confirmed' LIMIT 1`,
    );
    return r[0]?.customer_id ?? null;
  }

  async creditCustomer(tx: DbExecutor, customerId: string | null): Promise<CreditCustomerFacts> {
    if (!customerId) return { exists: false, isRetailDefault: false, hasOnecRef: false, creditAllowed: false };
    const r = await rows<{ is_retail_default: boolean; has_ref: boolean; credit_allowed: boolean }>(
      tx,
      sql`SELECT is_retail_default, onec_ref IS NOT NULL AS has_ref, credit_allowed FROM customers
           WHERE id = ${customerId}::uuid`,
    );
    const c = r[0];
    if (!c) return { exists: false, isRetailDefault: false, hasOnecRef: false, creditAllowed: false };
    return {
      exists: true,
      isRetailDefault: c.is_retail_default,
      hasOnecRef: c.has_ref,
      creditAllowed: c.credit_allowed,
    };
  }

  async userRefs(tx: DbExecutor, ids: readonly string[]): Promise<Map<string, UserRefView>> {
    const uniq = [...new Set(ids)];
    const out = new Map<string, UserRefView>();
    if (uniq.length === 0) return out;
    const r = await rows<{ id: string; display_name: string | null; role: string | null }>(
      tx,
      sql`SELECT u.id, coalesce(nullif(up.display_name, ''), up.full_name) AS display_name,
                 (SELECT ro.code::text FROM user_roles ur JOIN roles ro ON ro.id = ur.role_id
                   WHERE ur.user_id = u.id AND ur.revoked_at IS NULL ORDER BY ur.granted_at LIMIT 1) AS role
            FROM users u LEFT JOIN user_profiles up ON up.user_id = u.id
           WHERE u.id = ANY(${`{${uniq.join(',')}}`}::uuid[])`,
    );
    for (const u of r) {
      out.set(u.id, {
        id: u.id,
        displayName: u.display_name ?? 'Сотрудник',
        ...(u.role ? { role: u.role } : {}),
      });
    }
    return out;
  }

  /**
   * Последняя строка журнала `transactions` каждого платежа (`payment_id`; при нескольких переходах — самая поздняя):
   * поле `Payment.transactionId` (переход UI-24-008 к SCR-37; FQ-FEORD-12, этап G RM-G-004).
   */
  async transactionIds(tx: DbExecutor, paymentIds: readonly string[]): Promise<Map<string, string>> {
    const uniq = [...new Set(paymentIds)];
    const out = new Map<string, string>();
    if (uniq.length === 0) return out;
    const r = await rows<{ payment_id: string; id: string }>(
      tx,
      sql`SELECT DISTINCT ON (t.payment_id) t.payment_id, t.id FROM transactions t
           WHERE t.payment_id = ANY(${`{${uniq.join(',')}}`}::uuid[])
           ORDER BY t.payment_id, t.occurred_at DESC, t.id DESC`,
    );
    for (const x of r) out.set(x.payment_id, x.id);
    return out;
  }
}
