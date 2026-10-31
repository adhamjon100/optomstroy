// Инициализация браузерного бэкенда (WP-B3; plan §3.3 «Состав воркера», §3.5; critic [0]–[4], [15], [20]):
// хранилище и эпоха, PGlite, миграции и данные, demo_meta (секреты, ключ JWT, состояние имитатора 1С), сотрудники и
// приглашение, восстановление после «падения процесса», догоняние расписаний, pos-api (createApp) и pos-worker
// (WorkerRuntime) в одном воркере на одном PGlite.
//
// Порядок (холодный старт эпохи / тёплый старт):
//  1. Хранилище: OPFS (opfs-ahp) → IndexedDB → память, по init.storage и storageFallback; занятые другой вкладкой
//     файлы OPFS — повтор ~10 с, затем fatal storage_busy. Сброс на диск — DemoStorage (сторож поколения тома).
//  2. Настоящий мигратор pos-api (и на тёплом старте: новые миграции применяются к данным; изменённая применённая
//     миграция → fatal epoch_incompatible, страница предлагает «Сбросить демо»).
//  3. Холодный старт: seeds, demo_meta, секреты эпохи, ключ JWT, сотрудники 901/906/907/909, служебные учётки сида,
//     каталог настоящим конвейером (CatalogFullLoadService + SyntheticCatalogSource). Шаги идемпотентны: старт,
//     оборванный посреди холодной инициализации, просто доделывает её.
//  4. Каждый старт: приглашение 902 создаётся или продлевается (ничего со сроком не «запекается», critic [2]);
//     восстановление после падения процесса ДО WorkerRuntime (critic [1]): активные задачи pg-boss → retry,
//     прогоны sync_runs running/queued → failed, аренда строк outbox снята.
//  5. Имитатор 1С: PosFakeOnec + журнал синтетики, состояние из demo_meta, сверка с данными PGlite (critic [0]).
//  6. createApp(config) без listen; WorkerRuntime (источник срезов stock/prices — тот же синтетический каталог,
//     иначе в режиме расширения они «без источника» и /sync/status навсегда degraded).
//  7. Догоняние (единицей работы): задачи всех сущностей расписания режима extension (stock, prices, receivables,
//     order_status, images), onec.changes, customers и outbox.dispatch — сразу, а не по cron (critic [2]);
//     receivables — после завершения задачи customers (fix round 1: иначе долги до следующего запуска по расписанию).
import { assertSameOrigin } from './shims/net-guard.mjs';
import 'reflect-metadata';
import { Buffer } from 'node:buffer';
import fsShim from './shims/node-fs.cjs';
import { registerFile as pdfkitRegisterFile, registerStdFonts } from 'pdfkit';
import Helvetica from 'pdfkit/standard-fonts/Helvetica';
import { NodePgSession } from 'drizzle-orm/node-postgres/session';
import * as pgShim from './alias/pg-shim.mjs';
import * as bossShim from './alias/pgboss-shim.mjs';
import * as gate from './alias/work-gate.mjs';
import { prepareJwtKeyRing } from './alias/jwt-keys.mjs';
import { configureOnecGateway } from './alias/onec-gateway.mjs';
import { setFakeOnec } from './alias/onec-transport.mjs';
import { pino } from './alias/pino.mjs';

import { migrate, seed, DEV_MIGRATIONS_SCHEMA } from '@pos-api-dist/db/migrator.js';
import { FakeOnecGateway, catalogProducts } from '@pos-api-dist/integrations/onec/fake-onec.gateway.js';
import { FakeExchangePlan } from '@pos-api-dist/integrations/onec/fake-exchange-plan.js';
import { SyntheticCashier } from '@pos-api-dist/integrations/onec/synthetic-cashier.js';
import { SyntheticCatalog } from '@pos-api-dist/integrations/onec/synthetic-catalog.js';
import { CatalogApplier } from '@pos-api-dist/sync/apply/catalog-applier.js';
import { CatalogFullLoadService } from '@pos-api-dist/sync/apply/catalog-full-load.service.js';
import { SyntheticCatalogSource } from '@pos-api-dist/sync/apply/catalog-source.js';
import { createRunTracker } from '@pos-api-dist/sync/apply/run-tracker.js';
import { loadAppConfig } from '@pos-api-dist/common/config/app-config.js';
import { createApp } from '@pos-api-dist/bootstrap/create-app.js';
import { CartJobsHandler, registerCartJobs } from '@pos-api-dist/cart/cart-jobs.js';
import { createPool } from '@pos-api-dist/common/db/database.module.js';
import * as ports from '@pos-api-dist/common/ports/index.js';
import { SettingsReader } from '@pos-api-dist/common/settings/settings-reader.js';
import { QUEUES } from '@pos-api-dist/common/jobs/contracts/queues.js';
import { createOrdersWorkerWiring } from '@pos-api-dist/jobs/orders/orders-worker.wiring.js';
import { createOtpDeliveryListener } from '@pos-api-dist/jobs/otp/otp-delivery-listener.js';
import { createSyncWorkerWiring } from '@pos-api-dist/jobs/sync/sync-worker.wiring.js';
import { WorkerRuntime } from '@pos-api-dist/jobs/worker-runtime.js';
import { ReturnsStatusSyncHandler } from '@pos-api-dist/returns/onec/returns-jobs.bridge.js';
import { pinoSmsLogger } from '@pos-api-dist/integrations/sms/sms-telemetry.js';
import { SmsRuntime } from '@pos-api-dist/notifications/sms/sms-runtime.js';
import { schedulerConfigFromEnv } from '@pos-api-dist/sync/scheduler/scheduler.config.js';
import { ENTITY_QUEUES, EXTENSION_POLLED_ENTITIES, ONEC_EXCHANGE_NODE } from '@pos-api-dist/sync/scheduler/sync-queues.js';
import { PosFakeOnec } from '@pos-api-scripts/pos_fake_onec.ts';

import { DEMO_BUILD, DEMO_DATA, FLUSH, INVITATION, ONEC_GATEWAY_RETRY, QR_DEFAULTS, SEED_ACCOUNTS, STAFF, demoEnv } from './demo-config.mjs';
import { FakeOnecOverlay, createDemoCashierState } from './demo-overlay.mjs';
import { ensureUsers } from './snapshot/data-steps.mjs';
import { restoreSnapshot, verifySnapshot } from './snapshot/export-copy.mjs';
import { DemoStorage } from './demo-storage.mjs';

export { DemoStorage };

const now = () => performance.now();
const ms = (t) => Math.round(now() - t);
const rnd = (n = 32) => Buffer.from(crypto.getRandomValues(new Uint8Array(n))).toString('base64url');

/** Ошибка инициализации с кодом для страницы (fatal {code}). */
export class DemoInitError extends Error {
  constructor(code, message, cause) {
    super(message);
    this.name = 'DemoInitError';
    this.code = code;
    if (cause) this.cause = cause;
  }
}

// ======================================================================== хранилище и сброс на диск
// DemoStorage, IdbVolume и readFence — demo-storage.mjs (fix round 2: запись IndexedDB вне замка сессии и слота).

function opfsSupported() {
  try {
    return (
      typeof navigator !== 'undefined' &&
      typeof navigator.storage?.getDirectory === 'function' &&
      typeof FileSystemFileHandle !== 'undefined' &&
      'createSyncAccessHandle' in FileSystemFileHandle.prototype
    );
  } catch {
    return false;
  }
}
const idbSupported = () => typeof indexedDB !== 'undefined';

const isBusyError = (e) => e?.name === 'NoModificationAllowedError' || /access handle|locked|modification/i.test(String(e?.message));

/**
 * Файлы OPFS тома заняты другой вкладкой? opfs-ahp при запуске монопольно открывает state.txt и КАЖДЫЙ файл каталога
 * data/ (узлы файлов и пул). Пробуем открыть state.txt, а при полной проверке — и все файлы data/ (параллельно), и
 * сразу закрываем. → { busy, files, ms, stateAgeMs }.
 * build:site (2026-10-30): раньше проверялся только state.txt. Вкладка, которая уходит (разморожена → demo-closed),
 * отпускает дескрипторы не все разом: проверка state.txt проходила, а PGlite.create заставал часть файлов пула ещё
 * занятыми и зависал навсегда («ждём освобождения…» без конца; smoke --storage opfs, шаг frozen, ~1 из 4). Полная
 * проверка стоит ~1,1 с на 2800 файлов, поэтому она — только когда том мог держать другой контекст совсем недавно:
 * state.txt был занят в этом запуске (`full`) или менялся меньше OPFS_RECENT_MS назад (живой держатель пишет его при
 * каждом сбросе на диск). Тёплый старт тома, закрытого раньше, её не платит; редкий остаток гонки (держатель долго
 * не писал и только что завершился) ловит createOnOpfsGuarded — storage_busy вместо зависания.
 */
const OPFS_RECENT_MS = 120_000;
async function opfsProbe(dbName, { full = false } = {}) {
  const t0 = now();
  const open = [];
  let files = 0;
  let stateAgeMs = null;
  try {
    const root = await navigator.storage.getDirectory();
    const dir = await root.getDirectoryHandle(dbName, { create: true });
    const stateFh = await dir.getFileHandle('state.txt', { create: true });
    if (!full) {
      try {
        stateAgeMs = Math.max(0, Date.now() - (await stateFh.getFile()).lastModified);
      } catch {
        stateAgeMs = 0; // не прочитать — считаем, что том только что был занят
      }
    }
    // state.txt — первым и отдельно: замороженная вкладка держит все файлы, и тогда хватает одной попытки.
    open.push(await stateFh.createSyncAccessHandle());
    files = 1;
    const handles = [];
    let data = null;
    if (full || stateAgeMs < OPFS_RECENT_MS) {
      try {
        data = await dir.getDirectoryHandle('data');
      } catch (e) {
        if (e?.name !== 'NotFoundError') throw e;
      }
    }
    if (data && typeof data.values === 'function') for await (const h of data.values()) if (h.kind === 'file') handles.push(h);
    files += handles.length;
    const r = await Promise.allSettled(handles.map(async (fh) => open.push(await fh.createSyncAccessHandle())));
    const failed = r.find((x) => x.status === 'rejected');
    if (failed) throw failed.reason;
    return { busy: false, files, ms: Math.round(now() - t0), stateAgeMs };
  } catch (e) {
    if (isBusyError(e)) return { busy: true, files, ms: Math.round(now() - t0), stateAgeMs };
    throw e;
  } finally {
    for (const h of open) {
      try {
        h.close();
      } catch {
        /* уже закрыт */
      }
    }
  }
}

/**
 * PGlite.create на OPFS под охраной. opfs-ahp (PGlite 0.3.16) открывает файлы пула внутри `new Promise(async (resolve)
 * => …)`: занятый файл даёт unhandledrejection, а Promise.all ждёт вечно; ошибку узла данных он только пишет в
 * console.error и работает дальше без дескриптора. И то и другое значит «том занят» (файл захватили после opfsProbe) →
 * сразу storage_busy, без бесконечного ожидания: страница предлагает «Обновить страницу», перезагрузка завершает воркер и
 * отпускает то, что он успел открыть.
 */
async function createOnOpfsGuarded(PGlite, opts) {
  let busy = null;
  let trip = null;
  const hit = (e) => {
    busy ??= e;
    trip?.();
  };
  const onRejection = (ev) => {
    if (!isBusyError(ev?.reason)) return;
    ev.preventDefault?.();
    hit(ev.reason);
  };
  const origError = console.error;
  console.error = function (...a) {
    if (a[0] === 'Error opening file handle for node' && isBusyError(a[2])) hit(a[2]);
    return origError.apply(this, a);
  };
  globalThis.addEventListener?.('unhandledrejection', onRejection);
  const fail = () => new DemoInitError('storage_busy', 'Данные демо заняты другой вкладкой этого браузера (OPFS). Закройте её или перезагрузите страницу.', busy);
  try {
    const created = PGlite.create(opts);
    const tripped = new Promise((resolve) => {
      trip = () => resolve('busy');
      if (busy) trip();
    });
    const first = await Promise.race([created, tripped]);
    if (first === 'busy') {
      created.then((db) => db.close().catch(() => undefined), () => undefined);
      throw fail();
    }
    if (busy) {
      await first.close().catch(() => undefined);
      throw fail();
    }
    return first;
  } finally {
    globalThis.removeEventListener?.('unhandledrejection', onRejection);
    console.error = origError;
  }
}

/** Открыть PGlite: выбор хранилища с запасными вариантами; OPFS занят другой вкладкой → повтор, затем storage_busy. */
async function openPglite(init, { PGlite, extensions, base, storage, progress, log }) {
  const order = [init.storage ?? 'memory', ...(init.storageFallback ?? [])].filter((x, i, a) => a.indexOf(x) === i);
  if (!order.includes('memory')) order.push('memory');
  const tried = [];
  for (const kind of order) {
    if (kind === 'opfs' && !opfsSupported()) {
      tried.push('opfs: нет createSyncAccessHandle');
      continue;
    }
    if (kind === 'idb' && !idbSupported()) {
      tried.push('idb: нет IndexedDB');
      continue;
    }
    const pgOpts = { extensions, relaxedDurability: true };
    if (kind === 'opfs') {
      const until = now() + (init.opfsBusyRetryMs ?? FLUSH.opfsBusyRetryMs);
      let waited = 0;
      let probe;
      while ((probe = await opfsProbe(init.dbName, { full: waited > 0 })).busy) {
        if (!waited) progress('pglite', 6, 'Данные демо заняты другой вкладкой — ждём освобождения…');
        waited++;
        if (now() > until) throw new DemoInitError('storage_busy', 'Данные демо заняты другой вкладкой этого браузера (OPFS). Закройте её или перезагрузите страницу.');
        await new Promise((r) => setTimeout(r, 400));
      }
      const opfsProbeInfo = { files: probe.files, ms: probe.ms, busyRetries: waited, stateAgeMs: probe.stateAgeMs };
      const { OpfsAhpFS } = await import(/* @vite-ignore */ `${base}fs/opfs-ahp.js`);
      // Пул файлов OPFS: initdb + схема pos-api создают ~2000 файлов; maintainedPoolSize < ~1200 ломает 0001_init
      // («No more file handles available in the pool», WP-B0).
      const fs = new OpfsAhpFS(init.dbName, { initialPoolSize: init.opfsPool ?? 2000, maintainedPoolSize: init.opfsMaintained ?? 1200 });
      try {
        const db = await createOnOpfsGuarded(PGlite, { ...pgOpts, fs });
        return { db, kind, tried, opfsProbe: opfsProbeInfo };
      } catch (e) {
        if (e instanceof DemoInitError) throw e;
        if (e?.name === 'NoModificationAllowedError') throw new DemoInitError('storage_busy', 'Данные демо заняты другой вкладкой этого браузера (OPFS).', e);
        tried.push(`opfs: ${e?.message ?? e}`);
        log('warn', `PGlite на OPFS не открылся: ${e?.stack ?? e}; пробуем следующее хранилище`);
        continue;
      }
    }
    try {
      if (kind === 'idb') return { db: await PGlite.create(`idb://${init.dbName}`, pgOpts), kind, tried };
      const mem = { ...pgOpts };
      if (init.loadDataDir) mem.loadDataDir = new Blob([init.loadDataDir]);
      return { db: await PGlite.create('memory://', mem), kind: 'memory', tried };
    } catch (e) {
      tried.push(`${kind}: ${e?.message ?? e}`);
      log('warn', `PGlite (${kind}) не открылся: ${e?.stack ?? e}`);
      if (kind === 'memory') throw e;
    }
  }
  throw new DemoInitError('storage_failed', `Хранилище демо недоступно: ${tried.join('; ')}`);
}

// ======================================================================== demo_meta
const META_DDL = `CREATE TABLE IF NOT EXISTS demo_meta (key text PRIMARY KEY, value jsonb NOT NULL, updated_at timestamptz NOT NULL DEFAULT now())`;

async function readMeta(db) {
  const exists = (await db.query(`SELECT to_regclass('public.demo_meta') AS t`)).rows[0].t !== null;
  if (!exists) return { exists: false, values: {} };
  const r = await db.query(`SELECT key, value FROM demo_meta`);
  return { exists: true, values: Object.fromEntries(r.rows.map((x) => [x.key, x.value])) };
}
/** Записать ключ demo_meta напрямую в PGlite под замком сессии pg-shim (без подсадки в чужую транзакцию). */
export function writeMeta(db, key, value) {
  return pgShim.bossSessionLocked('demo.meta', `UPSERT demo_meta ${key}`, () =>
    db.query(`INSERT INTO demo_meta (key, value) VALUES ($1, $2::jsonb) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()`, [key, JSON.stringify(value)]),
  );
}

// ======================================================================== сотрудники, приглашение, служебные учётки
/**
 * Приглашение продавца 902 (critic [2]): создаётся или продлевается на каждом холодном старте; срок не «запекается»
 * в снимок. Уже вошедший по приглашению 902 не трогается.
 */
async function ensureInvitation(client) {
  const inv = INVITATION;
  const user = await client.query(`SELECT id FROM users WHERE phone_e164 = $1 AND deleted_at IS NULL`, [inv.phone]);
  if (user.rows[0]) return 'accepted';
  const admin = await client.query(`SELECT u.id FROM users u JOIN user_roles ur ON ur.user_id = u.id JOIN roles r ON r.id = ur.role_id WHERE r.code = 'admin' AND u.phone_e164 = $1`, [STAFF[0].phone]);
  const adminId = admin.rows[0]?.id;
  if (!adminId) return 'no-admin';
  const p = await client.query(
    `SELECT id, (expires_at - now() < make_interval(days => $2)) AS renew, expires_at <= now() AS expired FROM user_invitations WHERE phone_e164 = $1 AND status = 'pending'`,
    [inv.phone, inv.renewBelowDays],
  );
  const row = p.rows[0];
  if (row && !row.renew) return 'valid';
  if (row) {
    await client.query(`UPDATE user_invitations SET expires_at = now() + make_interval(days => $2), updated_at = now() WHERE id = $1`, [row.id, inv.days]);
    return row.expired ? 'revived' : 'extended';
  }
  await client.query(
    `INSERT INTO user_invitations (phone_e164, role, full_name, invited_by_user_id, expires_at) VALUES ($1, $2, $3, $4, now() + make_interval(days => $5))`,
    [inv.phone, inv.role, inv.name, adminId, inv.days],
  );
  return 'created';
}

// ======================================================================== восстановление после «падения процесса»
/**
 * critic [1]: процесс в эпохе один (одна вкладка), поэтому всё «в работе» на холодном старте — осиротевшее:
 * активные задачи pg-boss → retry сейчас (дубль ожидающей у stately/singleton → failed), прогоны sync_runs
 * running/queued → failed, строки outbox в аренде (sending) → pending сейчас. Выполняется ДО WorkerRuntime.start.
 */
async function crashRecovery(db, log) {
  const rep = { jobsRetried: 0, jobsFailed: 0, runsClosed: 0, outboxUnlocked: 0 };
  const hasBoss = (await db.query(`SELECT to_regclass('pgboss.job') AS t`)).rows[0].t !== null;
  if (hasBoss) {
    const active = await db.query(`SELECT id, name FROM pgboss.job WHERE state = 'active'`);
    for (const j of active.rows) {
      try {
        await db.query(`UPDATE pgboss.job SET state = 'retry', start_after = now(), heartbeat_on = NULL WHERE id = $1 AND name = $2 AND state = 'active'`, [j.id, j.name]);
        rep.jobsRetried++;
      } catch (e) {
        await db.query(
          `UPDATE pgboss.job SET state = 'failed', completed_on = now(), output = $3::jsonb WHERE id = $1 AND name = $2 AND state = 'active'`,
          [j.id, j.name, JSON.stringify({ message: 'демо: задача прервана перезагрузкой вкладки; ожидающая задача той же очереди уже есть' })],
        );
        rep.jobsFailed++;
        log('info', `восстановление: задача ${j.name} ${j.id}: ${e?.message ?? e} → failed`);
      }
    }
  }
  const runs = await db.query(
    `UPDATE sync_runs SET status = 'failed', finished_at = now(),
            duration_ms = LEAST(2147483647, GREATEST(0, (extract(epoch FROM now() - COALESCE(started_at, created_at)) * 1000)::bigint))::int,
            error_summary = 'Прервано: вкладка демо была закрыта или перезагружена во время прогона', updated_at = now()
      WHERE status IN ('queued', 'running') RETURNING id`,
  );
  rep.runsClosed = runs.rows.length;
  const ob = await db.query(
    `UPDATE onec_outbox SET status = 'pending', lease_until = NULL, locked_by = NULL, next_attempt_at = now(), updated_at = now()
      WHERE status = 'sending' RETURNING id`,
  );
  rep.outboxUnlocked = ob.rows.length;
  return rep;
}

/** Факты PGlite для сверки имитатора 1С (заказы с номером 1С, ожидающие QR, номер сообщения узла). */
async function readPosFacts(db) {
  const orders = await db.query(
    `SELECT id::text AS id, onec_ref::text AS onec_ref, onec_number, onec_date, onec_status_raw, total::text AS total, created_at
       FROM orders WHERE onec_ref IS NOT NULL OR onec_number IS NOT NULL`,
  );
  const qrs = await db.query(
    `SELECT id::text AS id, order_id::text AS order_id, amount::text AS amount, qr_expires_at, qr_provider_ref, qr_issued_at, created_at
       FROM payments WHERE qr_provider = 'onec' AND status IN ('qr_pending', 'qr_shown')`,
  );
  const node = await db.query(`SELECT max(last_message_number)::text AS n FROM sync_node_state`);
  return { orders: orders.rows, qrs: qrs.rows, lastMessageNumber: Number(node.rows[0]?.n ?? 0) };
}

// ======================================================================== снимок БД (WP-B4)
/**
 * Снимок, собранный при сборке (snapshot/build-snapshot.mjs): site/demo/snapshot/{manifest.json, data.copy.gz}.
 * Источник: init.snapshotData ({ manifest: текст|объект, dataGz | data: ArrayBuffer } — Node-тесты) или
 * fetch(init.snapshotUrl) своего origin. → { manifest, data, fetchMs, unzipMs, verifyMs, gzBytes } или { skip }.
 * Снимок используется, только если это тот снимок, с которым собран этот backend.js (DEMO_BUILD.snapshot.dataSha256;
 * init.snapshotAnyBuild — тесты со снимком из другого каталога), и число SKU совпадает с запрошенным; иначе —
 * запасной путь: каталог настоящим конвейером (как до WP-B4, без фото).
 */
async function loadSnapshotSource(init) {
  const t = now();
  const want = DEMO_BUILD.snapshot ?? null;
  if (init.snapshot === false) return { skip: 'выключен (init.snapshot=false)' };
  let manifest;
  let gz = null;
  let raw = null;
  if (init.snapshotData) {
    const m = init.snapshotData.manifest;
    manifest = typeof m === 'string' ? JSON.parse(m) : m;
    gz = init.snapshotData.dataGz ?? null;
    raw = init.snapshotData.data ?? null;
  } else {
    if (!init.snapshotUrl) return { skip: 'нет snapshotUrl' };
    if (!want) return { skip: 'backend.js собран без снимка' };
    const base = assertSameOrigin(String(init.snapshotUrl).replace(/\/?$/, '/'), 'fetch');
    const mr = await fetch(`${base}manifest.json`, { cache: 'no-cache' });
    if (!mr.ok) return { skip: `manifest.json: HTTP ${mr.status}` };
    manifest = await mr.json();
    const name = manifest?.data?.gzipFile ?? 'data.copy';
    const dr = await fetch(`${base}${name}`, { cache: 'no-cache' });
    if (!dr.ok) return { skip: `${name}: HTTP ${dr.status}` };
    if (manifest?.data?.gzipFile) gz = await dr.arrayBuffer();
    else raw = await dr.arrayBuffer();
  }
  if (want && !init.snapshotAnyBuild && manifest?.data?.sha256 !== want.dataSha256) {
    return { skip: `снимок сайта ${String(manifest?.data?.sha256).slice(0, 12)}… ≠ снимок сборки бэкенда ${String(want.dataSha256).slice(0, 12)}…` };
  }
  const sku = manifest?.source?.catalog?.skuCount;
  if (init.sku !== undefined && Number(init.sku) !== sku) return { skip: `снимок на ${sku} SKU, запрошено ${init.sku}` };
  const fetchMs = ms(t);
  const t2 = now();
  let data;
  // Review fixes (Netlify): если хостинг отдал data.copy.gz с Content-Encoding: gzip, браузер уже распаковал тело —
  // распаковываем, только если это действительно gzip (сигнатура 1f 8b); иначе sha256 ниже проверит распакованное.
  const isGzip = gz && gz.byteLength > 2 && new Uint8Array(gz, 0, 2)[0] === 0x1f && new Uint8Array(gz, 0, 2)[1] === 0x8b;
  if (gz && isGzip) data = new Uint8Array(await new Response(new Blob([gz]).stream().pipeThrough(new DecompressionStream('gzip'))).arrayBuffer());
  else data = new Uint8Array(gz ?? raw);
  const unzipMs = ms(t2);
  const t3 = now();
  await verifySnapshot(manifest, data);
  return { manifest, data, fetchMs, unzipMs, verifyMs: ms(t3), gzBytes: gz?.byteLength ?? null };
}

/** Миграции, dev-миграции и seeds снимка = файлы этого бандла (виртуальная fs): имена и sha256. */
async function snapshotMigrationsMatch(manifest) {
  const hex = async (buf) => [...new Uint8Array(await crypto.subtle.digest('SHA-256', buf))].map((b) => b.toString(16).padStart(2, '0')).join('');
  const own = async (dir, re) => {
    const out = [];
    for (const f of fsShim.readdirSync(dir).filter((x) => re.test(x)).sort()) out.push([f, await hex(new Uint8Array(fsShim.readFileSync(`${dir}/${f}`)))]);
    return out;
  };
  const a = JSON.stringify([await own('/vfs/pos-api/migrations', /^\d{4}_.*\.sql$/), await own('/vfs/pos-api/db/migrations-dev', /\.sql$/), await own('/vfs/pos-api/seeds', /\.sql$/)]);
  const b = JSON.stringify([manifest.source?.migrations ?? [], manifest.source?.devMigrations ?? [], manifest.source?.seeds ?? []]);
  return a === b;
}

// ======================================================================== инициализация
/**
 * init — сообщение страницы (plan §3.3 + handoff WP-S1): { epochKey, dbName, storage, storageFallback, generation,
 * pgliteBase, buildId, … } (поля и на верхнем уровне, и в opts). ctx — { post, log, progress }.
 */
export async function initBackend(init, ctx) {
  const { post, log, progress } = ctx;
  const T = {};
  const t0 = now();
  if (init.gate) gate.configureGate(init.gate);
  pgShim.configureShim({ ...(init.shim ?? {}), ...(init.strict ? { strict: true } : {}) });
  configureOnecGateway(init.onecRetry ?? ONEC_GATEWAY_RETRY);

  progress('pglite', 5);
  // import() не перехватывается запретом сети — адрес PGlite проверяется явно (только свой origin).
  const base = assertSameOrigin(String(init.pgliteBase), 'import');
  const [{ PGlite }, { pgcrypto }, { pg_trgm }, { unaccent }] = await Promise.all([
    import(/* @vite-ignore */ `${base}index.js`),
    import(/* @vite-ignore */ `${base}contrib/pgcrypto.js`),
    import(/* @vite-ignore */ `${base}contrib/pg_trgm.js`),
    import(/* @vite-ignore */ `${base}contrib/unaccent.js`),
  ]);
  T.pgliteImportMs = ms(t0);
  const t1 = now();
  const storage = new DemoStorage({ kind: 'memory', dbName: init.dbName, generation: init.generation, tabId: init.tabId ?? null, post, log, testCommitDelayMs: init.testFlushCommitDelayMs, testFailures: init.testFlushFailures });
  // Fence до открытия тома: вкладка, у которой том уже забрали, не открывает его вовсе.
  if (!(await storage.fenceOk())) throw new DemoInitError('fenced', 'Демо открыто в другой вкладке.');
  const opened = await openPglite(init, { PGlite, extensions: { pgcrypto, pg_trgm, unaccent }, base, storage, progress, log });
  const db = opened.db;
  storage.kind = opened.kind;
  storage.attach(db);
  T.storage = opened.kind;
  if (opened.tried.length) T.storageTried = opened.tried;
  if (opened.opfsProbe) T.opfsProbe = opened.opfsProbe;
  T.pgliteCreateMs = ms(t1);
  pgShim.attachPglite(db);
  pgShim.attachDrizzleScope(NodePgSession);
  bossShim.attachPgliteToBoss(db);
  globalThis.__posPglite = db;
  const pg = pgShim.default;

  // ---------------------------------------------------------------- миграции и данные
  let meta = await readMeta(db);
  const epochMeta = meta.values.epoch ?? null;
  const warm = !!epochMeta?.initComplete;
  T.warm = warm;
  const ownKey = DEMO_BUILD.epochKey;
  if (init.epochKey && init.epochKey !== ownKey) log('warn', `ключ эпохи страницы ${init.epochKey} ≠ ключ сборки бэкенда ${ownKey} (demo/build.json и backend/build.json разошлись)`);
  if (warm && epochMeta.epochKey && epochMeta.epochKey !== ownKey) log('warn', `данные эпохи ${epochMeta.epochKey}, бэкенд эпохи ${ownKey}: настоящий мигратор проверит совместимость`);

  // Снимок (WP-B4) грузится параллельно с миграциями — только на холодном старте, пока каталог не загружен.
  // init.snapshotPreloaded (только тесты, memory + loadDataDir): данные уже в каталоге данных PGlite (формат S1,
  // dumpDataDir обычной сборки) — seeds и каталог не выполняются, как после восстановления S2.
  const preloadedS1 = !warm && !!init.snapshotPreloaded && !!init.loadDataDir && !meta.values.catalog?.loaded;
  const snapshotP = !warm && !preloadedS1 && !meta.values.catalog?.loaded ? loadSnapshotSource(init).catch((e) => ({ skip: `загрузка: ${e?.message ?? e}` })) : null;

  progress('migrate', 20, warm ? 'Проверяем базу демо…' : 'Создаём базу демо…');
  const t2 = now();
  const quiet = { info() {}, warn: (o, m) => log('warn', `migrate: ${m ?? ''} ${JSON.stringify(o)}`) };
  const mc = new pg.Client({ application_name: 'demo-init' });
  try {
    const r1 = await migrate(mc, { dir: '/vfs/pos-api/migrations', appEnv: 'dev', logger: quiet });
    const r2 = await migrate(mc, { dir: '/vfs/pos-api/db/migrations-dev', appEnv: 'dev', logger: quiet, journalSchema: DEV_MIGRATIONS_SCHEMA });
    T.migrationsApplied = [...(r1?.applied ?? []), ...(r2?.applied ?? [])].length;
    // OPFS: пул файлов opfs-ahp пополняется только в syncToFs — после схемы (≈ 2000 файлов) пополнить его сразу.
    if (opened.kind === 'opfs' && T.migrationsApplied > 0) T.poolFlush = await storage.flush('init:migrate');
  } catch (e) {
    if (warm && /MIGRATION_(CHECKSUM_MISMATCH|MISSING_FILE|OUT_OF_ORDER)/.test(`${e?.code ?? ''} ${e?.message ?? ''}`)) {
      throw new DemoInitError('epoch_incompatible', `Данные демо в этом браузере несовместимы с новой версией сайта (${e.message}). Нажмите «Сбросить демо».`, e);
    }
    throw e;
  }
  T.migrateMs = ms(t2);

  // Холодный старт: снимок сборки (seeds, сотрудники, служебные учётки сида, каталог и фото уже в нём) или — запасной
  // путь — seeds + сотрудники + каталог конвейером ниже.
  let snapshotUsed = null;
  if (preloadedS1) {
    snapshotUsed = { format: 's1-datadir', data: { sha256: null }, source: { catalog: { skuCount: init.sku ?? null } }, images: null };
    T.snapshot = { used: true, format: 's1-datadir' };
  }
  if (snapshotP) {
    const src = await snapshotP;
    if (src.skip) T.snapshot = { used: false, reason: src.skip };
    else if (!(await snapshotMigrationsMatch(src.manifest))) T.snapshot = { used: false, reason: 'миграции/seeds снимка ≠ миграции бандла' };
    else {
      progress('snapshot', 30, 'Загружаем данные демо…');
      try {
        const r = await pgShim.bossSessionLocked('demo.snapshot', 'RESTORE snapshot', () => restoreSnapshot(db, src.manifest, src.data));
        snapshotUsed = src.manifest;
        T.snapshot = { used: true, format: src.manifest.format, dataSha256: src.manifest.data.sha256, bytes: src.data.byteLength, gzBytes: src.gzBytes, fetchMs: src.fetchMs, unzipMs: src.unzipMs, verifyMs: src.verifyMs, restoreMs: r.ms, rows: r.rows, tables: r.tables, rebased: r.rebased, audit: r.audit, steps: r.steps };
        if (opened.kind === 'opfs') await storage.flush('init:snapshot');
      } catch (e) {
        T.snapshot = { used: false, reason: `восстановление: ${e?.message ?? e}` };
        log('warn', `снимок не восстановлен, запасной путь (каталог конвейером): ${e?.stack ?? e}`);
      }
    }
    if (!T.snapshot.used) log('warn', `снимок не используется: ${T.snapshot.reason}`);
  }
  if (!warm) {
    const t3 = now();
    if (!snapshotUsed) await seed(mc, { dir: '/vfs/pos-api/seeds', logger: quiet, params: { receivables_max_age_min: '60' } });
    await mc.query(META_DDL);
    await mc.query('BEGIN');
    T.staffCreated = await ensureUsers(mc, STAFF);
    T.seedAccountsCreated = await ensureUsers(mc, SEED_ACCOUNTS);
    await mc.query('COMMIT');
    T.seedMs = ms(t3);
    if (snapshotUsed) {
      const c = snapshotUsed.source?.catalog ?? {};
      await writeMeta(db, 'catalog', { loaded: true, source: 'snapshot', at: new Date().toISOString(), skuCount: c.skuCount ?? null, dataSha256: snapshotUsed.data.sha256, images: snapshotUsed.images?.products ?? 0 });
    }
    meta = await readMeta(db);
  }

  // ---------------------------------------------------------------- секреты и ключ JWT эпохи (demo_meta)
  let secrets = meta.values.secrets;
  if (!secrets?.otpHmac || !secrets?.pinPepper || !secrets?.onecToken) {
    secrets = { otpHmac: rnd(), pinPepper: rnd(), onecToken: rnd(24) };
    await writeMeta(db, 'secrets', secrets);
  }
  let jwt = meta.values.jwt;
  if (jwt?.jwk) await prepareJwtKeyRing({ kid: jwt.kid, jwk: jwt.jwk });
  else {
    jwt = await prepareJwtKeyRing({ kid: 'demo-epoch' });
    await writeMeta(db, 'jwt', jwt);
  }

  // ---------------------------------------------------------------- каталог (холодный старт)
  // Один синтетический каталог (seed 1) — и для первой загрузки, и для срезов stock/prices pos-worker.
  const catalogGw = new FakeOnecGateway({ catalog: { skuCount: init.sku ?? DEMO_DATA.catalog.skuCount, seed: DEMO_DATA.catalog.seed }, includeFixtureCatalog: DEMO_DATA.catalog.includeFixtureCatalog, registerAll: false });
  if (!warm && !meta.values.catalog?.loaded) {
    progress('catalog', 40, 'Загружаем каталог…');
    const t4 = now();
    const cpool = new pg.Pool({ application_name: 'catalog-load' });
    const r = await new CatalogFullLoadService(cpool, new CatalogApplier(), createRunTracker(cpool), pino({ level: 'silent' })).loadAll(new SyntheticCatalogSource(catalogGw), 'full', 'manual');
    T.catalogMs = ms(t4);
    if (opened.kind === 'opfs') await storage.flush('init:catalog');
    await writeMeta(db, 'catalog', { loaded: true, at: new Date().toISOString(), skuCount: init.sku ?? DEMO_DATA.catalog.skuCount, status: r?.status ?? null });
  }

  // ---------------------------------------------------------------- каждый старт: приглашение, восстановление
  const t5 = now();
  await mc.query('BEGIN');
  T.invitation = await ensureInvitation(mc);
  await mc.query('COMMIT');
  // Всегда: и оборванная холодная инициализация могла успеть запустить pg-boss.
  T.recovery = await crashRecovery(db, log);
  T.recoveryMs = ms(t5);

  // Шрифты PDF: pdfkit (browser-сборка) читает файлы только из своего реестра; Helvetica — шрифт по умолчанию
  // конструктора PDFDocument. Inter — внешние файлы vfs (site/backend/vfs/…): fetch своего origin или байты Node.
  if (init.vfsExternal) for (const [k, bytes] of Object.entries(init.vfsExternal)) fsShim.__vfs.provide(k, new Uint8Array(bytes));
  else await fsShim.__vfs.preloadExternal(new URL('./', import.meta.url));
  registerStdFonts(Helvetica);
  for (const f of ['Inter-Regular.ttf', 'Inter-Bold.ttf']) {
    const p = `/vfs/pos-api/assets/fonts/${f}`;
    pdfkitRegisterFile(p, new Uint8Array(fsShim.readFileSync(p)));
  }

  // ---------------------------------------------------------------- имитатор 1С: состояние и сверка (critic [0])
  progress('fake1c', 55, 'Запускаем имитатор «1С»…');
  const t6 = now();
  const cs = createDemoCashierState({ SyntheticCashier, SyntheticCatalog, FakeExchangePlan, catalogProducts }, { catalogSku: init.sku ?? DEMO_DATA.catalog.skuCount, extraCustomers: DEMO_DATA.cashier.extraCustomers });
  const fake = new PosFakeOnec(init.qrPaidAfterPolls ?? QR_DEFAULTS.paidAfterPolls, cs);
  let fakeDirty = false;
  const overlay = new FakeOnecOverlay(fake, cs, { onDirty: () => (fakeDirty = true) });
  // testDropFakeState (только тесты): как если бы состояние имитатора не успело сохраниться — остаётся сверка с PGlite.
  T.fakeRestore = overlay.restore(init.testDropFakeState ? null : meta.values.fake, log);
  T.fakeReconcile = overlay.reconcile(await readPosFacts(db));
  setFakeOnec(fake);
  globalThis.__posFakeOnec = fake;
  // Review fixes: снимок состояния — до записи; флаги «изменено» снимаются до await (изменения во время записи снова
  // их ставят), а при сбое записи возвращаются: несохранённое состояние имитатора сохранится в конце следующей единицы.
  const persistFake = async (force = false) => {
    if (!force && !fakeDirty && !overlay.dirty) return false;
    const snapshot = overlay.serialize();
    fakeDirty = false;
    overlay.dirty = false;
    try {
      await writeMeta(db, 'fake', snapshot);
    } catch (e) {
      fakeDirty = true;
      overlay.dirty = true;
      throw e;
    }
    return true;
  };
  const isFakeDirty = () => fakeDirty || !!overlay.dirty;
  await persistFake(true);
  T.fakeOnecMs = ms(t6);

  // ---------------------------------------------------------------- pos-api
  const config = loadAppConfig(demoEnv(secrets, { overrides: init.env ?? {} }));
  progress('nest', 70, 'Запускаем сервер…');
  const t7 = now();
  const app = await createApp(config);
  const handler = app.getHttpAdapter().getInstance();
  T.createAppMs = ms(t7);

  // ---------------------------------------------------------------- pos-worker
  progress('worker', 85, 'Запускаем фоновые задачи…');
  const t8 = now();
  const wlog = pino({ level: 'warn', base: { service: 'pos-worker' } });
  const wpool = createPool(config, 'pos-worker');
  const sms = new SmsRuntime({ config, pool: wpool, logger: pinoSmsLogger(wlog.child({ component: 'sms' })), listener: createOtpDeliveryListener({ config, pool: wpool }) });
  const schedulerConfig = schedulerConfigFromEnv(config, init.schedulerOverrides ?? {});
  // Срезы stock/prices в режиме расширения — тот же синтетический каталог (seed 1), что загружен в БД.
  const sync = createSyncWorkerWiring({ config, pool: wpool, log: wlog, scheduler: schedulerConfig, source: new SyntheticCatalogSource(catalogGw) });
  const orders = createOrdersWorkerWiring({
    config,
    pool: wpool,
    log: wlog,
    ...(sync.gateway ? { gateway: sync.gateway } : {}),
    cart: app.get(ports.CART_READER),
    payments: app.get(ports.PAYMENTS_PORT),
    notifications: app.get(ports.NOTIFICATIONS_PORT),
  });
  const cartJobs = app.get(CartJobsHandler, { strict: false });
  const runtime = new WorkerRuntime({
    handlers: { ...sync.handlers, ...orders.handlers, return_docs: app.get(ReturnsStatusSyncHandler, { strict: false }) },
    jobs: { ...sync.jobs, ...orders.jobs },
    onRunFinished: sync.onRunFinished,
    ...(orders.outboxDelivery ? { outboxDelivery: orders.outboxDelivery } : {}),
    outboxHooks: orders.outboxHooks,
    extraWorkers: [
      (boss) => (sync.catalogChanges.attach(boss), Promise.resolve()),
      (boss) => sync.changeJobs.attach(boss),
      (boss) => sms.register(boss),
      (boss) => orders.register(boss),
      (boss) => registerCartJobs(boss, cartJobs, { pollingIntervalSeconds: 2, log: { warn() {}, info() {} } }),
    ],
    enabled: true,
    connectionString: config.DATABASE_URL,
    pool: wpool,
    settings: new SettingsReader(wpool),
    scheduler: schedulerConfig,
    log: wlog,
  });
  await runtime.start();
  T.workerStartMs = ms(t8);

  // ---------------------------------------------------------------- отметка эпохи
  const startedAt = new Date().toISOString();
  const epochValue = {
    ...(epochMeta ?? {}),
    epochKey: epochMeta?.epochKey ?? ownKey,
    backendEpochKey: ownKey,
    createdAt: epochMeta?.createdAt ?? startedAt,
    initComplete: true,
    buildId: init.buildId ?? null,
    appVersion: DEMO_BUILD.appVersion,
    coldStarts: (epochMeta?.coldStarts ?? 0) + (warm ? 0 : 1),
    warmStarts: (epochMeta?.warmStarts ?? 0) + (warm ? 1 : 0),
    lastStartAt: startedAt,
    storage: opened.kind,
  };
  await writeMeta(db, 'epoch', epochValue);
  storage.startBackground();
  // Первый сброс тома: холодная инициализация (миграции, каталог) не должна потеряться при выгрузке вкладки.
  T.firstFlush = await storage.flush('init');
  T.totalMs = ms(t0);

  return {
    db,
    app,
    handler,
    runtime,
    config,
    storage,
    fake,
    overlay,
    cs,
    persistFake,
    isFakeDirty,
    meta: { ...meta.values, epoch: epochValue, secrets: undefined, jwt: undefined },
    seedState: meta.values.seed ?? null,
    warm,
    timings: T,
  };
}

/**
 * Догоняние расписаний (critic [2]): pg-boss не выполняет пропущенные cron, а снимок и сохранённые данные стареют
 * между визитами. На каждом холодном старте — задачи всех сущностей расписания режима extension, цикл плана обмена,
 * клиенты и outbox. stately/singleton отбрасывают дубль уже ожидающей задачи (send → null).
 */
export async function catchUp(runtime, log) {
  const boss = runtime.boss;
  const sent = {};
  const send = async (queue, data, key) => {
    try {
      sent[queue] = (await boss.send(queue, data, key ? { singletonKey: key } : {})) ? 'sent' : 'dup';
    } catch (e) {
      sent[queue] = `error: ${e?.message ?? e}`;
      log('warn', `догоняние: ${queue}: ${e?.message ?? e}`);
    }
  };
  const job = (entity) => [ENTITY_QUEUES[entity].queue, { entity, mode: 'incremental', trigger: 'schedule' }, entity];
  // receivables — только после customers (fix round 1, WP-T1 дефект 3): клиентов «1С» в снимке нет, их приносит
  // синхронизация customers, а receivables опрашивает долги только известных POS клиентов. Поставленная раньше,
  // задача receivables (pg-boss выбирает порядок сам) получала 0 снимков, и долги «Просрочка»/«Долг в лимите» не были
  // видны до следующего запуска по расписанию (до 30 мин). Задача ставится после завершения ближайшей задачи
  // customers (pgboss-shim afterNextJob — вне её единицы работы, после COMMIT), не позже чем через
  // CATCH_UP_RECEIVABLES_MAX_WAIT_MS.
  for (const entity of EXTENSION_POLLED_ENTITIES) if (entity !== 'receivables') await send(...job(entity));
  await send(QUEUES.onecChanges, { node: ONEC_EXCHANGE_NODE }, ONEC_EXCHANGE_NODE);
  const rq = ENTITY_QUEUES.receivables.queue;
  sent[rq] = 'after customers';
  let fired = false;
  let timer = null;
  let cancel = () => undefined;
  const queueReceivables = (why) => {
    if (fired) return;
    fired = true;
    if (timer) clearTimeout(timer);
    cancel();
    void send(...job('receivables')).then(() => {
      catchUpState.receivables = { after: why, result: sent[rq], at: new Date().toISOString() };
      log('info', `догоняние: ${rq} после ${why} → ${sent[rq]}`);
    });
  };
  cancel = bossShim.afterNextJob(ENTITY_QUEUES.customers.queue, (o) => queueReceivables(o.ok ? 'customers' : 'customers (ошибка задачи)'));
  timer = setTimeout(() => queueReceivables('ожидания customers'), CATCH_UP_RECEIVABLES_MAX_WAIT_MS);
  timer?.unref?.();
  await send(...job('customers'));
  if (String(sent[ENTITY_QUEUES.customers.queue]).startsWith('error')) queueReceivables('ошибки постановки customers');
  await send(QUEUES.outboxDispatch, {});
  return sent;
}
/** Наибольшее ожидание задачи customers перед постановкой receivables при догонянии. */
export const CATCH_UP_RECEIVABLES_MAX_WAIT_MS = 60_000;
/** Итог отложенной постановки receivables последнего догоняния (для /__demo/state и тестов). */
export const catchUpState = { receivables: null };
