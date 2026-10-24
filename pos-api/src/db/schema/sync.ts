// СГЕНЕРИРОВАНО test/db/codegen/gen-drizzle-schema.ts из каталога PostgreSQL 17 после migrations/*.sql
// (RM-C-006) — вручную не править: новая миграция → `npx tsx test/db/codegen/gen-drizzle-schema.ts`.
// Сверка с БД — test/db/migrate-seed.db-spec.ts («Drizzle-схема совпадает с БД»).

// Домен sync/audit/служебные (07 §5.E)

import { sql } from 'drizzle-orm';
import {
  bigint,
  boolean,
  date,
  inet,
  integer,
  jsonb,
  numeric,
  pgTable,
  primaryKey,
  smallint,
  text,
  timestamp,
  uuid,
} from 'drizzle-orm/pg-core';
import { bytea } from './types.js';
import {
  auditLevelEnum,
  idempotencyStatusEnum,
  notificationKindEnum,
  outboxAggregateEnum,
  outboxStatusEnum,
  printDocumentKindEnum,
  printJobStatusEnum,
  roleCodeEnum,
  smsStatusEnum,
  stepUpMethodEnum,
  syncEntityEnum,
  syncModeEnum,
  syncRunStatusEnum,
  syncTriggerEnum,
} from './enums.js';

/** notifications — 07 §5.50 */
export const notifications = pgTable('notifications', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  userId: uuid('user_id').notNull(),
  kind: notificationKindEnum('kind').notNull(),
  severity: text('severity').notNull(),
  titleRu: text('title_ru').notNull(),
  bodyRu: text('body_ru').notNull(),
  payload: jsonb('payload')
    .notNull()
    .default(sql`'{}'::jsonb`),
  dedupeKey: text('dedupe_key').notNull(),
  readAt: timestamp('read_at', { withTimezone: true }),
  expiresAt: timestamp('expires_at', { withTimezone: true }),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** sync_runs — 07 §5.51 */
export const syncRuns = pgTable('sync_runs', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  entity: syncEntityEnum('entity').notNull(),
  mode: syncModeEnum('mode').notNull(),
  trigger: syncTriggerEnum('trigger').notNull(),
  triggeredByUserId: uuid('triggered_by_user_id'),
  status: syncRunStatusEnum('status')
    .notNull()
    .default(sql`'queued'::sync_run_status`),
  startedAt: timestamp('started_at', { withTimezone: true }),
  finishedAt: timestamp('finished_at', { withTimezone: true }),
  cursorFrom: text('cursor_from'),
  cursorTo: text('cursor_to'),
  counts: jsonb('counts')
    .notNull()
    .default(sql`'{}'::jsonb`),
  errorSummary: text('error_summary'),
  onecEndpoint: text('onec_endpoint'),
  workerJobId: text('worker_job_id'),
  durationMs: integer('duration_ms'),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** sync_state — 07 §5.52 */
export const syncState = pgTable('sync_state', {
  entity: syncEntityEnum('entity').primaryKey(),
  scheduleCron: text('schedule_cron').notNull(),
  lastRunId: uuid('last_run_id'),
  lastSuccessRunId: uuid('last_success_run_id'),
  lastSuccessAt: timestamp('last_success_at', { withTimezone: true }),
  lastCursor: text('last_cursor'),
  lastSourceTotal: integer('last_source_total'),
  lastLocalTotal: integer('last_local_total'),
  consecutiveErrors: integer('consecutive_errors')
    .notNull()
    .default(sql`0`),
  lastErrorAt: timestamp('last_error_at', { withTimezone: true }),
  lastError: text('last_error'),
  paused: boolean('paused')
    .notNull()
    .default(sql`false`),
  pausedReason: text('paused_reason'),
  maxAgeWarningSec: integer('max_age_warning_sec').notNull(),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** sync_errors — 07 §5.53 */
export const syncErrors = pgTable('sync_errors', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  syncRunId: uuid('sync_run_id'),
  outboxId: uuid('outbox_id'),
  entity: syncEntityEnum('entity').notNull(),
  onecRef: uuid('onec_ref'),
  onecCode: text('onec_code'),
  localId: uuid('local_id'),
  errorCode: text('error_code').notNull(),
  message: text('message').notNull(),
  payload: jsonb('payload'),
  severity: text('severity').notNull(),
  resolvedAt: timestamp('resolved_at', { withTimezone: true }),
  resolvedByUserId: uuid('resolved_by_user_id'),
  resolution: text('resolution'),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** sync_entity_versions — 07 §5.54 */
export const syncEntityVersions = pgTable(
  'sync_entity_versions',
  {
    entity: syncEntityEnum('entity').notNull(),
    onecKey: text('onec_key').notNull(),
    onecRef: uuid('onec_ref'),
    dataVersion: text('data_version'),
    contentHash: bytea('content_hash').notNull(),
    localId: uuid('local_id'),
    seenInRunId: uuid('seen_in_run_id').notNull(),
    lastSeenAt: timestamp('last_seen_at', { withTimezone: true }).notNull(),
    firstSeenAt: timestamp('first_seen_at', { withTimezone: true }).notNull(),
    createdAt: timestamp('created_at', { withTimezone: true })
      .notNull()
      .default(sql`now()`),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .notNull()
      .default(sql`now()`),
  },
  (t) => [primaryKey({ name: 'sync_entity_versions_pkey', columns: [t.entity, t.onecKey] })],
);

/** onec_outbox — 07 §5.55 */
export const onecOutbox = pgTable('onec_outbox', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  aggregateType: outboxAggregateEnum('aggregate_type').notNull(),
  aggregateId: uuid('aggregate_id').notNull(),
  externalId: text('external_id').notNull(),
  operation: text('operation').notNull(),
  payload: jsonb('payload').notNull(),
  payloadHash: bytea('payload_hash').notNull(),
  status: outboxStatusEnum('status')
    .notNull()
    .default(sql`'pending'::outbox_status`),
  attempts: smallint('attempts')
    .notNull()
    .default(sql`0`),
  nextAttemptAt: timestamp('next_attempt_at', { withTimezone: true }).default(sql`now()`),
  leaseUntil: timestamp('lease_until', { withTimezone: true }),
  lockedBy: text('locked_by'),
  lastErrorCode: text('last_error_code'),
  lastError: text('last_error'),
  onecResponse: jsonb('onec_response'),
  onecRef: uuid('onec_ref'),
  sentAt: timestamp('sent_at', { withTimezone: true }),
  confirmedAt: timestamp('confirmed_at', { withTimezone: true }),
  deadAt: timestamp('dead_at', { withTimezone: true }),
  cancelledAt: timestamp('cancelled_at', { withTimezone: true }),
  dependsOnOutboxId: uuid('depends_on_outbox_id'),
  priority: smallint('priority')
    .notNull()
    .default(sql`100`),
  requestedByUserId: uuid('requested_by_user_id'),
  warehouseId: uuid('warehouse_id'),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** idempotency_keys — 07 §5.56 */
export const idempotencyKeys = pgTable(
  'idempotency_keys',
  {
    key: text('key').notNull(),
    subjectKey: text('subject_key').notNull(),
    userId: uuid('user_id'),
    route: text('route').notNull(),
    requestHash: bytea('request_hash').notNull(),
    status: idempotencyStatusEnum('status')
      .notNull()
      .default(sql`'in_progress'::idempotency_status`),
    responseStatus: smallint('response_status'),
    responseBody: jsonb('response_body'),
    resourceId: uuid('resource_id'),
    expiresAt: timestamp('expires_at', { withTimezone: true })
      .notNull()
      .default(sql`(now() + '24:00:00'::interval)`),
    createdAt: timestamp('created_at', { withTimezone: true })
      .notNull()
      .default(sql`now()`),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .notNull()
      .default(sql`now()`),
  },
  (t) => [primaryKey({ name: 'idempotency_keys_pkey', columns: [t.key, t.subjectKey, t.route] })],
);

/** audit_logs — 07 §5.57 */
export const auditLogs = pgTable('audit_logs', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  seq: bigint('seq', { mode: 'number' }).notNull().generatedAlwaysAsIdentity(),
  chainSeq: bigint('chain_seq', { mode: 'number' }).notNull(),
  occurredAt: timestamp('occurred_at', { withTimezone: true })
    .notNull()
    .default(sql`clock_timestamp()`),
  level: auditLevelEnum('level').notNull(),
  actorUserId: uuid('actor_user_id'),
  actorRole: roleCodeEnum('actor_role'),
  onBehalfOfUserId: uuid('on_behalf_of_user_id'),
  sessionId: uuid('session_id'),
  deviceId: uuid('device_id'),
  ip: inet('ip'),
  appVersion: text('app_version'),
  clientPlatform: text('client_platform'),
  requestId: text('request_id'),
  action: text('action').notNull(),
  entityType: text('entity_type'),
  entityId: uuid('entity_id'),
  onecRef: uuid('onec_ref'),
  before: jsonb('before'),
  after: jsonb('after'),
  result: text('result').notNull(),
  stepUpMethod: stepUpMethodEnum('step_up_method'),
  reason: text('reason'),
  severity: text('severity').notNull(),
  prevHash: bytea('prev_hash'),
  rowHash: bytea('row_hash').notNull(),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** audit_anchors — 07 §5.58 (ядро §17.3) */
export const auditAnchors = pgTable('audit_anchors', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  anchorDate: date('anchor_date', { mode: 'string' }).notNull(),
  lastChainSeq: bigint('last_chain_seq', { mode: 'number' }).notNull(),
  lastRowHash: bytea('last_row_hash').notNull(),
  rowsCount: bigint('rows_count', { mode: 'number' }).notNull(),
  exportedAt: timestamp('exported_at', { withTimezone: true }),
  exportLocation: text('export_location'),
  verifiedAt: timestamp('verified_at', { withTimezone: true }),
  verifyResult: text('verify_result'),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** app_settings — 07 §5.59 */
export const appSettings = pgTable('app_settings', {
  key: text('key').primaryKey(),
  value: jsonb('value').notNull(),
  valueType: text('value_type').notNull(),
  isSecret: boolean('is_secret')
    .notNull()
    .default(sql`false`),
  descriptionRu: text('description_ru').notNull(),
  requiresStepUp: boolean('requires_step_up')
    .notNull()
    .default(sql`true`),
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

/** print_jobs — 07 §5.60 (опционально) */
export const printJobs = pgTable('print_jobs', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  orderId: uuid('order_id'),
  paymentId: uuid('payment_id'),
  documentKind: printDocumentKindEnum('document_kind').notNull(),
  paper: text('paper').notNull(),
  status: printJobStatusEnum('status').notNull(),
  storageKey: text('storage_key'),
  sha256: bytea('sha256'),
  version: smallint('version')
    .notNull()
    .default(sql`1`),
  requestedByUserId: uuid('requested_by_user_id').notNull(),
  error: text('error'),
  printedAt: timestamp('printed_at', { withTimezone: true }),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** sms_outbox — 07 §5.61 */
export const smsOutbox = pgTable('sms_outbox', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  phoneE164: text('phone_e164').notNull(),
  templateKey: text('template_key').notNull(),
  provider: text('provider')
    .notNull()
    .default(sql`'smspro'::text`),
  providerMessageId: text('provider_message_id').notNull(),
  providerStatusCode: smallint('provider_status_code'),
  deliveryStatus: text('delivery_status'),
  status: smsStatusEnum('status')
    .notNull()
    .default(sql`'queued'::sms_status`),
  attempts: smallint('attempts')
    .notNull()
    .default(sql`0`),
  sentAt: timestamp('sent_at', { withTimezone: true }),
  deliveredAt: timestamp('delivered_at', { withTimezone: true }),
  error: text('error'),
  otpChallengeId: uuid('otp_challenge_id'),
  costUnits: numeric('cost_units', { precision: 10, scale: 2 }),
  outcome: text('outcome'),
  smsParts: smallint('sms_parts'),
  phonesRecognized: smallint('phones_recognized'),
  latencyMs: integer('latency_ms'),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  requestId: text('request_id'),
});

/** dev_outbox — 07 §5.63 (ядро §17.3, только dev/test) */
export const devOutbox = pgTable('dev_outbox', {
  id: uuid('id')
    .primaryKey()
    .default(sql`uuid_generate_v7()`),
  transactionId: text('transaction_id').notNull(),
  smsOutboxId: uuid('sms_outbox_id'),
  phoneE164: text('phone_e164').notNull(),
  templateKey: text('template_key').notNull(),
  text: text('text').notNull(),
  simulatedStatusCode: smallint('simulated_status_code'),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
});

/** sync_node_state — 07 §5.64 (ядро §22.8) */
export const syncNodeState = pgTable('sync_node_state', {
  node: text('node').primaryKey(),
  lastMessageNumber: bigint('last_message_number', { mode: 'number' })
    .notNull()
    .default(sql`0`),
  lastAckAt: timestamp('last_ack_at', { withTimezone: true }),
  lastErrorCode: text('last_error_code'),
  lastPingAt: timestamp('last_ping_at', { withTimezone: true }),
  extensionVersion: text('extension_version'),
  apiVersion: text('api_version'),
  registrationBacklog: integer('registration_backlog'),
  clockSkewSec: integer('clock_skew_sec'),
  onecReachable: boolean('onec_reachable')
    .notNull()
    .default(sql`true`),
  unreachableSince: timestamp('unreachable_since', { withTimezone: true }),
  createdAt: timestamp('created_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  updatedAt: timestamp('updated_at', { withTimezone: true })
    .notNull()
    .default(sql`now()`),
  authErrorAt: timestamp('auth_error_at', { withTimezone: true }),
});
