import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

/**
 * Статические проверки этапа F по 12 (класс «review + scan», ревью F-trace-1 раунд 2) — без БД:
 * - T-PAY-029: возврата денег в API нет — ни операции контракта, ни маршрута pos-api с `refund` в пути
 *   (возврат денег — только документами 1С, 10 PAY-034); заявки на возврат товара (`/returns`) — не деньги;
 * - T-NOTIF-004: push (FCM/APNs) в R1 нет — ни зависимостей pos-app/pos-api, ни кода;
 * - T-PRINT-007: ЭСФ (электронные счета-фактуры) приложение не формирует — ни шаблонов, ни операций, ни кода.
 */
const ROOT = fileURLToPath(new URL('../../../', import.meta.url));
const API_SRC = join(ROOT, 'pos-api', 'src');
const APP_LIB = join(ROOT, 'pos-app', 'lib');
const CONTRACT = join(ROOT, 'contracts', 'openapi', 'pos-api.v1.yaml');

function files(dir: string, ext: RegExp): string[] {
  const out: string[] = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) out.push(...files(p, ext));
    else if (ext.test(name)) out.push(p);
  }
  return out;
}

const contractPaths = (): string[] =>
  readFileSync(CONTRACT, 'utf8')
    .split(/\r?\n/)
    .filter((l) => /^ {2}\/\S*:\s*$/.test(l))
    .map((l) => l.trim().replace(/:$/, ''));

describe('этап F: статические проверки 12 (review + scan)', () => {
  it('T-PAY-029: операций возврата денег нет — ни в контракте, ни в маршрутах pos-api', () => {
    const paths = contractPaths();
    expect(paths.length).toBeGreaterThan(100);
    expect(paths.filter((p) => /refund/i.test(p))).toEqual([]);
    // Платёжные операции контракта — только приём, ручное подтверждение, void, чтение и квитанция.
    const pay = paths.filter((p) => p.startsWith('/payments') || /\/orders\/\{id\}\/payments/.test(p));
    expect(pay.sort()).toEqual(
      [
        '/orders/{id}/payments',
        '/payments',
        '/payments/qr/webhook',
        '/payments/{id}',
        '/payments/{id}/confirm-manual',
        '/payments/{id}/documents/receipt.pdf',
        '/payments/{id}/void',
      ].sort(),
    );
    const routes = files(API_SRC, /\.controller\.ts$/)
      .map((f) => readFileSync(f, 'utf8'))
      .flatMap((s) => [...s.matchAll(/@(?:Get|Post|Put|Patch|Delete)\(\s*['"`]([^'"`]*)['"`]/g)].map((m) => m[1]));
    expect(routes.length).toBeGreaterThan(50);
    expect(routes.filter((r) => /refund/i.test(r))).toEqual([]);
  });

  it('T-NOTIF-004: push отсутствует в R1 — нет firebase/FCM/APNs в зависимостях и коде', () => {
    const pubspec = readFileSync(join(ROOT, 'pos-app', 'pubspec.yaml'), 'utf8');
    const pkg = readFileSync(join(ROOT, 'pos-api', 'package.json'), 'utf8');
    const rx = /firebase|\bfcm\b|firebase_messaging|onesignal|apns|web-push|node-pushnotifications/i;
    expect(pubspec).not.toMatch(rx);
    expect(pkg).not.toMatch(rx);
    const dart = files(APP_LIB, /\.dart$/).filter((f) =>
      /firebase_messaging|FirebaseMessaging/.test(readFileSync(f, 'utf8')),
    );
    expect(dart).toEqual([]);
    const ts = files(API_SRC, /\.ts$/).filter((f) =>
      /firebase-admin|messaging\(\)\.send|apns/i.test(readFileSync(f, 'utf8')),
    );
    expect(ts).toEqual([]);
  });

  it('T-PRINT-007: ЭСФ не формируются — нет операций, шаблонов и кода', () => {
    const rx = /ЭСФ|счет-фактур|счёт-фактур|\besf\b|e-invoice|einvoice/i;
    expect(contractPaths().filter((p) => rx.test(p))).toEqual([]);
    const hits = [...files(API_SRC, /\.(ts|json|ya?ml|txt)$/), ...files(APP_LIB, /\.dart$/)].filter((f) =>
      rx.test(readFileSync(f, 'utf8')),
    );
    expect(hits).toEqual([]);
  });
});
