// Приёмка WP-B4 (снимок БД, фото, замена ПДн; plan §3.5, §4 WP-B4; critic [2], [10], [20]) на собранном
// site/backend/backend.js в Node (worker_threads, storage 'memory'; снимок — байты site/demo/snapshot, как fetch в
// браузере).
//
//   node demo/web/backend/test/harness/b4-acceptance.mjs [--json <файл>] [--quiet] [--skip-determinism] [--skip-s1]
//
// Фазы:
//   D. Детерминизм: две независимые сборки снимка (build-snapshot.mjs в каталоги .tmp) дают manifest.json,
//      одинаковый с .build/snapshot/manifest.json (кроме builtAt), тот же data.copy и тот же список фото.
//   I. Фото: каждый файл site/images/{sha}/{size}.webp совпадает с images.json (sha256, байты); каталоги = sha строк
//      product_images; адреса фото из ответов API указывают на существующие файлы.
//   S2. Холодный старт со снимком S2: время восстановления, состав таблиц, время данных сдвинуто на момент
//      восстановления (ничего «запечённого»), приглашения/OTP/сессий в снимке нет, аудит сходится; служебные
//      учётки «Демо-история …»; сценарии клиентов: просрочка → CREDIT_BLOCKED, «Лимит превышен» →
//      CREDIT_LIMIT_EXCEEDED, «Долг в лимите» → 201; запрещённые строки ПДн — ни в одном ответе; /sync/status ok.
//   S1. Тот же состав, загруженный как каталог данных PGlite (dumpDataDir обычной, не детерминированной сборки —
//      .build/snapshot/s1-datadir.tar.gz, build-snapshot.mjs --s1): число строк всех таблиц и ответы
//      GET /catalog/products, /search/products?q=F4252, /catalog/sync/products совпадают с S2 (id и время маскируются).
//   P. Запасной путь без снимка (каталог конвейером, как WP-B3): те же ответы без полей фото совпадают с S2.
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { dirname, extname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { startWorkerBackend } from './worker-harness.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const BACKEND = resolve(HERE, '../..').replace(/\\/g, '/');
const WEB = resolve(BACKEND, '..').replace(/\\/g, '/');
const ROOT = resolve(WEB, '../..').replace(/\\/g, '/');
const SITE = `${WEB}/site`;
const SNAP = `${WEB}/.build/snapshot`;
const argv = process.argv.slice(2);
const arg = (k, d) => {
  const i = argv.indexOf(k);
  return i >= 0 ? argv[i + 1] : d;
};
const QUIET = argv.includes('--quiet');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const T0 = Date.now();
const el = () => `${((Date.now() - T0) / 1000).toFixed(1)}s`.padStart(7);
const say = (...a) => {
  if (!QUIET) console.log(el(), ...a);
};
const sha256 = (b) => createHash('sha256').update(b).digest('hex');
const VERSION = '0.1.0+1';
const crit = [];
const add = (criterion, met, evidence) => {
  crit.push({ criterion, met: !!met, evidence });
  console.log(`${met ? 'OK  ' : 'FAIL'} ${criterion}\n      ${String(evidence).slice(0, 700)}`);
};
const all5xx = [];
const dec = new TextDecoder();

process.env.TEMP ||= `${ROOT}/.tmp`;
process.env.TMP ||= `${ROOT}/.tmp`;

const { forbiddenStrings, scanText } = await import(pathToFileURL(`${BACKEND}/snapshot/forbidden.mjs`).href);
const { DEMO_DATA } = await import(pathToFileURL(`${BACKEND}/demo-config.mjs`).href);
const piiMap = JSON.parse(readFileSync(`${BACKEND}/pii-map.json`, 'utf8'));
const FORBIDDEN = forbiddenStrings(piiMap, { cashierSeed: DEMO_DATA.cashier.seed, extraCustomers: DEMO_DATA.cashier.extraCustomers }).strings;

/** Клиент API одного «устройства» поверх моста; тела ответов копятся для проверки ПДн. */
class Dev {
  constructor(be, bodies, platform = 'windows') {
    this.be = be;
    this.bodies = bodies;
    this.platform = platform;
    this.deviceId = crypto.randomUUID();
    this.token = null;
  }
  get H() {
    return { 'X-Device-Id': this.deviceId, 'X-App-Version': VERSION, 'X-Platform': this.platform, 'Accept-Language': 'ru', ...(this.token ? { Authorization: `Bearer ${this.token}` } : {}) };
  }
  async call(method, url, { body, headers = {}, idem = false, quiet = false } = {}) {
    const r = await this.be.api(method, `/api/v1${url}`, { headers: { ...this.H, ...headers, ...(idem ? { 'Idempotency-Key': crypto.randomUUID() } : {}) }, body });
    if (r.status >= 500) all5xx.push({ method, url: url.split('?')[0], status: r.status, code: r.json?.code });
    if (r.bytes?.length && /json|text/.test(r.headers?.['content-type'] ?? '')) this.bodies.push({ url: url.split('?')[0], text: dec.decode(r.bytes) });
    if (!quiet) say(String(r.status).padEnd(4), String(r.ms).padStart(5) + 'ms', method, url.slice(0, 90), r.json?.code ?? '');
    return r;
  }
  async login(phone, pin = '715382') {
    let rq = await this.call('POST', '/auth/otp/request', { body: { phone, purpose: 'login_or_register', locale: 'ru' } });
    for (let i = 0; i < 4 && rq.status === 429; i++) {
      await sleep(11000);
      rq = await this.call('POST', '/auth/otp/request', { body: { phone, purpose: 'login_or_register', locale: 'ru' } });
    }
    const vr = await this.call('POST', '/auth/otp/verify', { body: { challengeId: rq.json?.challengeId, code: '246810', device: { name: 'Node (b4)', platform: this.platform, appVersion: VERSION } } });
    this.token = vr.json?.accessToken; // check-secrets: allow — токен из ответа API в прогоне, не секрет; gitleaks:allow
    if (pin && vr.json?.kind !== 'customer') await this.call('POST', '/me/pin', { body: { newPin: pin }, idem: true });
    return vr;
  }
  async stepUp(operation) {
    return (await this.call('POST', '/auth/step-up', { body: { method: 'pin', operation, pin: '715382' } })).json?.stepUpToken;
  }
}

async function until(fn, ok, timeoutMs, every = 500) {
  const end = Date.now() + timeoutMs;
  for (;;) {
    const v = await fn();
    if (ok(v)) return { v, ok: true };
    if (Date.now() > end) return { v, ok: false };
    await sleep(every);
  }
}
async function syncRun(admin, entity) {
  const su = await admin.stepUp('sync.run.full');
  const st = await admin.call('POST', '/sync/runs', { idem: true, headers: { 'X-Step-Up-Token': su }, body: { entity, mode: 'incremental' } }); // check-secrets: allow
  if (!st.json?.id) return st.json?.code ?? st.status;
  const r = await until(async () => (await admin.call('GET', `/sync/runs/${st.json.id}`, { quiet: true })).json, (x) => ['success', 'partial', 'failed'].includes(x?.status), 90000, 300);
  return r.v?.status;
}

/** Заказ с одной строкой (qty) на клиента в долг. */
async function sellCredit(d, p, qty, customerId) {
  let c = (await d.call('GET', '/cart')).json;
  if ((c?.items ?? []).length) c = (await d.call('DELETE', `/cart?rowVersion=${c.rowVersion}`)).json;
  c = (await d.call('PUT', `/cart/items/${p.defaultVariantId}`, { idem: true, body: { quantity: { value: String(qty), unitId: p.baseUnit.id, packagingId: null }, rowVersion: c.rowVersion, mode: 'set' } })).json;
  c = (await d.call('POST', '/cart/customer', { idem: true, body: { customerId, rowVersion: c.rowVersion } })).json;
  const pv = await d.call('POST', '/cart/checkout-preview', { idem: true, body: { cartId: c.id, cartRowVersion: c.rowVersion, paymentMethod: 'credit', delivery: { method: 'pickup' }, receiver: { kind: 'customer' } } });
  return d.call('POST', '/orders', {
    idem: true,
    body: {
      cartId: c.id,
      cartRowVersion: c.rowVersion,
      ...(pv.json?.previewToken ? { previewToken: pv.json.previewToken } : {}),
      customerId,
      receiver: { kind: 'customer' },
      delivery: { method: 'pickup' },
      paymentMethod: 'credit',
      items: [{ variantId: p.defaultVariantId, quantity: { value: String(qty), unitId: p.baseUnit.id, packagingId: null } }],
    },
  });
}

// ---------------------------------------------------------------- маскирование для сравнения S1/S2/конвейер
const UUID_RE = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi;
const ISO_RE = /\b\d{4}-\d\d-\d\d[T ]\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d(?::?\d\d)?)?/g;
const MASK_KEYS = /^(nextCursor|cursor|etag|asOf|dataAsOf|serverTime|generatedAt|requestId)$/;
function mask(v, { dropImages = false } = {}) {
  if (Array.isArray(v)) return v.map((x) => mask(x, { dropImages }));
  if (v && typeof v === 'object') {
    const o = {};
    for (const [k, x] of Object.entries(v)) {
      if (dropImages && /image|thumb|photo/i.test(k)) continue;
      o[k] = MASK_KEYS.test(k) ? 'M' : mask(x, { dropImages });
    }
    return o;
  }
  if (typeof v === 'string') return v.replace(UUID_RE, (u) => (u.startsWith('0000') ? u : 'U')).replace(ISO_RE, 'T');
  return v;
}
const canon = (v) => JSON.stringify(v);
function compare(a, b, opts) {
  const ma = mask(a, opts);
  const mb = mask(b, opts);
  if (canon(ma) === canon(mb)) return 'equal';
  const ia = ma?.items;
  const ib = mb?.items;
  if (Array.isArray(ia) && Array.isArray(ib) && ia.length === ib.length && canon(ia.map(canon).sort()) === canon(ib.map(canon).sort())) return 'same-set';
  // первая разница
  const fa = canon(ma);
  const fb = canon(mb);
  let i = 0;
  while (i < fa.length && fa[i] === fb[i]) i++;
  return `differ @${i}: …${fa.slice(Math.max(0, i - 80), i + 80)} ≠ …${fb.slice(Math.max(0, i - 80), i + 80)}`;
}

/** Ответы каталога для сравнения: /catalog/products, /search/products?q=F4252, все страницы /catalog/sync/products и images. */
async function catalogResponses(d) {
  const out = {};
  out.products = (await d.call('GET', '/catalog/products?limit=40')).json;
  out.search = (await d.call('GET', '/search/products?q=F4252&limit=20')).json;
  const all = async (entity) => {
    const items = [];
    let since = null;
    for (let i = 0; i < 50; i++) {
      const r = await d.call('GET', `/catalog/sync/${entity}?limit=200${since ? `&since=${encodeURIComponent(since)}` : ''}`, { quiet: true });
      items.push(...(r.json?.items ?? []));
      since = r.json?.nextCursor ?? null;
      if (!since || !r.json?.hasMore) break;
    }
    return { items };
  };
  out.syncProducts = await all('products');
  out.syncImages = await all('images');
  out.categories = (await d.call('GET', '/catalog/categories')).json;
  return out;
}

const report = { at: new Date().toISOString(), phases: {} };
const backends = [];
try {
  const build = JSON.parse(readFileSync(`${SITE}/backend/build.json`, 'utf8'));
  const manifest = JSON.parse(readFileSync(`${SNAP}/manifest.json`, 'utf8'));
  const siteManifest = JSON.parse(readFileSync(`${SITE}/demo/snapshot/manifest.json`, 'utf8'));
  const imagesJson = JSON.parse(readFileSync(`${SNAP}/images.json`, 'utf8'));
  const buildReport = JSON.parse(readFileSync(`${SNAP}/report.json`, 'utf8'));
  report.build = { backendSha256: build.backend?.sha256, epochKey: build.epochKey, snapshot: build.snapshot };
  add('0 сборка: backend.js собран с этим снимком (sha данных в build.json = манифест сайта = .build)', build.snapshot?.dataSha256 === manifest.data.sha256 && siteManifest.data.sha256 === manifest.data.sha256, `build.json ${build.snapshot?.dataSha256?.slice(0, 16)}…, site ${siteManifest.data.sha256.slice(0, 16)}…, .build ${manifest.data.sha256.slice(0, 16)}…; эпоха ${build.epochKey}`);

  // ======================================================================== D. детерминизм
  if (!argv.includes('--skip-determinism')) {
    say('== D: две независимые сборки снимка');
    const { buildSnapshot } = await import(pathToFileURL(`${BACKEND}/snapshot/build-snapshot.mjs`).href);
    const runs = [];
    for (const n of [1, 2]) {
      const dir = `${ROOT}/.tmp/web_demo/b4/det-${n}`;
      rmSync(dir, { recursive: true, force: true });
      const t = Date.now();
      const r = await buildSnapshot({ outDir: dir, mediaDir: dir, site: false, quiet: true });
      const m = JSON.parse(readFileSync(`${dir}/manifest.json`, 'utf8'));
      runs.push({ dir, ms: Date.now() - t, problems: r.report.problems, manifest: m, data: sha256(readFileSync(`${dir}/data.copy`)), gz: sha256(readFileSync(`${dir}/${m.data.gzipFile}`)), images: sha256(readFileSync(`${dir}/images.json`)), builtAt: m.builtAt });
    }
    const strip = (m) => canon({ ...m, builtAt: undefined });
    const same12 = strip(runs[0].manifest) === strip(runs[1].manifest);
    const sameMain = strip(runs[0].manifest) === strip(manifest);
    const diffKeys = Object.keys(runs[0].manifest).filter((k) => canon(runs[0].manifest[k]) !== canon(runs[1].manifest[k]));
    report.phases.D = { runs: runs.map((r) => ({ ms: r.ms, problems: r.problems, data: r.data, gz: r.gz, images: r.images, builtAt: r.builtAt })), diffKeys };
    add(
      'D1 два прогона дают одинаковый manifest.json (кроме времени сборки), тот же data.copy, data.copy.gz и список фото',
      same12 && sameMain && runs[0].data === runs[1].data && runs[0].gz === runs[1].gz && runs[0].images === runs[1].images && runs.every((r) => !r.problems.length),
      `прогоны ${runs.map((r) => `${(r.ms / 1000).toFixed(1)} с`).join(', ')}; различаются ключи: ${JSON.stringify(diffKeys)}; = .build: ${sameMain}; data.copy ${runs[0].data.slice(0, 16)}… / ${runs[1].data.slice(0, 16)}…; gz ${runs[0].gz.slice(0, 12)}…/${runs[1].gz.slice(0, 12)}…; images.json ${runs[0].images.slice(0, 12)}…/${runs[1].images.slice(0, 12)}…`,
    );
    for (const r of runs) rmSync(r.dir, { recursive: true, force: true });
  }

  // ======================================================================== I. фото: файлы
  say('== I: фото на сайте');
  const imgProblems = [];
  const siteImages = `${SITE}/images`;
  const dirs = existsSync(siteImages) ? readdirSync(siteImages).filter((d) => statSync(`${siteImages}/${d}`).isDirectory()).sort() : [];
  const listed = imagesJson.files.map((f) => f.sha).sort();
  if (canon(dirs) !== canon(listed)) imgProblems.push(`каталоги site/images (${dirs.length}) ≠ images.json (${listed.length})`);
  let imgBytes = 0;
  for (const f of imagesJson.files) {
    for (const [size, meta] of Object.entries(f.sizes)) {
      const p = `${siteImages}/${f.sha}/${size}.webp`;
      if (!existsSync(p)) {
        imgProblems.push(`нет ${f.sha}/${size}.webp`);
        continue;
      }
      const b = readFileSync(p);
      imgBytes += b.length;
      if (b.length !== meta.bytes || sha256(b) !== meta.sha256) imgProblems.push(`${f.sha}/${size}.webp: ${b.length} Б ${sha256(b).slice(0, 8)} ≠ ${meta.bytes} Б ${meta.sha256.slice(0, 8)}`);
    }
  }
  report.phases.I = { dirs: dirs.length, files: imagesJson.files.length * 3, bytes: imgBytes, problems: imgProblems.slice(0, 10) };

  // ======================================================================== S2. холодный старт со снимком
  say('== S2: холодный старт со снимком');
  const bodiesS2 = [];
  const tS2 = Date.now();
  const s2 = await startWorkerBackend({ sku: manifest.source.catalog.skuCount, strict: true, initOpts: { seed: false, catchUp: false, buildId: 'b4-acceptance' }, onLog: (lv, m) => !QUIET && lv === 'error' && console.log('[worker error]', String(m).slice(0, 300)) });
  backends.push(s2);
  const sn = s2.ready.timings.snapshot;
  report.phases.S2 = { initMs: s2.initMs, wallMs: Date.now() - tS2, timings: s2.ready.timings };
  add(
    'S2.1 холодный старт восстанавливает снимок S2 (время восстановления; ready ≤ 10 с)',
    sn?.used === true && s2.initMs <= 10000,
    `ready ${s2.initMs} мс; снимок: ${(sn?.bytes / 1e6).toFixed(2)} МБ (gzip ${(sn?.gzBytes / 1e6).toFixed(2)} МБ), распаковка ${sn?.unzipMs} мс, sha ${sn?.verifyMs} мс, восстановление ${sn?.restoreMs} мс ${JSON.stringify(sn?.steps)}, ${sn?.rows} строк в ${sn?.tables} таблицах, сдвиг времени ${sn?.rebased} строк; миграции ${s2.ready.timings.migrateMs} мс`,
  );
  const ck2 = (await s2.rpc({ type: 'snapcheck' })).data;
  report.phases.S2.check = { counts: ck2.counts, times: ck2.times, audit: ck2.audit, images: ck2.images.length };
  // состав: таблицы снимка — ровно строки манифеста
  // Число строк сверяется внутри транзакции восстановления (restoreSnapshot → verify); после старта pos-worker
  // (sync_state расписаний и т. п.) — только для сведения.
  const countAfterStart = manifest.tables.filter((t) => ck2.counts[`${t.schema}.${t.name}`] !== t.rows).map((t) => `${t.schema}.${t.name} ${ck2.counts[`${t.schema}.${t.name}`]}≠${t.rows}`);
  add('S2.2 восстановление сверило число строк всех таблиц снимка с манифестом (в той же транзакции)', sn?.rows === manifest.tables.reduce((a, t) => a + t.rows, 0) && sn?.tables === manifest.tables.length, `${sn?.tables} таблиц, ${sn?.rows} строк = манифест; после старта pos-worker изменились: ${JSON.stringify(countAfterStart)}`);
  // время: всё «сейчас», ничего со сроком
  const nowMs = Date.parse(ck2.times.now.replace(' ', 'T').replace(/\+00$/, 'Z'));
  const near = (s) => s && Math.abs(Date.parse(String(s).replace(' ', 'T').replace(/([+-]\d\d)$/, '$1:00')) - nowMs) < 120_000;
  const t = ck2.times;
  const invDays = t.invitation_expires ? (Date.parse(String(t.invitation_expires).replace(' ', 'T').replace(/([+-]\d\d)$/, '$1:00')) - nowMs) / 86400e3 : null;
  add(
    'S2.3 в снимке нет данных со сроком: время сдвинуто на момент восстановления; приглашение создано воркером (+7 дней); OTP и сессий нет',
    near(t.products_created_min) && near(t.products_updated_max) && near(t.sync_success_min) && near(t.sync_success_max) && near(t.audit_min) && near(t.users_created_min) && t.invitations_pending === 1 && invDays > 6.9 && invDays < 7.1 && t.otp === 0 && t.sessions === 0 && !manifest.tables.some((x) => ['user_invitations', 'otp_challenges', 'sessions', 'devices', 'app_pins'].includes(x.name)),
    `now ${t.now}; products.created_at min ${t.products_created_min}; sync_state.last_success_at ${t.sync_success_min}…${t.sync_success_max}; audit ${t.audit_min}…${t.audit_max}; users ${t.users_created_min}; приглашение до ${t.invitation_expires} (+${invDays?.toFixed(2)} дн.); otp ${t.otp}, sessions ${t.sessions}; исключено из снимка: ${manifest.excluded.map((x) => x.table.replace('public.', '')).join(', ')}`,
  );
  add('S2.4 хэш-цепочка аудита после сдвига времени сходится (audit_verify_chain)', ck2.audit?.ok === true && sn?.audit?.ok === true, `${JSON.stringify(ck2.audit)}; при восстановлении ${JSON.stringify(sn?.audit)}`);
  const svc = ck2.staff.filter((s) => /^\+99677700098[167]$/.test(s.phone));
  add('S2.5 служебные учётки сида — «Демо-история …» (981, 986, 987)', svc.length === 3 && svc.every((s) => s.name.startsWith('Демо-история')), JSON.stringify(svc));

  // фото: строки product_images = файлы
  const dbShas = [...new Set(ck2.images.map((i) => i.sha))].sort();
  const sizeBad = [];
  for (const i of ck2.images) {
    const sizes = typeof i.sizes === 'string' ? JSON.parse(i.sizes) : i.sizes;
    for (const s of ['thumb', 'card', 'full']) {
      const p = `${siteImages}/${i.sha}/${s}.webp`;
      if (!existsSync(p) || statSync(p).size !== sizes?.[s]?.bytes) sizeBad.push(`${i.sha.slice(0, 8)}/${s}`);
    }
    if (i.status !== 'ready' || i.storage_key !== `images/${i.sha}`) sizeBad.push(`${i.sha.slice(0, 8)} ${i.status} ${i.storage_key}`);
  }

  // API: вход, каталог, фото по адресам ответа, клиенты, сценарии долга
  const admin = new Dev(s2, bodiesS2);
  await admin.login('+996777000901');
  await s2.control('POST sync/catch-up', {});
  const syncC = await syncRun(admin, 'customers');
  const syncR = await syncRun(admin, 'receivables');
  const cash = new Dev(s2, bodiesS2);
  await cash.login('+996777000906');
  const catS2 = await catalogResponses(cash);
  // адреса фото из ответов
  const urls = new Set();
  JSON.stringify(catS2).replace(/\/images\/([0-9a-f]{64})\/(thumb|card|full)/g, (m) => (urls.add(m), m));
  const missingUrl = [...urls].filter((u) => !existsSync(`${SITE}${u}.webp`));
  const withImg = new Set((catS2.syncImages.items ?? []).map((i) => i.productId)).size;
  add(
    'S2.6 sha фото в product_images совпадают с файлами site/images; адреса фото в ответах API ведут на существующие файлы',
    imgProblems.length === 0 && canon(dbShas) === canon(listed) && sizeBad.length === 0 && missingUrl.length === 0 && urls.size > 0,
    `site/images: ${dirs.length} каталогов, ${imagesJson.files.length * 3} файлов, ${(imgBytes / 1e6).toFixed(2)} МБ, sha256/байты = images.json: ${imgProblems.length === 0}; product_images ${ck2.images.length} строк, sha = каталоги: ${canon(dbShas) === canon(listed)}, размеры = файлы: ${sizeBad.length === 0}; в ответах ${urls.size} адресов /images/{sha}/{size}, нет файла: ${missingUrl.length}; товаров с фото в /catalog/sync/images: ${withImg} из ${catS2.syncProducts.items.length} в /catalog/sync/products`,
  );

  // сценарии клиентов
  const items = ((await cash.call('GET', '/catalog/products?limit=40&inStock=true')).json?.items ?? []).filter((p) => !p.hasVariants && p.price && p.defaultVariantId);
  const price = (p) => Number(p.price?.price?.amount ?? p.price?.amount);
  const pSmall = items.find((p) => price(p) < 900) ?? items[0];
  const pBig = items.find((p) => price(p) > 1100) ?? items[items.length - 1];
  const findCustomer = async (q) => (await cash.call('GET', `/search/customers?q=${encodeURIComponent(q)}&include=receivable&limit=5`)).json?.items?.[0];
  const cOver = await findCustomer('Просрочка');
  const cLimit = await findCustomer('Лимит превышен');
  const cOk = await findCustomer('0700000101');
  const oOver = cOver ? await sellCredit(cash, pSmall, 1, cOver.id) : null;
  const qtyBig = Math.max(1, Math.ceil(1100 / price(pBig)));
  const oLimit = cLimit ? await sellCredit(cash, pBig, qtyBig, cLimit.id) : null;
  const oOk = cOk ? await sellCredit(cash, pSmall, 1, cOk.id) : null;
  report.phases.S2.customers = { sync: { customers: syncC, receivables: syncR }, overdue: { name: cOver?.name ?? cOver?.displayName, status: oOver?.status, code: oOver?.json?.code }, overLimit: { name: cLimit?.name ?? cLimit?.displayName, product: pBig?.sku, qty: qtyBig, price: price(pBig), status: oLimit?.status, code: oLimit?.json?.code }, withinLimit: { name: cOk?.name ?? cOk?.displayName, status: oOk?.status } };
  add(
    'S2.7 сценарии клиентов не изменились: просрочка → CREDIT_BLOCKED, «Лимит превышен» → CREDIT_LIMIT_EXCEEDED, «Долг в лимите» → 201',
    oOver?.status === 422 && oOver?.json?.code === 'CREDIT_BLOCKED' && oLimit?.status === 422 && oLimit?.json?.code === 'CREDIT_LIMIT_EXCEEDED' && oOk?.status === 201,
    JSON.stringify(report.phases.S2.customers),
  );
  // ещё ответы с клиентами (для проверки ПДн)
  for (const q of ['Покупатель', 'ОсОО', 'ИП', 'Клиент', '0102', '0104', '1001', 'Асанов', 'Бакыт']) await cash.call('GET', `/search/customers?q=${encodeURIComponent(q)}&include=receivable&limit=50`, { quiet: true });
  if (cOk) {
    await cash.call('GET', `/customers/${cOk.id}`, { quiet: true });
    await cash.call('GET', `/customers/${cOk.id}/receivable`, { quiet: true });
  }
  for (const e of ['customers', 'customer_contacts', 'receivables']) await cash.call('GET', `/catalog/sync/${e}?limit=200`, { quiet: true });
  await cash.call('GET', '/orders?limit=50', { quiet: true });
  await admin.call('GET', '/admin/users?limit=100', { quiet: true });
  const ss = await until(async () => (await admin.call('GET', '/sync/status', { quiet: true })).json, (x) => x?.overall === 'ok', 60000, 1000);
  report.phases.S2.syncStatus = { overall: ss.v?.overall, stale: (ss.v?.entities ?? []).filter((e) => e.isStale).map((e) => e.entity) };
  add('S2.8 /sync/status overall=ok (снимок не «устаревает»: свежесть — от момента восстановления и догоняния)', ss.ok, JSON.stringify(report.phases.S2.syncStatus));

  // ПДн: ответы бэкенда, снимок, бандл, сайт
  const respText = bodiesS2.map((b) => b.text).join('\n');
  const respHits = scanText(respText, FORBIDDEN);
  const snapHits = scanText(readFileSync(`${SNAP}/data.copy`, 'utf8') + JSON.stringify(manifest), FORBIDDEN);
  const bundleHits = scanText(readFileSync(`${SITE}/backend/backend.js`, 'utf8'), FORBIDDEN);
  const siteHits = [];
  const walk = (dir) => {
    for (const f of readdirSync(dir)) {
      const p = `${dir}/${f}`;
      if (statSync(p).isDirectory()) walk(p);
      else if (['.js', '.mjs', '.json', '.html', '.css', '.txt', '.md'].includes(extname(f))) {
        const h = scanText(readFileSync(p, 'utf8'), FORBIDDEN);
        if (h.length) siteHits.push({ file: p.slice(SITE.length + 1), hits: h });
      }
    }
  };
  walk(SITE);
  const scenarioNames = bodiesS2.filter((b) => /Покупатель Долг в лимите \(тест\)|Покупатель Просрочка \(тест\)|ОсОО Лимит превышен \(тест\)/.test(b.text)).length;
  report.phases.S2.pii = { forbidden: FORBIDDEN.length, responses: bodiesS2.length, responseBytes: respText.length, respHits, snapHits, bundleHits, siteHits, scenarioNameResponses: scenarioNames };
  add(
    `S2.9 запрещённые строки ПДн (${FORBIDDEN.length}, полный список pii-map.json) — нет в снимке, backend.js, файлах сайта и ответах бэкенда`,
    !respHits.length && !snapHits.length && !bundleHits.length && !siteHits.length && bodiesS2.length > 20 && scenarioNames > 0,
    `ответов ${bodiesS2.length} (${(respText.length / 1e6).toFixed(2)} МБ текста; тестовые имена клиентов в ${scenarioNames}): ${JSON.stringify(respHits)}; снимок ${JSON.stringify(snapHits)}; backend.js ${JSON.stringify(bundleHits)}; сайт ${JSON.stringify(siteHits).slice(0, 200)}`,
  );
  const ph = buildReport.phones;
  add(
    'S2.10 телефоны тестовых клиентов проходят проверку номера pos-api/pos-app (мобильный КР, libphonenumber); вымышленного диапазона у КР нет',
    ph?.allValid === true && ph.nonMobileProbes.every((x) => !x.valid || x.type !== 'MOBILE'),
    `сценарные ${ph?.groups?.scenario?.map((x) => x.phone).join(', ')}; обычные ${ph?.groups?.regular?.[0]?.phone}…${ph?.groups?.regular?.at(-1)?.phone}; все MOBILE: ${ph?.allValid}; невыделенные префиксы ${JSON.stringify(ph?.nonMobileProbes)} → номер из них не пройдёт проверку, поэтому оставлен диапазон плана +996 700 000 1NN / 700 001 NNN (ограничение — known_issues)`,
  );

  // ======================================================================== S1. каталог данных PGlite
  if (!argv.includes('--skip-s1')) {
    const s1File = `${SNAP}/s1-datadir.tar.gz`;
    if (!existsSync(s1File)) throw new Error(`нет ${s1File}: node demo/web/backend/snapshot/build-snapshot.mjs --no-site --s1`);
    say('== S1: каталог данных PGlite (обычная сборка)');
    const bodiesS1 = [];
    const s1Bytes = new Uint8Array(readFileSync(s1File)).buffer;
    const s1 = await startWorkerBackend({ sku: manifest.source.catalog.skuCount, strict: true, snapshot: false, initOpts: { seed: false, catchUp: false, loadDataDir: s1Bytes, snapshotPreloaded: true, buildId: 'b4-s1' } });
    backends.push(s1);
    const ck1 = (await s1.rpc({ type: 'snapcheck' })).data;
    const keys = [...new Set([...Object.keys(ck1.counts), ...Object.keys(ck2.counts)])].sort();
    // Счёт до входа: в S2 ck2 снят до входа, в S1 — тоже.
    const cdiff = keys.filter((k) => ck1.counts[k] !== ck2.counts[k] && k !== 'public.demo_meta').map((k) => `${k} S1=${ck1.counts[k]} S2=${ck2.counts[k]}`);
    const a1 = new Dev(s1, bodiesS1);
    await a1.login('+996777000906');
    const catS1 = await catalogResponses(a1);
    const cmp = Object.fromEntries(Object.keys(catS2).map((k) => [k, compare(catS1[k], catS2[k])]));
    report.phases.S1 = { initMs: s1.initMs, timings: { pgliteCreateMs: s1.ready.timings.pgliteCreateMs, migrateMs: s1.ready.timings.migrateMs }, s1Bytes: s1Bytes.byteLength, countDiff: cdiff, compare: cmp, images: ck1.images.length };
    add(
      'S1.1 сравнение с S1 (dumpDataDir обычной сборки): число строк всех таблиц совпадает',
      cdiff.length === 0,
      `${keys.length} таблиц; расхождения: ${JSON.stringify(cdiff)}; S1 ${(s1Bytes.byteLength / 1e6).toFixed(2)} МБ gzip против S2 ${(sn.gzBytes / 1e6).toFixed(2)} МБ gzip`,
    );
    add(
      'S1.2 одинаковые ответы GET /catalog/products, /search/products?q=F4252, /catalog/sync/products и /catalog/sync/images (все страницы), /catalog/categories (id и время маскируются)',
      Object.values(cmp).every((v) => v === 'equal' || v === 'same-set') && (catS2.search?.items ?? []).length > 0,
      `${JSON.stringify(cmp).slice(0, 600)}; F4252 → ${(catS2.search?.items ?? []).length} товаров; /catalog/sync/products ${catS2.syncProducts.items.length}`,
    );
    report.phases.S1.piiHits = scanText(bodiesS1.map((b) => b.text).join('\n'), FORBIDDEN);
    await s1.close();
    backends.splice(backends.indexOf(s1), 1);
  }

  // ======================================================================== P. запасной путь без снимка
  if (!argv.includes('--skip-pipeline')) {
    say('== P: без снимка (каталог конвейером)');
    const p = await startWorkerBackend({ sku: manifest.source.catalog.skuCount, strict: true, snapshot: false, initOpts: { seed: false, catchUp: false, buildId: 'b4-pipeline' } });
    backends.push(p);
    const ckp = (await p.rpc({ type: 'snapcheck' })).data;
    const d = new Dev(p, []);
    await d.login('+996777000906');
    const catP = await catalogResponses(d);
    const cmpP = Object.fromEntries(Object.keys(catS2).filter((k) => k !== 'syncImages').map((k) => [k, compare(catP[k], catS2[k], { dropImages: true })]));
    // без снимка нет фото: product_images, их прогон sync_runs/sync_state и запись аудита импорта фото (audit_logs +1)
    const skipTables = new Set(['public.product_images', 'public.sync_runs', 'public.sync_state', 'public.demo_meta', 'public.sync_errors', 'public.audit_logs']);
    const pdiff = Object.keys(ck2.counts).filter((k) => !skipTables.has(k) && ckp.counts[k] !== ck2.counts[k]).map((k) => `${k} P=${ckp.counts[k]} S2=${ck2.counts[k]}`);
    report.phases.P = { initMs: p.initMs, snapshot: p.ready.timings.snapshot, catalogMs: p.ready.timings.catalogMs, countDiff: pdiff, compare: cmpP };
    add(
      'P1 запасной путь (каталог конвейером, как WP-B3) даёт те же данные: число строк и ответы каталога без полей фото совпадают со снимком',
      pdiff.length === 0 && Object.values(cmpP).every((v) => v === 'equal' || v === 'same-set'),
      `ready ${p.initMs} мс (каталог ${p.ready.timings.catalogMs} мс) против ${s2.initMs} мс со снимком; расхождения строк (кроме фото и журналов синхронизации): ${JSON.stringify(pdiff)}; ответы ${JSON.stringify(cmpP).slice(0, 400)}`,
    );
    await p.close();
    backends.splice(backends.indexOf(p), 1);
  }

  const stats = await s2.stats();
  add('0 ответов 5xx, 0 подсадок вне белого списка, 0 ожиданий замка дольше 3 с', all5xx.length === 0 && stats.pg.outsideWhitelist === 0 && stats.pg.waitsOver3s === 0, `5xx ${JSON.stringify(all5xx.slice(0, 5))}; подсадок вне списка ${stats.pg.outsideWhitelist}; ожиданий > 3 с ${stats.pg.waitsOver3s}, max ${stats.pg.maxWaitMs} мс`);
  report.size = buildReport.size;
} catch (e) {
  add('прогон без исключения', false, String(e?.stack ?? e).slice(0, 1500));
} finally {
  for (const b of backends) await b.close().catch(() => undefined);
}
report.acceptance = crit;
report.totalSec = Math.round((Date.now() - T0) / 1000);
const out = arg('--json', null);
if (out) {
  mkdirSync(dirname(resolve(out)), { recursive: true });
  writeFileSync(out, JSON.stringify(report, null, 1));
}
const failed = crit.filter((c) => !c.met).length;
console.log(`\n==== WP-B4: ${crit.length - failed}/${crit.length} за ${report.totalSec} с`);
process.exit(failed ? 1 : 0);
