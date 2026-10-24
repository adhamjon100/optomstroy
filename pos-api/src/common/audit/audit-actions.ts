/**
 * Канонический словарь `audit_logs.action` уровня приложения (`level='app'`): 11_SECURITY_PRIVACY §7.2 и §7.2.1
 * (владелец словаря — ядро v1.3 §18.1). «Имя, отсутствующее в обоих, в коде не используется» (11 §7.2) —
 * AuditService отклоняет действие вне словаря. Имена 08 §3.16 переводятся по таблице соответствия 11 §7.2.1
 * (`AUDIT_ACTION_ALIASES_08`). Действия уровня БД (`db.*`, триггеры 07 §9.2) пишет только БД.
 */
export const AUDIT_ACTIONS = [
  // 11 §7.2
  'auth.login',
  'auth.logout',
  'auth.logout_all',
  'auth.otp.locked',
  'auth.otp.rate_limited',
  'session.reuse_detected',
  'session.revoked',
  'auth.step_up.ok',
  'auth.step_up.failed',
  'auth.pin.set',
  'auth.pin.changed',
  'auth.pin.locked',
  'auth.pin.reset',
  'user.created',
  'user.invited',
  'user.activated',
  'user.role_changed',
  'user.blocked',
  'user.unblocked',
  'user.deleted',
  'user.phone_changed',
  'consent.granted',
  'consent.revoked',
  'customer.created',
  'customer.updated',
  'customer.link.confirmed',
  'customer.link.rejected',
  'customer.link.conflict_resolved',
  'customer.debt_viewed',
  'customer.finance.view',
  'price.override_attempt',
  'order.created',
  'order.submitted',
  'order.cancel_requested',
  'order.cancelled',
  'order.status_changed',
  'discount.applied',
  'discount.over_limit_approved',
  'discount.over_limit_rejected',
  'discount.limits_changed',
  'price.changed',
  'sync.prices.applied',
  'sync.stock.applied',
  'stock.adjusted',
  'payment.received',
  'payment.manual_qr_confirmed',
  'payment.webhook_received',
  'payment.webhook_rejected',
  'payment.voided',
  'credit.sale_approved',
  'credit.sale_blocked',
  'return.requested',
  'return.submitted',
  'return.status_changed',
  'transaction.viewed_all',
  'settings.changed',
  'sync.manual_started',
  'sync.run.finished',
  'sync.run.failed',
  'outbox.retried',
  'outbox.dead',
  'audit.viewed',
  'audit.exported',
  'authz.denied',
  'report.viewed',
  'privacy.subject_request',
  'privacy.user_anonymized',
  'backup.completed',
  'backup.restore_drill',
  // 11 §7.2.1
  'auth.otp.sent',
  'auth.otp.verified',
  'auth.otp.failed',
  'auth.refresh',
  'auth.unlock',
  'auth.pin.removed',
  'auth.biometrics.enabled',
  'auth.biometrics.disabled',
  'profile.updated',
  'user.phone_change_requested',
  'user.updated',
  'invitation.created',
  'invitation.revoked',
  'customer.phone_lookup',
  'cart.cleared',
  'cart.parked',
  'cart.resumed',
  'cart.resumed_foreign',
  'payment.qr_reissued',
  'receivables.overdue_viewed',
  'return.updated',
  'outbox.confirmed',
  'outbox.rejected',
  'integration.auth_failed',
  'export.created',
  'rbac.matrix_changed',
  'discount.rule_changed',
  'integration.token_issued',
  'integration.token_rotated',
  'integration.token_revoked',
  'order.onec_linked',
  'auth.emergency_code.issued',
  'auth.emergency_code.used',
  'outbox.cancelled',
  'audit.restore_verified',
  'audit.partition_dropped',
  'retention.executed',
  'incident.containment',
] as const;

export type AuditAction = (typeof AUDIT_ACTIONS)[number];

const ACTION_SET: ReadonlySet<string> = new Set(AUDIT_ACTIONS);

export function isAuditAction(v: string): v is AuditAction {
  return ACTION_SET.has(v);
}

/**
 * Зарезервированы в R1 (11 §7.2: цены и остатки меняются только в 1С — D-22, D-23): приложение их не пишет.
 */
export const RESERVED_AUDIT_ACTIONS: ReadonlySet<AuditAction> = new Set<AuditAction>([
  'price.changed',
  'stock.adjusted',
]);

/**
 * Обязательная причина `reason` (≥ 5 символов, 11 SEC-076; колонка «Обязательная причина? — да» 11 §7.2/§7.2.1)
 * для действий **пользователя** (`actorUserId` задан). Условные случаи (отзыв сессии администратором,
 * разрешение конфликта привязки, `CUSTOMER_DUPLICATE_SUSPECTED`) проверяет сервис-владелец.
 */
export const REASON_REQUIRED_ACTIONS: ReadonlySet<AuditAction> = new Set<AuditAction>([
  'auth.pin.reset',
  'user.role_changed',
  'user.blocked',
  'user.unblocked',
  'user.deleted',
  'order.cancel_requested',
  'order.cancelled',
  'discount.over_limit_approved',
  'discount.over_limit_rejected',
  'discount.limits_changed',
  'payment.manual_qr_confirmed',
  'payment.voided',
  'credit.sale_approved',
  'return.requested',
  'return.submitted',
  'return.status_changed',
  'settings.changed',
  'privacy.subject_request',
  'privacy.user_anonymized',
  'discount.rule_changed',
  'integration.token_revoked',
  'order.onec_linked',
  'auth.emergency_code.issued',
  'incident.containment',
  'audit.partition_dropped',
]);

export const MIN_REASON_LENGTH = 5;

/** Имена 08 §3.16 → канонические имена 11 (таблица соответствия 11 §7.2.1). */
export const AUDIT_ACTION_ALIASES_08: Readonly<Record<string, AuditAction>> = {
  'user.registered': 'user.created',
  'user.pin_set': 'auth.pin.set',
  'user.pin_changed': 'auth.pin.changed',
  'user.pin_removed': 'auth.pin.removed',
  'user.biometrics_enabled': 'auth.biometrics.enabled',
  'user.biometrics_disabled': 'auth.biometrics.disabled',
  'credit.override_approved': 'credit.sale_approved',
  'payment.manual_confirmed': 'payment.manual_qr_confirmed',
  'webhook.rejected': 'payment.webhook_rejected',
  'customer.viewed': 'customer.debt_viewed',
  'customer.debt_details_viewed': 'customer.finance.view',
  'customer_link.confirmed': 'customer.link.confirmed',
  'customer_link.rejected': 'customer.link.rejected',
  'return.draft_created': 'return.requested',
  'return.draft_updated': 'return.updated',
  'user.sessions_revoked_by_admin': 'session.revoked',
  'settings.discount_limits_changed': 'discount.limits_changed',
};
