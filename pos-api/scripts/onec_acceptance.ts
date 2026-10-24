/**
 * Приёмка API 1С (расширение «OptomstroyPOS», RM-E-016; 18 §7.2–§7.3; ядро §24.3): автоматизируемые шаги
 * контрольного примера против опубликованного HTTP-сервиса **тестовой копии** через тот же клиент, что pos-worker
 * (`OnecExtensionGateway`, `ONEC_MODE=extension`), и протокол в Markdown (запрос → ответ → результат, без секретов).
 *
 *   # сразу после получения API (тест-контур; секреты — только *_FILE, 16 §4.3):
 *   APP_ENV=staging ONEC_MODE=extension ONEC_BASE_URL=https://<1c-test> ONEC_HS_PATH=<публикация>/hs \
 *   ONEC_HS_USER_FILE=… ONEC_HS_PASSWORD_FILE=… ONEC_HS_TOKEN_FILE=… [ONEC_USER_FILE=… ONEC_PASSWORD_FILE=…] \
 *   npx tsx scripts/onec_acceptance.ts --steps kp1,kp2,kp5,kp18,kp19 --phone +996700123456 \
 *     --image-ref <Ref_Key файла> --allow-write --out ../docs/stages/E_onec_kp_protocol.md
 *   # репетиция сейчас — против локального мока на фикстурах contracts/onec/fixtures (не реальная интеграция):
 *   npx tsx scripts/onec_acceptance.ts --mock --steps kp1,kp2,kp5,kp18,kp19 --allow-write
 *
 * Шаги: `kp1` — `/health` с ключом и без (AC-ONEC-051, -032); `kp2` — `/changes/reregister` (запись в план обмена
 * тестовой копии — только с `--allow-write`), чтение `/changes` всеми страницами, два `GET` без подтверждения дают
 * один номер (AC-ONEC-035), `/changes/ack`, повтор ack — 200 (AC-ONEC-036), `registrationBacklog` после ack;
 * `kp5` — `/customers?phone=` в форматах `0XXXXXXXXX` и `+996XXXXXXXXX` → одна карточка (AC-ONEC-044); `kp18` —
 * `/images/{ref}` → 200 + ETag, повтор с `If-None-Match` → 304 (AC-ONEC-049); `kp19` — `/external-ids?since=`.
 * Остальные шаги 18 §7.2 требуют действий в 1С (изменить цену, согласовать заказ, пробная оплата QR, провести
 * реализацию) или записи документов — в протокол попадают как «вручную» с проверяемым ожиданием.
 * Полная загрузка RM-E-011 в режиме extension — `scripts/load_catalog_fixtures.ts` не подходит (это фикстуры):
 * используется pos-worker (`POST /sync/runs` full по сущностям) — см. docs/stages/E_onec_extension_acceptance.md.
 * Код выхода: 0 — все автоматические шаги PASS; 1 — есть FAIL; 2 — параметры/конфигурация.
 */
import { randomUUID } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';
import { loadAppConfig } from '../src/common/config/app-config.js';
import { onecAdapters } from '../src/integrations/onec/onec-adapters.js';
import { OnecError } from '../src/integrations/onec/onec-error.js';
import { OnecExtensionGateway } from '../src/integrations/onec/onec-extension.gateway.js';
import type { OnecChangeItem, OnecGateway } from '../src/integrations/onec/onec-gateway.js';
import { NodeOnecTransport } from '../src/integrations/onec/onec-http-transport.js';
import { type MockResponse, OnecMockServer } from '../test/onec/support/onec-mock-server.js';

type Verdict = 'PASS' | 'FAIL' | 'SKIP' | 'MANUAL';

interface StepRecord {
  readonly id: string;
  readonly title: string;
  readonly request: string;
  readonly response: string;
  readonly expected: string;
  readonly verdict: Verdict;
}

const ALL_STEPS = ['kp1', 'kp2', 'kp5', 'kp18', 'kp19'] as const;
type StepId = (typeof ALL_STEPS)[number];

/** Шаги 18 §7.2, требующие действий в 1С или записи документов (в протокол — как ручные). */
const MANUAL_STEPS: readonly [string, string, string][] = [
  [
    'КП-3',
    'изменить цену товара и удалить тестовую характеристику, затем /changes',
    'цена (УстановкаЦенНоменклатуры) и ObjectDeletion в следующем сообщении (AC-ONEC-034)',
  ],
  [
    'КП-4',
    'прочитать 1-ю страницу, изменить товар с неё, дочитать, ack',
    'изменённый товар — в следующем сообщении с новыми данными',
  ],
  [
    'КП-6',
    'POST /customers, повтор с тем же externalId, другой externalId с тем же телефоном',
    '201; 200 без второй карточки; 409 POS_E_DUPLICATE с кандидатами (AC-ONEC-045)',
  ],
  [
    'КП-7',
    'POST /check по корзине из 30 строк (одна — больше остатка), paymentMethod=credit',
    '200 ≤ 3 с; STOCK_INSUFFICIENT в строке; блок receivables (AC-ONEC-050)',
  ],
  [
    'КП-8',
    'POST /orders; повтор; 10 одновременных с новым externalId',
    '201 «Не согласован», без резерва, POS <uuid>; 200 тот же; один документ (AC-ONEC-037…040)',
  ],
  ['КП-9', 'заказ с автоматической скидкой 1С', 'recalculated=true и суммы 1С'],
  [
    'КП-10',
    'согласовать заказ в 1С, затем /orders/{uuid}/status и /changes',
    'статус «согласован» в обоих (AC-ONEC-041)',
  ],
  [
    'КП-11',
    'POST /payments/qr; повтор; пробная оплата; /payments/{externalId}/status; /changes',
    '201; 200 тот же reference; paid; элемент QrPaymentStatus (AC-ONEC-075…077)',
  ],
  [
    'КП-12',
    'POST /payments (kind=qr_bakai) для этого платежа',
    '200 «уже существует» или 201; ровно один документ поступления',
  ],
  [
    'КП-13',
    'второй QR, /qr/cancel, статус, повторная отмена',
    'cancelled; статус cancelled; повтор — 200 (AC-ONEC-078)',
  ],
  [
    'КП-14',
    'POST /payments наличными в счёт долга с allocations из двух документов; повтор',
    'ПКО с расшифровкой; повтор не создаёт второй ПКО (AC-ONEC-043)',
  ],
  ['КП-15', 'второй заказ, затем /orders/{uuid}/cancel', '200, заказ отменён в 1С'],
  [
    'КП-16',
    'провести реализацию по первому заказу, затем /cancel',
    '409 POS_E_STATE, документ не изменён (AC-ONEC-042)',
  ],
  [
    'КП-17',
    'POST /returns 1 шт.; затем больше отгруженного; согласовать заявку в 1С',
    '201 submitted; 409 POS_E_STATE; accepted (AC-ONEC-048, -067)',
  ],
  [
    'КП-20',
    'заблокировать заказ другим сеансом и /cancel; неверный JSON',
    '423/503 POS_E_LOCKED; 400 POS_E_BAD_REQUEST (AC-ONEC-055)',
  ],
];

const out = (s: string): boolean => process.stdout.write(`${s}\n`);

function errText(e: unknown): string {
  if (e instanceof OnecError) return `OnecError ${e.status} ${e.code}`;
  return e instanceof Error ? e.message : String(e);
}

/** Мок HS на фикстурах: ключ проверяется, страницы /changes по курсору, reregister, картинки с ETag. */
function mockOverrides(mock: OnecMockServer, clientKey: string): void {
  const err401 = OnecMockServer.fixture('error.401').body;
  mock.on('GET', /^\/pos\/v1\//, (req) =>
    req.headers['x-pos-client-key'] === clientKey ? undefined : { status: 401, body: err401 },
  );
  mock.on('POST', /^\/pos\/v1\//, (req) =>
    req.headers['x-pos-client-key'] === clientKey ? undefined : { status: 401, body: err401 },
  );
  mock.on('GET', /^\/pos\/v1\/changes$/, (req) =>
    req.headers['x-pos-client-key'] === clientKey && req.query.get('cursor')
      ? OnecMockServer.fixture('changes.documents.page2.200')
      : undefined,
  );
  mock.on('POST', /^\/pos\/v1\/changes\/reregister$/, (req) =>
    req.headers['x-pos-client-key'] === clientKey ? { status: 204 } : undefined,
  );
  const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3]);
  mock.on('GET', /^\/pos\/v1\/images\//, (req) => {
    if (req.headers['x-pos-client-key'] !== clientKey) return undefined;
    const r: MockResponse =
      req.headers['if-none-match'] === '"mock-etag"'
        ? { status: 304, headers: { ETag: '"mock-etag"' } }
        : { status: 200, raw: png, headers: { ETag: '"mock-etag"', 'Content-Type': 'image/png' } };
    return r;
  });
}

interface Ctx {
  readonly gw: OnecGateway;
  /** Тот же адрес и пользователь, но без верного X-POS-Client-Key (КП-1). */
  readonly gwNoKey: OnecGateway;
  readonly allowWrite: boolean;
  readonly phone: string;
  readonly imageRef: string | undefined;
  readonly since: string;
  /** Реальная тестовая копия: после ack очередь регистраций пуста (на моке — значение фикстуры). */
  readonly strictBacklog: boolean;
}

async function kp1(c: Ctx): Promise<StepRecord> {
  let response: string;
  let ok = false;
  try {
    const h = await c.gw.getHealth({ requestId: randomUUID() });
    const b = h.body;
    response = `200 apiVersion=${b.apiVersion} extensionVersion=${b.extensionVersion} platform=${b.platform} exchangeNode=${String(b['exchangeNode'] ?? '')} backlog=${b.registrationBacklog} lastAck=${b.lastAckMessageNumber}`;
    ok = h.status === 200 && !!b.apiVersion && !!b.extensionVersion && typeof b.registrationBacklog === 'number';
  } catch (e) {
    response = errText(e);
  }
  let denied = false;
  try {
    await c.gwNoKey.getHealth();
    response += '; без ключа: 200 (ОШИБКА — сведения выданы)';
  } catch (e) {
    denied = e instanceof OnecError && e.status === 401;
    response += `; без ключа: ${errText(e)}`;
  }
  return {
    id: 'КП-1',
    title: 'GET /health с верными пользователем и ключом; затем без ключа',
    request: 'GET /pos/v1/health (Basic pos_hs + X-POS-Client-Key); то же с неверным ключом',
    response,
    expected: '200 с версиями; без ключа — 401 без сведений (AC-ONEC-051, AC-ONEC-032)',
    verdict: ok && denied ? 'PASS' : 'FAIL',
  };
}

async function kp2(c: Ctx): Promise<StepRecord> {
  const notes: string[] = [];
  let ok = true;
  try {
    if (c.allowWrite) {
      await c.gw.reregisterChanges();
      notes.push('reregister: OK');
    } else notes.push('reregister: пропущен (нет --allow-write)');
    const h0 = await c.gw.getHealth();
    const since = h0.body.lastAckMessageNumber;
    const first = await c.gw.getChanges({ since, limit: 1000 });
    const again = await c.gw.getChanges({ since, limit: 1000 });
    const sameNumber = first.body.messageNumber === again.body.messageNumber;
    notes.push(`два GET без ack: номер ${first.body.messageNumber}/${again.body.messageNumber}`);
    ok &&= sameNumber;
    const types = new Map<string, number>();
    let pages = 0;
    let page = first.body;
    const seen: OnecChangeItem[] = [];
    for (;;) {
      pages += 1;
      for (const it of page.items) {
        seen.push(it);
        types.set(it.type, (types.get(it.type) ?? 0) + 1);
      }
      if (!page.hasMore || !page.cursor || pages > 10_000) break;
      page = (await c.gw.getChanges({ since, limit: 1000, cursor: page.cursor })).body;
      ok &&= page.messageNumber === first.body.messageNumber;
    }
    notes.push(
      `страниц ${pages}, элементов ${seen.length}: ${[...types].map(([t, n]) => `${t}=${n}`).join(', ') || '—'}`,
    );
    if (first.body.items.length > 0 || pages > 1) {
      const ack = await c.gw.ackChanges(first.body.messageNumber);
      const ack2 = await c.gw.ackChanges(first.body.messageNumber);
      notes.push(`ack ${ack.status}, повтор ack ${ack2.status}`);
      ok &&= ack.status === 200 && ack2.status === 200;
    } else notes.push('сообщение пустое — ack не нужен');
    const h1 = await c.gw.getHealth();
    notes.push(
      `registrationBacklog после ack: ${h1.body.registrationBacklog}${c.strictBacklog ? '' : ' (мок: значение фикстуры)'}`,
    );
    if (c.strictBacklog) ok &&= h1.body.registrationBacklog === 0;
  } catch (e) {
    ok = false;
    notes.push(errText(e));
  }
  return {
    id: 'КП-2',
    title: 'reregister → /changes всеми страницами → /changes/ack',
    request: 'POST /changes/reregister; GET /changes?since=N&limit=1000[&cursor]; POST /changes/ack ×2',
    response: notes.join('; '),
    expected:
      'все объекты состава пришли; два GET без ack — один номер; повтор ack — 200; backlog после ack = 0 (AC-ONEC-035, -036)',
    verdict: ok ? 'PASS' : 'FAIL',
  };
}

async function kp5(c: Ctx): Promise<StepRecord> {
  const local = `0${c.phone.replace(/^\+996/, '')}`;
  let response: string;
  let ok = false;
  try {
    const a = await c.gw.findCustomersByPhone(local);
    const b = await c.gw.findCustomersByPhone(c.phone);
    const refOf = (x: Record<string, unknown>): string => (typeof x['ref'] === 'string' ? x['ref'] : '');
    const ra = a.body.map(refOf).sort();
    const rb = b.body.map(refOf).sort();
    ok = ra.length > 0 && JSON.stringify(ra) === JSON.stringify(rb);
    response = `${local}: ${ra.length} карточ.; ${c.phone.slice(0, 7)}*****: ${rb.length} карточ.; совпадают: ${ok}`;
  } catch (e) {
    response = errText(e);
  }
  return {
    id: 'КП-5',
    title: 'GET /customers?phone=… в форматах 0700123456 и +996700123456',
    request: 'GET /pos/v1/customers?phone=<0XXXXXXXXX>; то же <+996XXXXXXXXX>',
    response,
    expected: 'одна и та же карточка (AC-ONEC-044)',
    verdict: ok ? 'PASS' : 'FAIL',
  };
}

async function kp18(c: Ctx): Promise<StepRecord> {
  if (!c.imageRef) {
    return {
      id: 'КП-18',
      title: 'GET /images/{ref}; повтор с If-None-Match',
      request: '—',
      response: 'нет --image-ref (Ref_Key присоединённого файла номенклатуры)',
      expected: '200 с ETag; 304 без тела (AC-ONEC-049)',
      verdict: 'SKIP',
    };
  }
  let response: string;
  let ok = false;
  try {
    const r = await c.gw.getImage(c.imageRef);
    const etag = r.body?.etag ?? null;
    const r2 = etag ? await c.gw.getImage(c.imageRef, etag) : undefined;
    ok = r.status === 200 && !!etag && r2?.status === 304 && r2.body === null;
    response = `${r.status} ${r.body?.contentType ?? ''} ${r.body?.data.byteLength ?? 0} байт ETag=${etag ? 'есть' : 'нет'}; повтор: ${r2?.status ?? '—'}`;
  } catch (e) {
    response = errText(e);
  }
  return {
    id: 'КП-18',
    title: 'GET /images/{ref}; повтор с If-None-Match',
    request: 'GET /pos/v1/images/{ref}; If-None-Match: <ETag>',
    response,
    expected: '200 с ETag; 304 без тела (AC-ONEC-049)',
    verdict: ok ? 'PASS' : 'FAIL',
  };
}

async function kp19(c: Ctx): Promise<StepRecord> {
  let response: string;
  let ok = false;
  try {
    const r = await c.gw.listExternalIds({ since: c.since, limit: 1000 });
    const items = (r.body['items'] as unknown[] | undefined) ?? [];
    ok = r.status === 200 && Array.isArray(r.body['items']);
    response = `${r.status} объектов ${items.length}`;
  } catch (e) {
    response = errText(e);
  }
  return {
    id: 'КП-19',
    title: 'GET /external-ids?since=<начало теста>',
    request: `GET /pos/v1/external-ids?since=${c.since}`,
    response,
    expected: 'все объекты КП-6…КП-17 с externalId (полнота — сверка с протоколом ручных шагов)',
    verdict: ok ? 'PASS' : 'FAIL',
  };
}

const RUNNERS: Record<StepId, (c: Ctx) => Promise<StepRecord>> = { kp1, kp2, kp5, kp18, kp19 };

function protocol(mode: string, records: readonly StepRecord[]): string {
  const lines = [
    `# Протокол контрольного примера 18 §7.2 (автоматическая часть) — ${new Date().toISOString()}`,
    '',
    `Режим: ${mode}. Секреты не выводятся; номера телефонов маскируются.`,
    '',
    '| Шаг | Действие | Запрос | Ответ | Ожидание | Итог |',
    '|---|---|---|---|---|---|',
    ...records.map(
      (r) =>
        `| ${r.id} | ${r.title} | ${r.request.replace(/\|/g, '\\|')} | ${r.response.replace(/\|/g, '\\|')} | ${r.expected} | ${r.verdict} |`,
    ),
    ...MANUAL_STEPS.map(([id, action, expected]) => `| ${id} | ${action} | — | — | ${expected} | MANUAL |`),
    '',
  ];
  return lines.join('\n');
}

export async function main(argv = process.argv.slice(2)): Promise<number> {
  let values;
  try {
    ({ values } = parseArgs({
      args: argv,
      options: {
        mock: { type: 'boolean', default: false },
        steps: { type: 'string' },
        phone: { type: 'string' },
        'image-ref': { type: 'string' },
        since: { type: 'string' },
        'allow-write': { type: 'boolean', default: false },
        out: { type: 'string' },
      },
      strict: true,
    }));
  } catch (e) {
    process.stderr.write(`${e instanceof Error ? e.message : String(e)}\n`);
    return 2;
  }
  const steps = (values.steps ?? ALL_STEPS.join(',')).split(',').map((s) => s.trim()) as StepId[];
  const unknown = steps.filter((s) => !(ALL_STEPS as readonly string[]).includes(s));
  if (unknown.length > 0) {
    process.stderr.write(`неизвестные шаги: ${unknown.join(', ')} (есть: ${ALL_STEPS.join(', ')})\n`);
    return 2;
  }
  let mock: OnecMockServer | undefined;
  let transport: NodeOnecTransport | undefined;
  let gw: OnecGateway;
  let gwNoKey: OnecGateway;
  let mode: string;
  if (values.mock) {
    const clientKey = 'test-only-client-key';
    mock = new OnecMockServer('/ut11/hs');
    mockOverrides(mock, clientKey);
    await mock.start();
    transport = new NodeOnecTransport({ allowInsecureHttp: true, connectTimeoutMs: 2_000 });
    const base = { baseUrl: mock.baseUrl, hsPath: 'ut11/hs', user: 'pos_hs', password: 'test-only-password' }; // check-secrets: allow — фиктивное значение теста/приёмки на мок-сервере
    gw = new OnecExtensionGateway({ ...base, clientKey, timeoutMs: 5_000 }, transport);
    gwNoKey = new OnecExtensionGateway({ ...base, clientKey: 'test-only-wrong-key', timeoutMs: 5_000 }, transport);
    mode = 'мок HS на фикстурах contracts/onec/fixtures — репетиция, НЕ реальная интеграция';
  } else {
    let config;
    try {
      config = loadAppConfig(process.env);
    } catch (e) {
      process.stderr.write(`Конфигурация: ${e instanceof Error ? e.message : String(e)}\n`);
      return 2;
    }
    if (config.ONEC_MODE !== 'extension' || config.APP_ENV === 'prod') {
      process.stderr.write('Отказ: нужен ONEC_MODE=extension на тест-контуре (APP_ENV=staging|dev), не prod\n');
      return 2;
    }
    const adapters = onecAdapters(config);
    gw = adapters.extension!();
    gwNoKey = onecAdapters({ ...config, ONEC_HS_TOKEN: `invalid-${randomUUID()}` }).extension!(); // check-secrets: allow — фиктивное значение теста/приёмки на мок-сервере
    mode = `ONEC_MODE=extension, ${config.ONEC_BASE_URL ?? ''}/${config.ONEC_HS_PATH ?? ''} (тестовая копия)`;
  }
  const ctx: Ctx = {
    gw,
    gwNoKey,
    allowWrite: values['allow-write'] === true,
    phone: values.phone ?? '+996700123456',
    imageRef: values['image-ref'] ?? (values.mock ? 'a1b2c3d4-0000-4000-8000-0000000000f1' : undefined),
    since: values.since ?? new Date(Date.now() - 24 * 3600_000).toISOString(),
    strictBacklog: !values.mock,
  };
  const records: StepRecord[] = [];
  try {
    for (const s of steps) {
      const r = await RUNNERS[s](ctx);
      records.push(r);
      out(`[onec-acceptance] ${r.verdict.padEnd(6)} ${r.id} — ${r.response}`);
    }
  } finally {
    transport?.close();
    await mock?.stop();
  }
  const text = protocol(mode, records);
  if (values.out) writeFileSync(values.out, text);
  const failed = records.filter((r) => r.verdict === 'FAIL').length;
  out(
    `[onec-acceptance] ИТОГ (${mode}): PASS ${records.filter((r) => r.verdict === 'PASS').length}, FAIL ${failed}, SKIP ${records.filter((r) => r.verdict === 'SKIP').length}, вручную ${MANUAL_STEPS.length}`,
  );
  return failed === 0 ? 0 : 1;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  main().then(
    (code) => process.exit(code),
    (e: unknown) => {
      process.stderr.write(`[onec-acceptance] ОШИБКА: ${e instanceof Error ? e.message : String(e)}\n`);
      process.exit(2);
    },
  );
}
