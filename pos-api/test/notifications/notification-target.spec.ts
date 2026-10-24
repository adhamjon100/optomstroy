import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { parse as parseYaml } from 'yaml';
import {
  NOTIFICATION_TARGET_VALUES,
  assertNotificationPayload,
} from '../../src/common/notifications/notification-target.js';
import { NotificationsPortService } from '../../src/notifications/center/notifications-port.service.js';
import type { NotificationsRepository } from '../../src/notifications/center/notifications.repository.js';

/**
 * `Notification.payload.target` по контракту (OpenAPI 1.2.0, 08 §3.13; ревью F, RC-3): сервер передаёт только значения
 * закрытого enum `target`. Проверки без БД: (1) список сервера совпадает с enum собранного контракта; (2) порт
 * уведомлений и запись алертов синхронизации отклоняют значение вне enum; (3) в исходниках pos-api нет литерала
 * `target: '…'` в `payload` уведомления вне enum (прежние `sync`, `sync_outbox`, `sync_errors`).
 */
const ROOT = fileURLToPath(new URL('../../../', import.meta.url));
const CONTRACT = join(ROOT, 'contracts', 'openapi', 'pos-api.v1.yaml');
const API_SRC = join(ROOT, 'pos-api', 'src');

type Schema = Record<string, unknown>;

function contractTargetEnum(): unknown[] {
  const doc = parseYaml(readFileSync(CONTRACT, 'utf8')) as { components: { schemas: Record<string, Schema> } };
  const payload = (doc.components.schemas.Notification?.properties as Record<string, Schema>).payload;
  const target = (payload.properties as Record<string, Schema>).target;
  return target.enum as unknown[];
}

function files(dir: string): string[] {
  const out: string[] = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) out.push(...files(p));
    else if (name.endsWith('.ts') && !name.endsWith('.spec.ts')) out.push(p);
  }
  return out;
}

describe('Notification.payload.target — только enum контракта (RC-3)', () => {
  it('список сервера совпадает с enum Notification.payload.target контракта (кроме null)', () => {
    const e = contractTargetEnum();
    expect(e).toContain(null);
    expect(e.filter((x) => x !== null).sort()).toEqual([...NOTIFICATION_TARGET_VALUES].sort());
  });

  it('assertNotificationPayload: enum и null — да; sync / sync_outbox / sync_errors — ошибка', () => {
    for (const t of [...NOTIFICATION_TARGET_VALUES, null]) {
      expect(() => assertNotificationPayload({ target: t })).not.toThrow();
    }
    expect(() => assertNotificationPayload(undefined)).not.toThrow();
    expect(() => assertNotificationPayload({ orderId: 'x' })).not.toThrow();
    for (const t of ['sync', 'sync_outbox', 'sync_errors', '', 42]) {
      expect(() => assertNotificationPayload({ target: t })).toThrow(/вне enum контракта/);
    }
  });

  it('NotificationsPort (notify/notifyRole) не записывает payload с target вне enum', async () => {
    const calls: unknown[] = [];
    const repo = {
      insert: (_tx: unknown, n: unknown) => {
        calls.push(n);
        return Promise.resolve({ id: 'n1', created: true });
      },
      insertForRole: (_tx: unknown, _role: string, n: unknown) => {
        calls.push(n);
        return Promise.resolve(['n1']);
      },
    } as unknown as NotificationsRepository;
    const port = new NotificationsPortService(repo);
    const base = { kind: 'sync_error' as const, severity: 'error' as const, title: 't', body: 'b', dedupeKey: 'k' };
    await expect(port.notifyRole(null, 'admin', { ...base, payload: { target: 'sync_outbox' } })).rejects.toThrow(
      /вне enum контракта/,
    );
    await expect(
      port.notify(null, {
        ...base,
        userId: '00000000-0000-4000-8000-000000000001',
        payload: { target: 'sync_errors' },
      }),
    ).rejects.toThrow(/вне enum контракта/);
    expect(calls).toHaveLength(0);
    await port.notifyRole(null, 'admin', { ...base, kind: 'system', payload: { target: 'cart_parked' } });
    expect(calls).toHaveLength(1);
  });

  it('исходники pos-api: литералы target в payload уведомлений — только значения enum', () => {
    const found: string[] = [];
    for (const f of files(API_SRC)) {
      const src = readFileSync(f, 'utf8');
      for (const m of src.matchAll(/payload:\s*\{[^}]*?\btarget:\s*(?:'([^']*)'|"([^"]*)"|(null))/g)) {
        found.push(`${f.slice(API_SRC.length + 1)}:${m[1] ?? m[2] ?? m[3]}`);
      }
    }
    // Источники target (cart_parked — cart-jobs; customer_link — link-conflict; null — отзыв согласия).
    expect(found.length).toBeGreaterThanOrEqual(3);
    const bad = found.filter((x) => {
      const v = x.slice(x.lastIndexOf(':') + 1);
      return v !== 'null' && !(NOTIFICATION_TARGET_VALUES as readonly string[]).includes(v);
    });
    expect(bad).toEqual([]);
  });
});
