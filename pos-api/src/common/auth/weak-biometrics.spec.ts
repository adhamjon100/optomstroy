import { describe, expect, it } from 'vitest';
import { SUBJECT_KINDS } from './subject-kind.js';
import { biometricWeakAllowed, weakBiometricsAllowedFor, weakReauthDueAt } from './weak-biometrics.js';

/**
 * Правила уровня W Android (15 ADR-116 п. 2; 09 BIO-030, BIO-032; 08 §3.14, API-200, API-201; 16 §4.3
 * `AUTH_BIO_ALLOW_WEAK`, `AUTH_BIO_WEAK_REAUTH_HOURS`; 12 T-BIO-022, T-BIO-024, T-BIO-025 — unit-часть).
 */
describe('уровень W Android: AUTH_BIO_ALLOW_WEAK × вид субъекта × платформа (ADR-116)', () => {
  it('off — никому; customer — только покупателю; all — сотруднику и покупателю; планшет — никогда (BIO-037)', () => {
    const table = Object.fromEntries(
      (['off', 'customer', 'all'] as const).map((mode) => [
        mode,
        Object.fromEntries(SUBJECT_KINDS.map((k) => [k, weakBiometricsAllowedFor(mode, k)])),
      ]),
    );
    expect(table).toEqual({
      off: { staff: false, customer: false, kiosk: false },
      customer: { staff: false, customer: true, kiosk: false },
      all: { staff: true, customer: true, kiosk: false },
    });
  });

  it('Me.security.biometricWeakAllowed — только platform=android; Windows, iOS, без устройства — false', () => {
    expect(biometricWeakAllowed('all', 'customer', 'android')).toBe(true);
    expect(biometricWeakAllowed('all', 'staff', 'android')).toBe(true);
    for (const platform of ['windows', 'ios', null, undefined] as const) {
      expect(biometricWeakAllowed('all', 'customer', platform)).toBe(false);
    }
    expect(biometricWeakAllowed('customer', 'staff', 'android')).toBe(false);
    expect(biometricWeakAllowed('all', 'kiosk', 'android')).toBe(false);
  });

  it('weak_reauth_due_at = момент + AUTH_BIO_WEAK_REAUTH_HOURS', () => {
    const at = new Date('2026-11-08T09:00:00.000Z');
    expect(weakReauthDueAt(at, 24).toISOString()).toBe('2026-11-09T09:00:00.000Z');
    expect(weakReauthDueAt(at, 1).toISOString()).toBe('2026-11-08T10:00:00.000Z');
  });
});
