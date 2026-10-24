// СГЕНЕРИРОВАНО test/db/codegen/gen-drizzle-schema.ts из каталога PostgreSQL 17 после migrations/*.sql
// (RM-C-006) — вручную не править: новая миграция → `npx tsx test/db/codegen/gen-drizzle-schema.ts`.
// Сверка с БД — test/db/migrate-seed.db-spec.ts («Drizzle-схема совпадает с БД»).

// Домен customers/finance (07 §5.C)

import { sql } from 'drizzle-orm';
import {
  boolean,
  char,
  date,
  integer,
  jsonb,
  numeric,
  pgTable,
  smallint,
  text,
  timestamp,
  uuid,
} from 'drizzle-orm/pg-core';
import {
  contactKindEnum,
  customerLinkStatusEnum,
  customerOnecStatusEnum,
  customerSourceEnum,
  customerTypeEnum,
  discountKindEnum,
  discountSourceEnum,
  linkMatchMethodEnum,
  roleCodeEnum,
} from './enums.js';

/** customers — 07 §5.28 */
export const customers = pgTable('customers', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  onecRef: uuid('onec_ref'),
  onecCode: text('onec_code'),
  onecDataVersion: text('onec_data_version'),
  deletionMark: boolean('deletion_mark')
    .notNull()
    .default(sql`false`),
  syncedAt: timestamp('synced_at', { withTimezone: true }),
  sourceHash: text('source_hash'),
  source: customerSourceEnum('source').notNull(),
  onecCounterpartyRef: uuid('onec_counterparty_ref'),
  onecAgreementRef: uuid('onec_agreement_ref'),
  name: text('name').notNull(),
  nameNorm: text('name_norm').generatedAlwaysAs(sql`norm_search(name)`),
  customerType: customerTypeEnum('customer_type').notNull(),
  inn: text('inn'),
  primaryPhoneE164: text('primary_phone_e164'),
  phonesNorm: text('phones_norm')
    .array()
    .notNull()
    .default(sql`'{}'::text[]`),
  defaultPriceListId: uuid('default_price_list_id'),
  discountPercent: numeric('discount_percent', { precision: 5, scale: 2 }),
  creditAllowed: boolean('credit_allowed')
    .notNull()
    .default(sql`false`),
  creditLimit: numeric('credit_limit', { precision: 14, scale: 2 }),
  creditDays: smallint('credit_days'),
  isRetailDefault: boolean('is_retail_default')
    .notNull()
    .default(sql`false`),
  segment: text('segment'),
  comment: text('comment'),
  createdByUserId: uuid('created_by_user_id'),
  forceReason: text('force_reason'),
  onecStatus: customerOnecStatusEnum('onec_status')
    .notNull()
    .default(sql`'n_a'::customer_onec_status`),
  rowVersion: integer('row_version')
    .notNull()
    .default(sql`1`),
  deletedAt: timestamp('deleted_at', { withTimezone: true }),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** customer_contacts — 07 §5.29 */
export const customerContacts = pgTable('customer_contacts', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  customerId: uuid('customer_id').notNull(),
  kind: contactKindEnum('kind').notNull(),
  label: text('label'),
  value: text('value').notNull(),
  valueNorm: text('value_norm'),
  isPrimary: boolean('is_primary')
    .notNull()
    .default(sql`false`),
  onecLineKey: text('onec_line_key'),
  syncedAt: timestamp('synced_at', { withTimezone: true }),
  sourceHash: text('source_hash'),
  deletedAt: timestamp('deleted_at', { withTimezone: true }),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** customer_links — 07 §5.30 */
export const customerLinks = pgTable('customer_links', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  userId: uuid('user_id').notNull(),
  customerId: uuid('customer_id').notNull(),
  status: customerLinkStatusEnum('status')
    .notNull()
    .default(sql`'proposed'::customer_link_status`),
  matchMethod: linkMatchMethodEnum('match_method').notNull(),
  matchedPhoneE164: text('matched_phone_e164'),
  proposedAt: timestamp('proposed_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  confirmedByUserId: uuid('confirmed_by_user_id'),
  confirmedAt: timestamp('confirmed_at', { withTimezone: true }),
  rejectedAt: timestamp('rejected_at', { withTimezone: true }),
  conflictCandidates: uuid('conflict_candidates').array(),
  reason: text('reason'),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** receivables — 07 §5.31 */
export const receivables = pgTable('receivables', {
  customerId: uuid('customer_id').primaryKey(),
  balance: numeric('balance', { precision: 14, scale: 2 })
    .notNull()
    .default(sql`0`),
  overdueAmount: numeric('overdue_amount', { precision: 14, scale: 2 }),
  overdueDays: integer('overdue_days'),
  oldestDueDate: date('oldest_due_date', { mode: 'string' }),
  currency: char('currency', { length: 3 })
    .notNull()
    .default(sql`'KGS'::bpchar`),
  onecSnapshotAt: timestamp('onec_snapshot_at', { withTimezone: true }).notNull(),
  syncedAt: timestamp('synced_at', { withTimezone: true }).notNull(),
  sourceHash: text('source_hash').notNull(),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** receivable_documents — 07 §5.32 */
export const receivableDocuments = pgTable('receivable_documents', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  customerId: uuid('customer_id').notNull(),
  onecRef: uuid('onec_ref').notNull(),
  docType: text('doc_type').notNull(),
  kind: text('kind').notNull(),
  status: text('status').notNull(),
  docNumber: text('doc_number').notNull(),
  docDate: date('doc_date', { mode: 'string' }).notNull(),
  amount: numeric('amount', { precision: 14, scale: 2 }).notNull(),
  paid: numeric('paid', { precision: 14, scale: 2 })
    .notNull()
    .default(sql`0`),
  remaining: numeric('remaining', { precision: 14, scale: 2 }).notNull(),
  dueDate: date('due_date', { mode: 'string' }),
  overdueDays: integer('overdue_days'),
  orderId: uuid('order_id'),
  onecSnapshotAt: timestamp('onec_snapshot_at', { withTimezone: true }).notNull(),
  supersededAt: timestamp('superseded_at', { withTimezone: true }),
  syncedAt: timestamp('synced_at', { withTimezone: true }).notNull(),
  sourceHash: text('source_hash').notNull(),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** discount_rules — 07 §5.33 */
export const discountRules = pgTable('discount_rules', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  onecRef: uuid('onec_ref'),
  onecCode: text('onec_code'),
  onecDataVersion: text('onec_data_version'),
  deletionMark: boolean('deletion_mark')
    .notNull()
    .default(sql`false`),
  syncedAt: timestamp('synced_at', { withTimezone: true }),
  sourceHash: text('source_hash'),
  source: discountSourceEnum('source').notNull(),
  name: text('name').notNull(),
  kind: discountKindEnum('kind').notNull(),
  value: numeric('value', { precision: 14, scale: 2 }).notNull(),
  conditions: jsonb('conditions')
    .notNull()
    .default(sql`'{}'::jsonb`),
  appliesAutomatically: boolean('applies_automatically')
    .notNull()
    .default(sql`false`),
  isActive: boolean('is_active')
    .notNull()
    .default(sql`true`),
  validFrom: date('valid_from', { mode: 'string' }),
  validTo: date('valid_to', { mode: 'string' }),
  descriptionRu: text('description_ru'),
  rowVersion: integer('row_version')
    .notNull()
    .default(sql`1`),
  deletedAt: timestamp('deleted_at', { withTimezone: true }),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** role_discount_limits — 07 §5.34 */
export const roleDiscountLimits = pgTable('role_discount_limits', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  role: roleCodeEnum('role').notNull(),
  maxPercent: numeric('max_percent', { precision: 5, scale: 2 }).notNull(),
  canApproveOverLimit: boolean('can_approve_over_limit')
    .notNull()
    .default(sql`false`),
  approveMaxPercent: numeric('approve_max_percent', { precision: 5, scale: 2 }),
  requiresReasonOverPercent: numeric('requires_reason_over_percent', { precision: 5, scale: 2 }),
  updatedByUserId: uuid('updated_by_user_id'),
  rowVersion: integer('row_version')
    .notNull()
    .default(sql`1`),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});
