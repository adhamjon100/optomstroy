import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import YAML from 'yaml';
import { SYNC_ENTITY_VALUES } from '../../src/common/enums.js';
import { ROLE_GRANTS } from '../../src/common/rbac/permissions.generated.js';
import { parseManualRunBody } from '../../src/sync/api/sync-runs.service.js';
import { LIMITED_RUN_ENTITIES, manualRunRule } from '../../src/sync/api/sync-run.policy.js';
import { presentCounts } from '../../src/sync/api/sync-api.presenters.js';

/** Правило ручного запуска R0 §17.2 / 08 §4.17.2 / 11 №42, №42a — без БД. */
describe('RM-E-002: правило POST /sync/runs (R0 §17.2)', () => {
  it('incremental для stock/prices/order_status — sync.run.incremental.limited без step-up; всё прочее — sync.run.full со step-up', () => {
    for (const entity of SYNC_ENTITY_VALUES) {
      for (const mode of ['incremental', 'full', 'reconcile'] as const) {
        const r = manualRunRule(entity, mode);
        if (mode === 'incremental' && LIMITED_RUN_ENTITIES.includes(entity)) {
          expect(r).toEqual({ permission: 'sync.run.incremental.limited', stepUp: false });
        } else {
          expect(r).toEqual({ permission: 'sync.run.full', stepUp: true });
        }
      }
    }
  });

  it('права ролей (permissions.yaml): senior_seller — только limited; admin/owner — оба; seller/cashier/customer — нет', () => {
    const has = (role: string, p: string) =>
      (ROLE_GRANTS as Record<string, readonly string[]>)[role]?.includes(p) ?? false;
    expect(has('senior_seller', 'sync.run.incremental.limited')).toBe(true);
    expect(has('senior_seller', 'sync.run.full')).toBe(false);
    expect(has('admin', 'sync.run.full') && has('owner', 'sync.run.full')).toBe(true);
    for (const r of ['seller', 'cashier', 'customer']) {
      expect(has(r, 'sync.run.incremental.limited') || has(r, 'sync.run.full')).toBe(false);
    }
    expect(has('senior_seller', 'sync.outbox.manage') && has('admin', 'sync.outbox.manage')).toBe(true);
    expect(has('owner', 'sync.outbox.manage')).toBe(false);
  });

  it('тело SyncRunsCreateRequest: manual не принимается, лишние поля и scope.variantIds > 200 — VALIDATION_FAILED', () => {
    expect(parseManualRunBody({ entity: 'stock', mode: 'incremental' })).toEqual({
      entity: 'stock',
      mode: 'incremental',
      scope: null,
    });
    const bad = [
      { entity: 'stock', mode: 'manual' },
      { entity: 'goods', mode: 'full' },
      { entity: 'stock', mode: 'full', extra: 1 },
      { entity: 'receivables', mode: 'incremental', scope: { customerId: 'x' } },
      {
        entity: 'stock',
        mode: 'incremental',
        scope: { variantIds: Array.from({ length: 201 }, () => '0190a1b2-0000-7000-8000-000000000001') },
      },
    ];
    for (const b of bad) {
      expect(() => parseManualRunBody(b)).toThrow(expect.objectContaining({ code: 'VALIDATION_FAILED' }));
    }
  });

  it('SyncCounts: inserted+updated → upserted, markedDeleted → deleted; лишнее не выводится', () => {
    expect(
      presentCounts({ fetched: 10, inserted: 2, updated: 3, markedDeleted: 1, errors: 0, sourceTotal: 9, tables: {} }),
    ).toEqual({ fetched: 10, upserted: 5, deleted: 1, errors: 0, sourceTotal: 9 });
    expect(presentCounts({ stub: true })).toEqual({});
  });
});

/** Файлы дерева с нужными расширениями (без сгенерированных и служебных каталогов). */
function sourceFiles(dir: string, exts: readonly string[]): string[] {
  const out: string[] = [];
  for (const name of readdirSync(dir)) {
    if (['node_modules', '.dart_tool', 'build', 'generated'].includes(name)) continue;
    const full = join(dir, name);
    if (statSync(full).isDirectory()) out.push(...sourceFiles(full, exts));
    else if (exts.some((e) => name.endsWith(e))) out.push(full);
  }
  return out;
}

const REPO = fileURLToPath(new URL('../../../', import.meta.url));

describe('Граница «1С ↔ приложение» и состав операций синхронизации (статически, без БД)', () => {
  // 12 T-SYNC-027 (contract): операции паузы сущности в R1 нет (R2, Q-219) — ни в контракте, ни в маршрутах pos-api.
  it('T-SYNC-027: в контракте и в контроллерах sync нет операции паузы сущности', () => {
    const doc = YAML.parse(readFileSync(join(REPO, 'contracts/openapi/pos-api.v1.yaml'), 'utf8')) as {
      paths: Record<string, Record<string, { operationId?: string }>>;
    };
    const ops: string[] = [];
    for (const [path, item] of Object.entries(doc.paths)) {
      for (const [method, op] of Object.entries(item)) {
        if (typeof op === 'object' && op && 'operationId' in op) ops.push(`${method} ${path} ${op.operationId ?? ''}`);
      }
    }
    expect(ops.length).toBeGreaterThan(50);
    // «resume» есть у отложенных корзин (/cart/parked/{id}/resume) — к синхронизации не относится.
    expect(ops.filter((o) => /pause/i.test(o) || (/ \/sync\//.test(o) && /resume/i.test(o)))).toEqual([]);
    const routes = sourceFiles(join(REPO, 'pos-api/src'), ['.controller.ts'])
      .flatMap((f) => readFileSync(f, 'utf8').split(/\r?\n/))
      .filter((l) => /@(Get|Post|Put|Patch|Delete)\(/.test(l));
    expect(routes.length).toBeGreaterThan(20);
    // Этап F: `POST /cart/parked/:id/resume` (возобновление отложенной корзины) к синхронизации не относится.
    expect(routes.filter((l) => /pause|resume/i.test(l) && !/parked\/:id\/resume/.test(l))).toEqual([]);
  });

  // 12 T-SYNC-022 (review + static) и статическая часть T-ONEC-002: клиент обновляет только кэш с backend и не
  // обращается к 1С — в коде и ресурсах pos-app нет путей HTTP-сервиса 1С, OData и настроек подключения к 1С.
  // Анализ трафика сборок (вторая часть T-ONEC-002) — вручную, не здесь.
  it('T-SYNC-022, T-ONEC-002 (статическая часть): pos-app не содержит адресов и настроек 1С', () => {
    const files = [
      ...sourceFiles(join(REPO, 'pos-app/lib'), ['.dart']),
      ...sourceFiles(join(REPO, 'pos-app/assets'), ['.json', '.yaml', '.yml', '.txt']),
      join(REPO, 'pos-app/pubspec.yaml'),
    ].filter((f) => !/\.(g|freezed)\.dart$/.test(f));
    expect(files.length).toBeGreaterThan(100);
    const forbidden =
      /\/pos\/v1\/|standard\.odata|\$format=json|ONEC_(HS|ODATA|BASE|MODE)|pos_integration|X-POS-Client-Key/i;
    const hits = files.flatMap((f) =>
      readFileSync(f, 'utf8')
        .split(/\r?\n/)
        .map((l, i) => ({ f, i: i + 1, l }))
        .filter((x) => forbidden.test(x.l))
        .map((x) => `${x.f.slice(REPO.length)}:${x.i}: ${x.l.trim()}`),
    );
    expect(hits).toEqual([]);
  });
});
