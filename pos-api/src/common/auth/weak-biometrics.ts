import type { AppConfig } from '../config/app-config.js';
import { bySubjectKind, type SubjectKind } from './subject-kind.js';

/**
 * Уровень W Android — вход «лицо или отпечаток» (Class 2) без криптопривязки (15 ADR-116 п. 2; 09 BIO-030…BIO-033;
 * 11 SEC-144, RR-9; 08 §4.1.8, §4.3.6, §3.14 «`Me.security` входа по лицу»). Решение владельца 2026-11-08 на Q-353 —
 * «Всем (Рекоменд.)»: целевое значение `AUTH_BIO_ALLOW_WEAK=all`, на рабочем контуре — после T-BIO-026 (16 DEPLOY-055).
 *
 * Правила, общие для модулей auth (разблокировка, вход по SMS) и profile (`POST /me/biometrics`, `GET /me`,
 * `DELETE /me/pin`): файл без зависимостей от модулей D-06 (06 §7.4, MOD-022).
 */
export type WeakBiometricsMode = AppConfig['AUTH_BIO_ALLOW_WEAK'];

/**
 * Разрешает ли `AUTH_BIO_ALLOW_WEAK` уровень W этому виду субъекта: `off` — никому; `customer` — только покупателям
 * (`kind=customer`); `all` — сотрудникам и покупателям. Планшет магазина биометрию не получает ни в каком виде
 * (09 BIO-037). Исчерпывающий разбор вида (06 ARCH-065), а не двоичная проверка `kind`.
 */
export function weakBiometricsAllowedFor(mode: WeakBiometricsMode, kind: SubjectKind): boolean {
  return bySubjectKind(kind, { staff: mode === 'all', customer: mode !== 'off', kiosk: false });
}

/**
 * `Me.security.biometricWeakAllowed` (08 §3.14, API-201): переменная разрешает субъекта и устройство запроса —
 * `platform=android`; на Windows, iOS, без устройства и у планшета — `false`. PIN — отдельный признак `pinSet`.
 */
export function biometricWeakAllowed(
  mode: WeakBiometricsMode,
  kind: SubjectKind,
  platform: 'android' | 'ios' | 'windows' | null | undefined,
): boolean {
  return platform === 'android' && weakBiometricsAllowedFor(mode, kind);
}

/**
 * Срок разблокировки уровнем W без PIN (`sessions.weak_reauth_due_at`, 07 §5.9): момент включения, разблокировки PIN
 * или входа по SMS на устройстве + `AUTH_BIO_WEAK_REAUTH_HOURS` (1…24; схема env больше 24 не принимает).
 */
export function weakReauthDueAt(now: Date, hours: number): Date {
  return new Date(now.getTime() + hours * 3600_000);
}
