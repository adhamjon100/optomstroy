// Онлайн-адаптация (20.11.2026, ТЗ «ночной обмен» 2.3 отозвано) и закрытие пропусков охоты на дефекты, раунд 3
// (.tmp/onec-check/hunt-r3): каждый неверный ответ 1С — через фасад test/helpers/front-1c.mjs, отдельный процесс программы.
// Сценарии Z — неверные ответы (нужна ОШИБКА или ЗАМЕЧАНИЕ у названной проверки), Y10 — верный ответ, который не должен
// давать ОШИБКУ. Каждый тест на сборке до исправлений падал (журнал — .tmp/onec-check/online-adapt.md). Данные вымышленные.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import net from 'node:net';
import { mutateJson } from './helpers/front-1c.mjs';
import {
  frontWithSecrets, makeConfig, runMain, runInteractive, readProtocol, check, checkTexts, tmpDir, secretForms, leaks, limiter,
} from './helpers/env.mjs';

const dirs = [];
const closers = [];
after(async () => { for (const c of closers) await c(); for (const d of dirs) fs.rmSync(d, { recursive: true, force: true }); });
const limit = limiter(4);

const is = (c, m, re) => c.method === m && re.test(c.sub || '');
const CHANGES = /^\/pos\/v1\/changes$/;
const XID = /^\/pos\/v1\/external-ids$/;
const RECV = /^\/pos\/v1\/customers\/[^/]+\/receivables$/;
const IMG = /^\/pos\/v1\/images\/[^/]+$/;
const HEALTH = /^\/pos\/v1\/health$/;
const CUST = /^\/pos\/v1\/customers$/;
const PAY = /^\/pos\/v1\/payments$/;
const jsonOf = (r) => { try { return JSON.parse(r.body.toString('utf8')); } catch { return undefined; } };
const withH = (r, k, v) => ({ ...r, headers: { ...r.headers, [k]: v } });
const each = (j, type, fn) => { for (const it of (j && Array.isArray(j.items)) ? j.items : []) if (it && it.type === type) fn(it); };
const codes = (c) => c.findings.map((f) => `${f.severity} ${f.code}`);

function runWith(defect, { write = false } = {}) {
  return limit(async () => {
    const { front, password, clientKey } = await frontWithSecrets({ defect });
    closers.push(() => front.close());
    const dir = tmpDir(`oc-adapt-${defect.id}-`);
    dirs.push(dir);
    const cfg = makeConfig(dir, { baseUrl: front.baseUrl, password, clientKey });
    const r = await runMain(['--config', cfg, '--allow-http', '--no-manual', ...(write ? ['--allow-write'] : [])],
      { input: write ? `${front.publication}\n` : '', timeoutMs: 240000 });
    const p = readProtocol(path.join(dir, 'protokoly'));
    assert.ok(p, `нет протокола: ${r.out.slice(-1500)}`);
    assert.deepEqual(leaks([r.out, ...p.texts], secretForms(password, clientKey)), [], 'секрет в выводе');
    return { ...r, p, journal: front.journal };
  });
}

/** Проверка id — с вердиктом verdict и находкой с кодом code (и, если задан, фрагментом текста). */
function expectFinding(r, id, verdict, code, fragment = null) {
  const c = check(r.p, id);
  assert.ok(c, `нет проверки ${id}`);
  assert.equal(c.verdict, verdict, `${id}: ${c.verdict} — ${checkTexts(c)}`);
  const f = c.findings.find((x) => x.code === code);
  assert.ok(f, `${id}: нет находки ${code}; есть: ${codes(c).join(', ')}`);
  if (fragment) assert.match(f.text, fragment);
  return f;
}

test('Z01: один externalId дважды на странице /external-ids с разными ref — X1 ОШИБКА «один externalId — два объекта 1С»', async () => {
  const r = await runWith({
    id: 'Z01',
    after: (c, res) => (is(c, 'GET', XID) && res.status === 200 ? mutateJson(res, (j) => {
      if (j.items?.length) j.items.push({ ...j.items[0], ref: crypto.randomUUID(), number: 'ПКО0-990001' });
    }) : null),
  });
  expectFinding(r, 'X1', 'FAIL', 'dup-conflict', /один externalId — два объекта 1С: ref .* и .*Требования §4\.7/);
  assert.equal(r.code, 1);
});

test('Z02: один и тот же объект дважды на одной странице /changes — C2 ОШИБКА «дважды на странице»', async () => {
  const r = await runWith({
    id: 'Z02',
    after: (c, res) => (is(c, 'GET', CHANGES) && res.status === 200 && !c.query.get('cursor') ? mutateJson(res, (j) => {
      const it = (j.items || []).find((x) => x.type === 'Catalog_Номенклатура');
      if (it) j.items.push(structuredClone(it));
    }) : null),
  });
  expectFinding(r, 'C2', 'FAIL', 'dup-in-page', /дважды на странице 1 \(Catalog_Номенклатура:.*\) — одна запись выдана два раза: у объекта в сообщении одна регистрация/);
  assert.equal(r.code, 1);
});

test('Z03: повтор /changes до ack с тем же messageNumber, но без одного элемента — C1 ОШИБКА, не ЗАМЕЧАНИЕ', async () => {
  const r = await runWith({
    id: 'Z03',
    after: (c, res) => {
      if (!(is(c, 'GET', CHANGES) && res.status === 200 && !c.query.get('cursor'))) return null;
      c.state.reads = (c.state.reads || 0) + 1;
      if (c.state.reads < 2) return null;
      return mutateJson(res, (j) => { if (j.items?.length > 1) j.items.splice(1, 1); });
    },
  });
  const f = expectFinding(r, 'C1', 'FAIL', 'items-lost', /повтор до ack с тем же номером 5121 выдал не всё: 1 элемента первого чтения нет/);
  assert.match(f.text, /Повтор до ack выдаёт то же сообщение/);
  assert.ok(!/данные меняли во время проверки/.test(checkTexts(check(r.p, 'C1'))), 'причина — не «данные меняли»');
  assert.equal(r.code, 1);
});

test('Z05: WWW-Authenticate ответов 401 с версиями платформы и конфигурации — A7 ОШИБКА', async () => {
  const r = await runWith({
    id: 'Z05',
    after: (c, res) => (res.status === 401 ? withH(res, 'www-authenticate', 'Basic realm="1C:Enterprise 8.3.25.1374 UpravlenieTorgovlej 11.5.18.25"') : null),
  });
  expectFinding(r, 'A7', 'FAIL', 'leak-header-platform', /в заголовке www-authenticate ответа 401 номер версии платформы 1С/);
  assert.equal(r.code, 1);
});

test('Z05b: WWW-Authenticate ответов 401 с теми же версиями, что /health, — A7 ОШИБКА по каждому значению', async () => {
  const r = await runWith({
    id: 'Z05b',
    after: (c, res) => {
      if (res.status !== 401) return null;
      const h = c.inner.state.health;
      return withH(res, 'www-authenticate', `Basic realm="OptomstroyPOS ${h.extensionVersion}; release ${h.configurationVersion}"`);
    },
  });
  expectFinding(r, 'A7', 'FAIL', 'leak-header-extensionVersion', /в заголовке www-authenticate ответа 401 сведения о системе: extensionVersion/);
  expectFinding(r, 'A7', 'FAIL', 'leak-header-configurationVersion');
});

test('Z06: несуществующие даты (30 февраля, 31 ноября) по шаблону контракта — E5 ОШИБКА «такой даты нет в календаре»', async () => {
  const r = await runWith({
    id: 'Z06',
    after: (c, res) => {
      if (is(c, 'GET', RECV) && res.status === 200) return mutateJson(res, (j) => { if (j.documents?.[0]) j.documents[0].date = '2026-11-31T12:00:00+06:00'; });
      if (is(c, 'GET', HEALTH) && res.status === 200 && c.key) return mutateJson(res, (j) => { j.serverTime = '2026-02-30T10:00:00+06:00'; });
      return null;
    },
  });
  const e5 = check(r.p, 'E5');
  assert.equal(e5.verdict, 'FAIL', checkTexts(e5));
  assert.match(checkTexts(e5), /31\.11\.2026 — такой даты нет в календаре \(в этом месяце 30 дн\.\)/);
  assert.match(checkTexts(e5), /30\.02\.2026 — такой даты нет в календаре \(в этом месяце 28 дн\.\)/);
  assert.equal(r.code, 1);
});

test('Z19: путь к файлу на диске 1С в Content-Disposition картинки — I1 ОШИБКА; путь в протокол не попадает', async () => {
  const r = await runWith({
    id: 'Z19',
    after: (c, res) => (is(c, 'GET', IMG) && res.status === 200 ? withH(res, 'content-disposition', 'inline; filename="D:\\1C\\Toma\\Nomenklatura\\2026\\9f8e7d6c.jpg"') : null),
  });
  expectFinding(r, 'I1', 'FAIL', 'fs-path-header', /в заголовке content-disposition ответа 200 путь к файлу на диске 1С — путь в ответе запрещён \(контракт GET \/images\/\{ref\}\)/);
  assert.equal(r.code, 1);
});

test('Z20: путь к файлу на диске 1С в тексте ошибки 404 картинки — I3 ОШИБКА', async () => {
  const r = await runWith({
    id: 'Z20',
    after: (c, res) => (is(c, 'GET', IMG) && res.status === 404 ? mutateJson(res, (j) => { j.message = 'Файл D:\\1C\\Тома\\Номенклатура\\2026\\9f8e7d6c.jpg не найден на диске'; }) : null),
  });
  expectFinding(r, 'I3', 'FAIL', 'fs-path-message', /в тексте ошибки \(message\) путь к файлу на диске 1С/);
  assert.equal(r.code, 1);
});

test('Z46: ответ 304 с другим ETag, чем у файла, — I2 ОШИБКА', async () => {
  const r = await runWith({
    id: 'Z46',
    after: (c, res) => (is(c, 'GET', IMG) && res.status === 304 ? withH(res, 'etag', '"1732090000-4096"') : null),
  });
  expectFinding(r, 'I2', 'FAIL', 'etag-304', /304 с другим ETag/);
  assert.equal(r.code, 1);
});

test('Z52: /health показывает registrationBacklog > 0, а /changes отдаёт пустое сообщение — C2 ОШИБКА', async () => {
  const r = await runWith({
    id: 'Z52',
    after: (c, res) => (is(c, 'GET', CHANGES) && res.status === 200 ? mutateJson(res, (j) => { j.items = []; j.hasMore = false; j.cursor = null; }) : null),
  });
  expectFinding(r, 'C2', 'FAIL', 'backlog-not-output', /registrationBacklog = \d+, а сообщение 5121 пустое — регистрации узла есть, но \/changes их не выдаёт/);
  assert.equal(r.code, 1);
});

test('Z57: повтор создания клиента возвращает того же клиента с новым contractorRef — K2 ОШИБКА', async () => {
  const r = await runWith({
    id: 'Z57',
    after: (c, res) => (is(c, 'POST', CUST) && res.status === 200 ? mutateJson(res, (j) => { if (j.created === false) j.contractorRef = crypto.randomUUID(); }) : null),
  }, { write: true });
  expectFinding(r, 'K2', 'FAIL', 'contractor', /повтор вернул другого контрагента/);
  assert.equal(r.code, 1);
});

test('Z91: 10 одновременных созданий клиента — один ref, но у повторов другой код и контрагент — K3 ОШИБКА', async () => {
  const r = await runWith({
    id: 'Z91',
    before: (c) => { if (is(c, 'POST', CUST)) { const e = c.json().value?.externalId; if (e) c.state.seen.set(e, (c.state.seen.get(e) || 0) + 1); } return null; },
    after: (c, res) => {
      if (!(is(c, 'POST', CUST) && res.status === 200)) return null;
      const e = c.json().value?.externalId;
      if (!e || (c.state.seen.get(e) || 0) < 3) return null;
      return mutateJson(res, (j) => { j.code = 'ПР' + String(crypto.randomInt(100000, 999999)); j.contractorRef = crypto.randomUUID(); });
    },
  }, { write: true });
  expectFinding(r, 'K3', 'FAIL', 'same-code', /ref один, а code — \d+ разных значений/);
  expectFinding(r, 'K3', 'FAIL', 'same-contractorRef');
  assert.equal(r.code, 1);
});

test('Z92: 10 одновременных оплат — один документ, но в ответах повторов другие номера — PAY3 ОШИБКА', async () => {
  const r = await runWith({
    id: 'Z92',
    before: (c) => { if (is(c, 'POST', PAY)) { const e = c.json().value?.externalId; if (e) c.state.seen.set(e, (c.state.seen.get(e) || 0) + 1); } return null; },
    after: (c, res) => {
      if (!(is(c, 'POST', PAY) && res.status === 200)) return null;
      const e = c.json().value?.externalId;
      if (!e || (c.state.seen.get(e) || 0) < 3) return null;
      return mutateJson(res, (j) => { j.number = 'ПКО0-' + String(crypto.randomInt(100000, 999999)); });
    },
  }, { write: true });
  expectFinding(r, 'PAY3', 'FAIL', 'same-number', /ref один, а number — \d+ разных значений/);
  assert.equal(r.code, 1);
});

test('Z93: при failOnDuplicate=false вернулся существующий клиент (201, created=true, ref клиента K1) — K5 ОШИБКА', async () => {
  const r = await runWith({
    id: 'Z93',
    after: (c, res) => {
      if (!(is(c, 'POST', CUST) && res.status === 201)) return null;
      const b = c.json().value;
      if (!c.state.first) { c.state.first = jsonOf(res); return null; }
      if (b?.dedupe?.failOnDuplicate === false && c.state.first?.ref) {
        return mutateJson(res, (j) => { j.ref = c.state.first.ref; j.contractorRef = c.state.first.contractorRef; j.code = c.state.first.code; });
      }
      return null;
    },
  }, { write: true });
  expectFinding(r, 'K5', 'FAIL', 'existing', /при failOnDuplicate=false вернулся существующий клиент из K1/);
  assert.equal(r.code, 1);
});

test('Z75: оплата наличными оформлена документом безналичного поступления — PAY1 ОШИБКА', async () => {
  const r = await runWith({
    id: 'Z75',
    after: (c, res) => (is(c, 'POST', PAY) && (res.status === 201 || res.status === 200)
      ? mutateJson(res, (j) => { if (j.documentType) j.documentType = 'Document_ПоступлениеБезналичныхДенежныхСредств'; }) : null),
  }, { write: true });
  expectFinding(r, 'PAY1', 'FAIL', 'doc-kind', /оплата наличными \(kind=cash\) оформлена документом Document_ПоступлениеБезналичныхДенежныхСредств — для наличных нужен приходный кассовый ордер/);
  assert.equal(r.code, 1);
});

test('Z60: текст ошибки по-кыргызски — E8 ЗАМЕЧАНИЕ (язык в контракте и Требованиях не задан), не ОШИБКА', async () => {
  const r = await runWith({
    id: 'Z60',
    after: (c, res) => {
      if (is(c, 'GET', RECV) && res.status === 404) return mutateJson(res, (j) => { j.message = 'Кардар табылган жок. Шилтеме туура эмес же өчүрүлгөн.'; });
      if (is(c, 'GET', IMG) && res.status === 404) return mutateJson(res, (j) => { j.message = 'Файл табылган жок. Сүрөт өчүрүлгөн.'; });
      return null;
    },
  });
  expectFinding(r, 'E8', 'WARN', 'not-ru-ky', /похож на кыргызский \(буквы ң, ө, ү\).*язык в Требованиях не задан, поэтому замечание/);
  assert.equal(r.code, 0, r.out.slice(-1500));
});

test('Y10: повтор оплаты отдаёт текущее состояние posted=true — PAY2 ЗАМЕЧАНИЕ, не ОШИБКА; код 0', async () => {
  const r = await runWith({
    id: 'Y10',
    after: (c, res) => (is(c, 'POST', PAY) && res.status === 200 ? mutateJson(res, (j) => { j.posted = true; }) : null),
  }, { write: true });
  expectFinding(r, 'PAY2', 'WARN', 'posted-changed', /если документ провёл бухгалтер между запросами — это верно/);
  assert.equal(r.code, 0, r.out.slice(-1500));
});

test('Z16: наименование товара обрезано посреди эмодзи (одиночный суррогат) — E3 ЗАМЕЧАНИЕ', async () => {
  const r = await runWith({
    id: 'Z16',
    after: (c, res) => (is(c, 'GET', CHANGES) && res.status === 200
      ? mutateJson(res, (j) => each(j, 'Catalog_Номенклатура', (it) => { if (it.description) it.description = it.description.slice(0, 12) + '\ud83d'; })) : null),
  });
  expectFinding(r, 'E3', 'WARN', 'lone-surrogate', /строка с половиной символа \(одиночный суррогат\)/);
});

test('Z49: ссылка товара — пустой GUID 00000000-… — E4 ОШИБКА', async () => {
  const r = await runWith({
    id: 'Z49',
    after: (c, res) => (is(c, 'GET', CHANGES) && res.status === 200
      ? mutateJson(res, (j) => { const it = (j.items || []).find((x) => x.type === 'Catalog_Номенклатура' && !x.isFolder); if (it) it.ref = '00000000-0000-0000-0000-000000000000'; }) : null),
  });
  expectFinding(r, 'E4', 'FAIL', 'guid-nil', /пустая ссылка 00000000-0000-0000-0000-000000000000 вместо ссылки объекта/);
  assert.equal(r.code, 1);
});

test('Z04: /health отдаёт JSON, закодированный дважды, — A1 ОШИБКА «закодирован дважды», не «без JSON»; код 2', async () => {
  const r = await runWith({
    id: 'Z04',
    after: (c, res) => (is(c, 'GET', HEALTH) && res.status === 200 ? { ...res, body: Buffer.from(JSON.stringify(res.body.toString('utf8')), 'utf8') } : null),
  });
  const f = expectFinding(r, 'A1', 'FAIL', 'double-json', /JSON закодирован дважды/);
  assert.ok(!/без JSON/.test(f.text));
  assert.equal(r.code, 2);
});

// ---------------------------------------------------------------- шаги-действия: «н» — не «сделано»

async function manualRun(checks, answers) {
  const { front, password, clientKey } = await frontWithSecrets();
  closers.push(() => front.close());
  const dir = tmpDir(`oc-adapt-wait-${checks}-`);
  dirs.push(dir);
  const cfg = makeConfig(dir, { baseUrl: front.baseUrl, password, clientKey });
  const r = await runInteractive(['--config', cfg, '--allow-http', '--checks', checks], answers, { timeoutMs: 90000 });
  return { ...r, p: readProtocol(path.join(dir, 'protokoly')) };
}

test('waitEnter: «н», «нет», «n» на «Измените в 1С товар» — шаг не сделан: переспрос, затем ПРОПУЩЕНО, не ложная ОШИБКА C11', async () => {
  const r = await manualRun('C11', [[/нажмите Enter/, 'н'], [/нажмите Enter/, 'нет'], [/нажмите Enter/, 'n']]);
  assert.ok(r.p, r.out.slice(-1500));
  assert.match(r.out, /Шаг не выполнен\? Сделайте его в 1С и нажмите Enter/);
  const c11 = check(r.p, 'C11');
  assert.equal(c11.verdict, 'SKIP', checkTexts(c11));
  assert.match(c11.summary, /товар не изменён \(три ответа «нет»\)/);
  // Выбрана одна C11, и она пропущена: «ничего не проверено», код 2 (не 1 — ошибки 1С нет).
  assert.equal(r.code, 2, r.out.slice(-1500));
});

test('waitEnter: «н» трижды на «Включите константу ОбменПриостановлен» — M1 ПРОПУЩЕНО, не ОШИБКА «нужен 503»', async () => {
  const r = await manualRun('M1', [[/нажмите Enter/, 'н'], [/нажмите Enter/, 'y'], [/нажмите Enter/, 'нет']]);
  assert.ok(r.p, r.out.slice(-1500));
  const m1 = check(r.p, 'M1');
  assert.equal(m1.verdict, 'SKIP', checkTexts(m1));
  assert.match(m1.summary, /константа не включена \(три ответа «нет»\)/);
});

// ---------------------------------------------------------------- связь: отказ в соединении — не «сертификат»; NODE_EXTRA_CA_CERTS

test('HTTPS, порт закрыт: S2 «сертификат не проверен» (ПРОПУЩЕНО), причина — S3 «отказал в соединении»; NODE_EXTRA_CA_CERTS — в протоколе', async () => {
  const port = await new Promise((ok) => { const s = net.createServer(); s.listen(0, '127.0.0.1', () => { const p = s.address().port; s.close(() => ok(p)); }); });
  const dir = tmpDir('oc-adapt-refused-');
  dirs.push(dir);
  const cfg = makeConfig(dir, { baseUrl: `https://127.0.0.1:${port}/ut_test/hs`, password: 'Vymysel-Parol-Otkaz-1', clientKey: 'vymysel-klyuch-otkaz-1' }); // check-secrets: allow — вымышленное тестовое значение, не секрет
  const r = await runMain(['--config', cfg, '--no-manual'], { env: { NODE_EXTRA_CA_CERTS: path.join(dir, 'net-takogo-fajla.pem') } });
  assert.equal(r.code, 2, r.out.slice(-1500));
  const p = readProtocol(path.join(dir, 'protokoly'));
  const s2 = check(p, 'S2');
  assert.equal(s2.verdict, 'SKIP', checkTexts(s2));
  assert.match(s2.summary, /сертификат не проверен: соединение с публикацией не установлено \(ECONNREFUSED\) — причина в S3/);
  const s3 = check(p, 'S3');
  assert.equal(s3.verdict, 'FAIL', checkTexts(s3));
  assert.match(checkTexts(s3), /отказал в соединении \(ECONNREFUSED\) — по этому адресу и порту ничего не слушает/);
  assert.ok(p.json.banners.some((b) => /NODE_EXTRA_CA_CERTS/.test(b)), `баннер: ${p.json.banners.join(' | ')}`);
  assert.match(r.out, /ИСПОЛЬЗОВАНЫ КОРНЕВЫЕ СЕРТИФИКАТЫ ИЗ NODE_EXTRA_CA_CERTS/);
});

// Строки вне ожидаемых проверок: в хороших ответах фасада (без дефекта) новые правила не дают ОШИБОК.
test('хорошая 1С с записью: новые правила (календарь, дубли на странице, контрагент, вид документа, ETag 304, пути) — без ОШИБОК', async () => {
  const r = await runWith({ id: 'GOOD' }, { write: true });
  // S1 — ЗАМЕЧАНИЕ «HTTP без шифрования» (фасад по http://, --allow-http) — ожидаемо.
  const bad = r.p.json.checks.filter((c) => c.id !== 'S1' && (c.verdict === 'FAIL' || c.verdict === 'WARN')).map((c) => `${c.id} ${c.verdict}: ${checkTexts(c)}`);
  assert.deepEqual(bad, []);
  assert.equal(r.code, 0);
  const json = JSON.stringify(r.p.json);
  assert.ok(!/ТЗ 2\.3|1\.3\.0/.test(json));
});
