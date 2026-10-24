/**
 * Перечень мутаций, разрешённых при `APP_READ_ONLY=true` — ADR-083 п. (2) (15_DECISION_LOG; ядро §17.4, §17.7;
 * 13 RM-B-002). Статус ADR-083 на 2026-10-21 — «Предложено»: перечень вынесен в конфигурацию (токен DI
 * READ_ONLY_ALLOWLIST), чтобы при отклонении ADR вернуть правило 11 SEC-119 «все мутации → 503» заменой
 * значения на пустой массив без правки guard. Расширение перечня — только новой ADR (процедура 13 §5.3).
 * Пути — как в contracts/openapi/pos-api.v1.yaml (относительно /api/v1).
 */
export interface AllowedMutation {
  readonly method: 'POST' | 'PUT' | 'PATCH' | 'DELETE';
  readonly path: string;
  readonly group: 'auth' | 'registration' | 'me' | 'notifications' | 'containment';
}

export const READ_ONLY_ALLOWLIST = Symbol('READ_ONLY_ALLOWLIST');

/**
 * Действующий перечень по умолчанию (RM-C-005: «до принятия ADR он пуст и действует 11 SEC-119 „все мутации → 503“»;
 * ревью C-MJ-03). Пока ADR-083 в статусе «Предложено», AppModule получает пустой перечень; после принятия ADR сюда
 * подставляется ADR_083_ALLOWED_MUTATIONS (правка одной строки + запись в 15_DECISION_LOG). Тесты guard подставляют
 * перечень ADR-083 явно (AppModuleOptions.readOnlyAllowlist / TestAppOptions.readOnlyAllowlist).
 */
export const DEFAULT_READ_ONLY_ALLOWLIST: readonly AllowedMutation[] = [];

export const ADR_083_ALLOWED_MUTATIONS: readonly AllowedMutation[] = [
  { method: 'POST', path: '/auth/otp/request', group: 'auth' },
  { method: 'POST', path: '/auth/otp/verify', group: 'auth' },
  { method: 'POST', path: '/auth/refresh', group: 'auth' },
  { method: 'POST', path: '/auth/logout', group: 'auth' },
  { method: 'POST', path: '/auth/logout-all', group: 'auth' },
  { method: 'DELETE', path: '/auth/sessions/{sessionId}', group: 'auth' },
  { method: 'PATCH', path: '/auth/sessions/{sessionId}', group: 'auth' },
  { method: 'POST', path: '/auth/step-up', group: 'auth' },
  { method: 'POST', path: '/auth/unlock', group: 'auth' },
  { method: 'POST', path: '/registration/complete', group: 'registration' },
  { method: 'POST', path: '/registration/customer-match/confirm', group: 'registration' },
  { method: 'POST', path: '/registration/customer-match/reject', group: 'registration' },
  { method: 'PATCH', path: '/me/profile', group: 'me' },
  { method: 'POST', path: '/me/phone/change/request', group: 'me' },
  { method: 'POST', path: '/me/phone/change/confirm', group: 'me' },
  { method: 'PUT', path: '/me/settings', group: 'me' },
  { method: 'POST', path: '/me/pin', group: 'me' },
  { method: 'DELETE', path: '/me/pin', group: 'me' },
  { method: 'POST', path: '/me/biometrics', group: 'me' },
  { method: 'POST', path: '/me/consents', group: 'me' },
  { method: 'POST', path: '/notifications/{id}/read', group: 'notifications' },
  { method: 'POST', path: '/notifications/read-all', group: 'notifications' },
  { method: 'POST', path: '/admin/users/{id}/block', group: 'containment' },
  { method: 'POST', path: '/admin/users/{id}/logout-all', group: 'containment' },
];
