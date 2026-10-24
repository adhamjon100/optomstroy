import { Inject, Injectable } from '@nestjs/common';
import { desc, eq } from 'drizzle-orm';
import type { DbExecutor } from '../common/audit/db-executor.js';
import { DRIZZLE } from '../common/db/database.module.js';
import { customerDisplayName, maskCustomerName } from '../common/presenters/customer-name.js';
import { customerLinks, customers } from '../db/schema/index.js';

export type CustomerLinkStatus = 'none' | 'proposed' | 'confirmed' | 'rejected' | 'conflict';
export type CustomerMatchNextStep = 'confirm_or_reject' | 'wait_admin' | 'confirmed' | 'none';

/** contracts/openapi `RegistrationCustomerMatch` (08 §4.2.2). */
export interface CustomerMatchView {
  readonly status: CustomerLinkStatus;
  readonly linkId: string | null;
  readonly customer: {
    readonly displayNameMasked: string;
    readonly id?: string;
    readonly displayName?: string;
  } | null;
  readonly nextStep: CustomerMatchNextStep;
}

/** contracts/openapi `MeCustomerLink`: до `confirmed` — только linkId, status, displayNameMasked (09 REG-032). */
export interface MeCustomerLinkDto {
  readonly linkId: string | null;
  readonly status: CustomerLinkStatus;
  readonly displayNameMasked?: string;
  readonly customerId?: string;
  readonly displayName?: string;
}

/**
 * Маска и отображаемое имя карточки 1С — общие правила `common/presenters/customer-name.ts` (D PR-09): та же форма,
 * что у `RegistrationCustomerMatch` и `Customer.displayName` модуля customers (08 §3.7, §4.2.2).
 */
export { customerDisplayName, maskCustomerName };

const PRIORITY: Readonly<Record<Exclude<CustomerLinkStatus, 'none'>, number>> = {
  confirmed: 0,
  conflict: 1,
  proposed: 2,
  rejected: 3,
};

/**
 * Состояние привязки пользователя к карточке 1С **только для чтения** (`customer_links`, 07 §5.30): `Me.customerLink`
 * и запасной ответ `GET /registration/customer-match`, пока порт модуля `customers` не подключён. Финансовых данных
 * не читает (09 REG-031/032). `nextStep` для `proposed` — консервативно `wait_admin`: условия самоподтверждения
 * (11 SEC-130 — подтверждённый телефон карточки, тип карточки) проверяет модуль `customers` (RM-D-005).
 */
@Injectable()
export class CustomerLinkReader {
  constructor(@Inject(DRIZZLE) private readonly db: DbExecutor) {}

  async view(userId: string, ex: DbExecutor = this.db): Promise<CustomerMatchView> {
    const rows = await ex
      .select({
        id: customerLinks.id,
        status: customerLinks.status,
        customerId: customerLinks.customerId,
        name: customers.name,
        updatedAt: customerLinks.updatedAt,
      })
      .from(customerLinks)
      .innerJoin(customers, eq(customers.id, customerLinks.customerId))
      .where(eq(customerLinks.userId, userId))
      .orderBy(desc(customerLinks.updatedAt));
    if (rows.length === 0) return { status: 'none', linkId: null, customer: null, nextStep: 'none' };
    const best = [...rows].sort((a, b) => PRIORITY[a.status] - PRIORITY[b.status])[0];
    if (!best) return { status: 'none', linkId: null, customer: null, nextStep: 'none' };
    switch (best.status) {
      case 'confirmed':
        return {
          status: 'confirmed',
          linkId: best.id,
          customer: {
            displayNameMasked: maskCustomerName(best.name),
            id: best.customerId,
            displayName: customerDisplayName(best.name),
          },
          nextStep: 'confirmed',
        };
      case 'conflict':
        return { status: 'conflict', linkId: best.id, customer: null, nextStep: 'wait_admin' };
      case 'proposed':
        return {
          status: 'proposed',
          linkId: best.id,
          customer: { displayNameMasked: maskCustomerName(best.name) },
          nextStep: 'wait_admin',
        };
      case 'rejected':
        return { status: 'rejected', linkId: best.id, customer: null, nextStep: 'none' };
    }
  }

  async meLink(userId: string, ex?: DbExecutor): Promise<MeCustomerLinkDto> {
    return toMeCustomerLink(await this.view(userId, ex));
  }
}

export function toMeCustomerLink(v: CustomerMatchView): MeCustomerLinkDto {
  return {
    linkId: v.linkId,
    status: v.status,
    ...(v.customer ? { displayNameMasked: v.customer.displayNameMasked } : {}),
    ...(v.status === 'confirmed' && v.customer?.id ? { customerId: v.customer.id } : {}),
    ...(v.status === 'confirmed' && v.customer?.displayName ? { displayName: v.customer.displayName } : {}),
  };
}
