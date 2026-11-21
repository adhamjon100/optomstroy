// C — план обмена: /changes, /changes/ack, /changes/reregister.
import { readPages } from '../paging.mjs';
import { expectStatus, expectPosError, netFailed, statusText } from './common.mjs';
import { sleep } from '../util.mjs';

const CH = 'GET /pos/v1/changes';
const ACK = 'POST /pos/v1/changes/ack';
const REREG = 'POST /pos/v1/changes/reregister';
const HEALTH = 'GET /pos/v1/health';

function lightItem(it) {
  if (!it || typeof it !== 'object') return null;
  const o = { type: it.type, ref: it.ref };
  for (const k of ['dataVersion', 'deletionMark', 'isFolder', 'ownerRef', 'externalId', 'size', 'extension', 'currency',
    'partnerRef', 'creditAllowed', 'imageFileRef', 'objectType', 'code', 'description', 'status', 'reference']) {
    if (it[k] !== undefined) o[k] = it[k];
  }
  if (Array.isArray(it.phones)) o.phones = it.phones.map((p) => p && p.phone).filter((p) => typeof p === 'string');
  if (it.type !== 'Catalog_Номенклатура') delete o.description;
  return o;
}

/**
 * Ключ объекта без ref — по чему тот же объект узнаётся во втором чтении: тип + код (+ владелец), штрихкод, номер и
 * дата документа, externalId QR, наименование + версия данных; для картинки — владелец и версия данных.
 * ObjectDeletion и элементы без таких реквизитов не сопоставляются.
 */
export function naturalKey(it) {
  if (!it || typeof it !== 'object' || typeof it.type !== 'string' || it.type === 'ObjectDeletion') return null;
  const s = (v) => (typeof v === 'string' && v.trim() ? v.trim() : (typeof v === 'number' ? String(v) : null));
  const t = it.type;
  const owner = s(it.ownerRef) ? ` владелец ${it.ownerRef.toLowerCase()}` : '';
  if (s(it.code)) return { key: `${t}|код ${s(it.code)}${owner}`, label: `${t} код ${s(it.code)}` };
  if (s(it.barcode)) return { key: `${t}|штрихкод ${s(it.barcode)}`, label: `${t} штрихкод ${s(it.barcode)}` };
  if (s(it.number) && s(it.date)) return { key: `${t}|№ ${s(it.number)} ${s(it.date)}`, label: `${t} № ${s(it.number)}` };
  if (s(it.externalId)) return { key: `${t}|externalId ${s(it.externalId).toLowerCase()}`, label: `${t} externalId ${s(it.externalId).toLowerCase()}` };
  if (s(it.description) && s(it.dataVersion)) return { key: `${t}|${s(it.description)}|${s(it.dataVersion)}${owner}`, label: t };
  if (s(it.dataVersion) && owner) return { key: `${t}|${s(it.dataVersion)}${owner}`, label: t };
  return null;
}

/** Объекты, которые в двух чтениях одного сообщения пришли с разными ref (ключи, встречающиеся дважды в одном чтении, — не в счёт). */
export function unstableRefs(items1, items2) {
  const index = (arr) => {
    const m = new Map();
    const dup = new Set();
    for (const it of arr) {
      const k = naturalKey(it);
      if (!k) continue;
      if (m.has(k.key)) dup.add(k.key); else m.set(k.key, { it, label: k.label });
    }
    for (const k of dup) m.delete(k);
    return m;
  };
  const m1 = index(items1), m2 = index(items2);
  const out = [];
  let paired = 0;
  for (const [k, a] of m1) {
    const b = m2.get(k);
    if (!b) continue;
    paired++;
    const r1 = String(a.it.ref ?? '').toLowerCase(), r2 = String(b.it.ref ?? '').toLowerCase();
    if (r1 !== r2) out.push({ key1: `${a.it.type}:${r1}`, label: a.label });
  }
  out.paired = paired;
  return out;
}

const BARCODES = 'InformationRegister_ШтрихкодыНоменклатуры';
const GUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * C3: ключ набора штрихкодов. Контракт BarcodeChange: «с ключом набора — значением штрихкода … Пустой набор (штрихкод
 * удалён) передаётся как ObjectDeletion с ref = штрихкод»; ref — «Ключ набора — значение штрихкода». POS хранит набор
 * по ref: при ref = GUID удаление (ref = штрихкод) не найдёт запись, и удалённый штрихкод останется в POS.
 */
export function barcodeKey(run, it, where) {
  if (!it || typeof it !== 'object') return;
  if (it.type === BARCODES && typeof it.ref === 'string' && typeof it.barcode === 'string' && it.ref !== it.barcode) {
    run.fail(`ref набора штрихкодов — значение штрихкода, не GUID: ref «${it.ref.slice(0, 40)}», barcode «${it.barcode.slice(0, 40)}» (контракт BarcodeChange: «Ключ набора — значение штрихкода»; иначе ObjectDeletion с ref = штрихкод не удалит штрихкод в POS)`, { code: 'barcode-ref', where });
  } else if (it.type === 'ObjectDeletion' && it.objectType === BARCODES && typeof it.ref === 'string' && GUID_RE.test(it.ref)) {
    run.warn(`удаление набора штрихкодов с ref-GUID «${it.ref}» — по контракту ref = значение штрихкода (ключ набора); проверьте, что это штрихкод`, { code: 'barcode-deletion-guid', where });
  }
}

/** Полное чтение сообщения since → все страницы; находки разбора — в pagingRun, схемы — в C3. */
export async function readMessage(ctx, run, since, { label = 'чтение сообщения', pagingRun = run } = {}) {
  const limit = ctx.settings.limits.pageLimit;
  const items = [];
  const counts = {};
  let first = null;
  let emptyShapeBad = false;
  const res = await readPages({
    maxPages: ctx.settings.limits.maxPages,
    limit, hardMax: 5000, sameMessage: true,
    keyOf: (it) => (it && it.type && it.ref !== undefined ? `${it.type}:${it.ref}` : null),
    labels: { item: 'элемент', dupInPage: 'у объекта в сообщении одна регистрация (контракт GET /changes: страницы — из таблиц регистрации узла), POS применит его дважды' },
    onItem: (it, pageNo, i) => {
      const l = lightItem(it);
      if (l) { items.push(l); counts[l.type] = (counts[l.type] || 0) + 1; }
      barcodeKey(ctx.runObj('C3'), it, `items[${i}].ref`);
    },
    report: (f) => pagingRun.add(f.severity, f.text, { code: f.code, where: f.where }),
    fetchPage: async (cursor, pageNo) => {
      const ex = await run.call({
        op: CH, path: '/pos/v1/changes', query: { since, limit, ...(cursor ? { cursor } : {}) },
        schemaRun: ctx.runObj('C3'), label: `${label}, страница ${pageNo}`,
      });
      if (pageNo === 1) first = ex;
      if (netFailed(pagingRun, ex, `страница ${pageNo}`)) return { ex, body: null };
      if (ex.status !== 200) {
        pagingRun.fail(`страница ${pageNo}: нужен 200, пришёл ${statusText(ex)}`, { code: 'status' });
        return { ex, body: null };
      }
      const b = ex.json;
      if (b && Array.isArray(b.items) && b.items.length === 0 && pageNo === 1 && (b.hasMore !== false || b.cursor !== null)) {
        emptyShapeBad = true;
        pagingRun.fail('пустое сообщение должно быть ровно items=[], hasMore=false, cursor=null', { code: 'empty-shape' });
      }
      return { ex, body: b };
    },
  });
  return { ...res, items, counts, first, emptyShapeBad, empty: res.items === 0 };
}

/** Ссылки для проверок: настройки refs, иначе элементы /changes (§1.2). */
export function discoverRefs(ctx, items) {
  const s = ctx.settings.refs || {};
  const refs = { ...(ctx.data.refs || {}) };
  const pick = (k, fn) => { if (s[k]) refs[k] = s[k]; else if (!refs[k]) { const it = items.find(fn); if (it) refs[k] = it.ref; } };
  pick('productRef', (i) => i.type === 'Catalog_Номенклатура' && !i.isFolder && !i.deletionMark);
  pick('warehouseRef', (i) => i.type === 'Catalog_Склады' && !i.deletionMark && !i.isFolder);
  pick('priceListRef', (i) => i.type === 'Catalog_ВидыЦен' && !i.deletionMark && (i.currency === 'KGS' || i.currency == null));
  // клиент с соглашением creditAllowed=true, иначе любой партнёр
  if (s.customerRef) refs.customerRef = s.customerRef;
  else if (!refs.customerRef) {
    const credit = items.find((i) => i.type === 'Catalog_СоглашенияСКлиентами' && i.creditAllowed === true && i.partnerRef && !i.deletionMark);
    const partner = credit ? items.find((i) => i.type === 'Catalog_Партнеры' && i.ref === credit.partnerRef && !i.deletionMark) : null;
    const anyP = items.find((i) => i.type === 'Catalog_Партнеры' && !i.deletionMark);
    if (partner || anyP) refs.customerRef = (partner || anyP).ref;
  }
  const exts = ctx.contract.imageExtensions();
  const max = ctx.contract.imageMaxBytes();
  if (s.imageRef) refs.imageRef = s.imageRef;
  else if (!refs.imageRef) {
    const img = items.find((i) => i.type === 'Catalog_НоменклатураПрисоединенныеФайлы' && !i.deletionMark
      && typeof i.extension === 'string' && exts.includes(i.extension.toLowerCase()) && Number.isInteger(i.size) && i.size <= max);
    if (img) { refs.imageRef = img.ref; refs.imageSize = img.size; }
    else {
      const prod = items.find((i) => i.type === 'Catalog_Номенклатура' && i.imageFileRef);
      if (prod) refs.imageRef = prod.imageFileRef;
    }
  }
  if (refs.imageRef && refs.imageSize === undefined) {
    const img = items.find((i) => i.ref === refs.imageRef && Number.isInteger(i.size));
    if (img) refs.imageSize = img.size;
  }
  if (ctx.settings.phone) refs.phone = ctx.settings.phone;
  else if (!refs.phone) {
    const p = items.find((i) => i.type === 'Catalog_Партнеры' && i.phones && i.phones.length);
    if (p) refs.phone = p.phones[0];
  }
  ctx.data.refs = refs;
  return refs;
}

function countsForHuman(items) {
  const c = {
    товары: 0, группы: 0, характеристики: 0, упаковки: 0, штрихкоды: 0, картинки: 0, склады: 0, 'виды цен': 0,
    партнёры: 0, контрагенты: 0, соглашения: 0, удаления: 0,
  };
  for (const i of items) {
    switch (i.type) {
      case 'Catalog_Номенклатура': if (i.isFolder) c.группы++; else if (!i.deletionMark) c.товары++; break;
      case 'Catalog_ХарактеристикиНоменклатуры': c.характеристики++; break;
      case 'Catalog_УпаковкиЕдиницыИзмерения': c.упаковки++; break;
      case 'InformationRegister_ШтрихкодыНоменклатуры': c.штрихкоды++; break;
      case 'Catalog_НоменклатураПрисоединенныеФайлы': c.картинки++; break;
      case 'Catalog_Склады': c.склады++; break;
      case 'Catalog_ВидыЦен': c['виды цен']++; break;
      case 'Catalog_Партнеры': c.партнёры++; break;
      case 'Catalog_Контрагенты': c.контрагенты++; break;
      case 'Catalog_СоглашенияСКлиентами': c.соглашения++; break;
      case 'ObjectDeletion': c.удаления++; break;
      default: break;
    }
  }
  return c;
}

export async function runChangesRead(ctx) {
  const lastAck = ctx.data.health?.lastAckMessageNumber;
  ctx.data.lastAck = lastAck;
  const limit = ctx.settings.limits.pageLimit;
  if (!Number.isInteger(lastAck)) {
    for (const id of ['C1', 'C2', 'C3', 'C4', 'C5']) await ctx.skip(id, 'lastAckMessageNumber из /health не число — номер сообщения неизвестен');
    return;
  }
  await ctx.run('C1', async (r) => {
    const a = await r.call({ op: CH, path: '/pos/v1/changes', query: { since: lastAck, limit }, noSchema: true, label: 'первое чтение без ack' });
    const b = await r.call({ op: CH, path: '/pos/v1/changes', query: { since: lastAck, limit }, noSchema: true, label: 'повтор без ack' });
    if (!expectStatus(r, a, 200, 'первое чтение') || !expectStatus(r, b, 200, 'повтор')) return;
    const n1 = a.json?.messageNumber, n2 = b.json?.messageNumber;
    if (n1 !== lastAck + 1) r.fail(`номер сообщения ${n1}, нужен lastAckMessageNumber + 1 = ${lastAck + 1}`, { code: 'number' });
    if (n2 !== n1) r.fail(`номер сообщения изменился без подтверждения: ${n1} → ${n2} (повтор до ack должен выдавать то же сообщение)`, { code: 'changed' });
    const items1 = Array.isArray(a.json?.items) ? a.json.items : [];
    const items2 = Array.isArray(b.json?.items) ? b.json.items : [];
    const keys = (arr) => new Set(arr.map((i) => `${i?.type}:${String(i?.ref ?? '').toLowerCase()}`));
    const k1 = keys(items1), k2 = keys(items2);
    // Один и тот же объект (тип + код, штрихкод, номер и дата документа…) в двух чтениях одного сообщения — с той же
    // ссылкой: POS сопоставляет объекты только по ref (Требования §4.3: ref — УникальныйИдентификатор() ссылки),
    // повтор до ack — то же сообщение (контракт GET /changes, ONEC-035).
    const moved = unstableRefs(items1, items2);
    const movedKeys = new Set(moved.map((x) => x.key1));
    if (moved.length) {
      const ex = moved[0];
      r.fail(`ссылка объекта меняется от чтения к чтению: ${moved.length} из ${moved.paired} объектов первой страницы пришли с другим ref (например, ${ex.label}) — нужен Ссылка.УникальныйИдентификатор() (Требования §4.3: POS сопоставляет объекты только по ref)`, { code: 'unstable-ref' });
    }
    // Объект, удалённый между чтениями, приходит во втором как ObjectDeletion с тем же ref — это не потеря.
    const deletedRefs = new Set(items2.filter((i) => i?.type === 'ObjectDeletion').map((i) => String(i?.ref ?? '').toLowerCase()));
    let missing = [...k1].filter((k) => !k2.has(k) && !movedKeys.has(k) && !deletedRefs.has(k.slice(k.indexOf(':') + 1)));
    if (missing.length && n1 === n2 && b.json?.hasMore === true && typeof b.json.cursor === 'string' && b.json.cursor) {
      // Сообщение больше страницы: новая регистрация между чтениями сдвигает границу страниц. Пропавшие элементы
      // ищутся на следующих страницах повтора (тот же messageNumber), а не считаются потерянными сразу.
      const rest = new Set(missing);
      let cursor = b.json.cursor;
      const seen = new Set([cursor]);
      for (let page = 2; rest.size && cursor && page <= ctx.settings.limits.maxPages; page++) {
        const ex = await r.call({ op: CH, path: '/pos/v1/changes', query: { since: lastAck, limit, cursor }, noSchema: true, label: `повтор без ack, страница ${page} (поиск элементов первого чтения)` });
        if (ex.error || ex.status !== 200 || !Array.isArray(ex.json?.items)) break;
        for (const i of ex.json.items) rest.delete(`${i?.type}:${String(i?.ref ?? '').toLowerCase()}`);
        const next = ex.json.hasMore === true ? ex.json.cursor : null;
        if (!next || seen.has(next)) break;
        seen.add(next);
        cursor = next;
      }
      missing = [...rest];
    }
    if (missing.length && n1 === n2) {
      r.fail(`повтор до ack с тем же номером ${n1} выдал не всё: ${missing.length} ${missing.length === 1 ? 'элемента' : 'элементов'} первого чтения нет (например, ${missing[0]}) — до подтверждения сообщение выдаётся заново целиком (контракт GET /changes: «Повтор до ack выдаёт то же сообщение»; Требования §8.4: два GET без подтверждения дают один номер и все элементы)`, { code: 'items-lost' });
    }
    r.evidence = { messageNumber: n1, firstPageItems: k1.size, unstableRefs: moved.length };
    r.pass(`сообщение ${n1} выдано дважды`);
  });
  let full = null;
  await ctx.run('C2', async (r) => {
    const t0 = Date.now();
    full = await readMessage(ctx, r, lastAck, { label: 'полное чтение' });
    ctx.data.message = { number: full.messageNumber, items: full.items, counts: full.counts, complete: full.complete };
    ctx.data.fullRead = { pages: full.pages, items: full.items.length, ms: Date.now() - t0, pageMs: full.pageMs, reregistered: false };
    discoverRefs(ctx, full.items);
    r.evidence = { messageNumber: full.messageNumber, pages: full.pages, items: full.items.length, stoppedBy: full.stoppedBy };
    if (full.messageNumber !== null && full.messageNumber !== lastAck + 1) r.fail(`номер сообщения ${full.messageNumber}, нужен ${lastAck + 1}`, { code: 'number' });
    // /health показывает регистрации, а сообщение пустое: регистрации есть, но /changes их не выдаёт. Перед находкой —
    // ещё раз /health и /changes (регистрацию могли подтвердить или снять между запросами).
    const backlog0 = ctx.data.health?.registrationBacklog;
    if (full.empty && full.complete && Number.isInteger(backlog0) && backlog0 > 0) {
      const hx = await r.call({ op: 'GET /pos/v1/health', path: '/pos/v1/health', label: 'registrationBacklog при пустом сообщении' });
      const h2 = hx.status === 200 && hx.json && typeof hx.json === 'object' ? hx.json : null;
      if (h2 && Number.isInteger(h2.registrationBacklog) && h2.registrationBacklog > 0 && h2.lastAckMessageNumber === lastAck) {
        const again = await r.call({ op: CH, path: '/pos/v1/changes', query: { since: lastAck, limit: ctx.settings.limits.pageLimit }, noSchema: true, label: 'повтор при пустом сообщении' });
        if (again.status === 200 && Array.isArray(again.json?.items) && again.json.items.length === 0) {
          r.fail(`/health: registrationBacklog = ${h2.registrationBacklog}, а сообщение ${full.messageNumber ?? lastAck + 1} пустое — регистрации узла есть, но /changes их не выдаёт (контракт GET /changes: «ВыбратьИзменения нумерует все непронумерованные регистрации узла»; КП-2: после подтверждения registrationBacklog = 0)`, { code: 'backlog-not-output' });
        }
      }
    }
    if (full.empty) r.pass(`сообщение ${full.messageNumber ?? lastAck + 1} пустое (регистраций нет)`);
    else r.pass(`сообщение ${full.messageNumber}: страниц ${full.pages}, элементов ${full.items.length}`);
  });
  await ctx.run('C3', async (r) => {
    if (!full || !full.items.length) {
      if (r.findings.length) { r.pass('элементов нет'); return; }
      r.skip(full ? 'в сообщении нет элементов — запустите с --allow-write и перерегистрацией (C6), чтобы проверить все типы' : 'нет данных C2');
      return;
    }
    r.evidence = { byType: full.counts, human: countsForHuman(full.items) };
    const types = Object.entries(full.counts).map(([t, n]) => `${t}: ${n}`).join(', ');
    r.note(`элементов по типам: ${types}`);
    r.pass(`проверено элементов: ${full.items.length}, типов: ${Object.keys(full.counts).length}`);
  });
  await ctx.run('C4', async (r) => {
    const ex = await r.call({ op: CH, path: '/pos/v1/changes', query: { since: lastAck, limit: 10000 }, noSchema: true, label: 'limit=10000' });
    if (!expectStatus(r, ex, 200, 'limit=10000')) return;
    const n = Array.isArray(ex.json?.items) ? ex.json.items.length : null;
    if (n === null) { r.fail('в ответе нет списка items'); return; }
    if (n > 5000) r.fail(`больше 5000 элементов на странице: ${n} (limit больше 5000 расширение должно ограничивать до 5000)`, { code: 'over' });
    r.pass(`элементов на странице: ${n}`);
  });
  await ctx.run('C5', async (r) => {
    const bad = [lastAck + 5];
    if (lastAck > 0) bad.push(lastAck - 1);
    for (const since of bad) {
      const ex = await r.call({ op: CH, path: '/pos/v1/changes', query: { since, limit: 1 }, dataError: true, noRetry: true, label: `since=${since} (lastAck=${lastAck})` });
      if (ex.status === 200) { r.fail(`since=${since} не равен lastAckMessageNumber (${lastAck}), а ответ 200 — нужен 400 POS_E_BAD_REQUEST`, { code: 'accepted' }); continue; }
      expectPosError(r, ex, 400, 'POS_E_BAD_REQUEST', `since=${since}`);
    }
    r.pass('400 POS_E_BAD_REQUEST');
  });
}

async function health(ctx, r, label) {
  const ex = await r.call({ op: HEALTH, path: '/pos/v1/health', label });
  return ex.status === 200 && ex.json ? ex.json : null;
}

/** Запись: C6 (вопрос) → полное чтение → C7–C10. */
export async function runChangesWrite(ctx) {
  await ctx.run('C6', async (r) => {
    let yes = !!ctx.demo;
    if (!ctx.demo) {
      const a = await ctx.askYesNo(r, 'Выполнить перерегистрацию (полную выгрузку всех объектов плана обмена «POS»)? Она нагрузит 1С на несколько минут', { def: 'n', allowSkip: false });
      yes = a === 'y';
    }
    if (!yes) { r.skip('перерегистрация не выбрана (ответ «нет» по умолчанию)'); return; }
    const before = await health(ctx, r, 'до перерегистрации');
    const ex = await r.call({ op: REREG, path: '/pos/v1/changes/reregister', noBodyExpected: true, label: 'перерегистрация' });
    if (netFailed(r, ex, 'перерегистрация')) return;
    if (ex.status === 200 || ex.status === 204) r.warn(`ответ ${ex.status} — по контракту 202 Accepted`, { code: 'not-202' });
    else if (ex.status !== 202) { r.fail(`перерегистрация: нужен 202, пришёл ${statusText(ex)}`, { code: 'status' }); return; }
    if (ex.size > 0 && ex.status === 202) r.info('202 с телом — тело не требуется', { code: 'body' });
    ctx.registry.addPlan({ action: 'reregister', checkId: 'C6', note: 'все объекты состава плана обмена зарегистрированы для узла «POS»' });
    let prev = before?.registrationBacklog ?? 0;
    const seq = [prev];
    const pollMs = ctx.pollMs;
    const deadline = Date.now() + 10 * 60 * 1000 * ctx.flags.timeoutScale;
    let stable = 0;
    while (Date.now() < deadline) {
      await sleep(pollMs);
      const h = await health(ctx, r, 'ожидание регистрации');
      const b = h?.registrationBacklog;
      if (!Number.isInteger(b)) break;
      seq.push(b);
      if (b > prev) { stable = 0; prev = b; } else if (++stable >= 2) break;
    }
    r.evidence = { backlog: seq };
    if (prev === 0) r.warn(`после перерегистрации registrationBacklog = 0 — регистрации не появились (${seq.join(' → ')})`, { code: 'no-growth' });
    else if (prev <= (before?.registrationBacklog ?? 0)) r.info(`registrationBacklog не вырос (${seq.join(' → ')}): все объекты уже были зарегистрированы`, { code: 'same' });
    ctx.data.reregistered = true;
    r.pass(`202; регистраций: ${seq.join(' → ')}`);
  });

  const lastAck0 = ctx.data.lastAck;
  let msg = null;
  await ctx.run('C7', async (r) => {
    if (!Number.isInteger(lastAck0)) { r.skip('номер последнего ack неизвестен'); return; }
    const h0 = await health(ctx, r, 'текущий lastAckMessageNumber');
    const lastAck = h0?.lastAckMessageNumber ?? lastAck0;
    const t0 = Date.now();
    msg = await readMessage(ctx, r, lastAck, { label: ctx.data.reregistered ? 'полное чтение после перерегистрации' : 'полное чтение перед ack', pagingRun: ctx.runObj('C2') });
    if (ctx.data.reregistered) {
      ctx.data.fullRead = { pages: msg.pages, items: msg.items.length, ms: Date.now() - t0, pageMs: msg.pageMs, reregistered: true };
      ctx.data.message = { number: msg.messageNumber, items: msg.items, counts: msg.counts, complete: msg.complete };
      discoverRefs(ctx, msg.items);
      const c3 = ctx.get('C3');
      if (c3) c3.evidence = { byType: msg.counts, human: countsForHuman(msg.items), afterReregister: true };
    }
    if (!msg.complete) {
      // Предел программы (limits.maxPages) — не ошибка 1С: сообщение просто больше, чем программа читает за раз.
      if (msg.stoppedBy === 'maxPages') {
        r.skip(`сообщение больше предела программы (limits.maxPages ${ctx.settings.limits.maxPages} × limits.pageLimit ${ctx.settings.limits.pageLimit}) — ack не отправлен; увеличьте limits.maxPages в nastrojki.json`);
        return;
      }
      r.fail('сообщение не дочитано до конца из-за ответа 1С (подробно — C2) — ack не отправляется', { code: 'incomplete' });
      return;
    }
    if (msg.empty) {
      r.skip('сообщение пустое — POS пустые сообщения не подтверждает; чтобы проверить ack, запустите с перерегистрацией (C6)');
      ctx.data.ackSkipped = true;
      return;
    }
    const N1 = msg.messageNumber;
    const ex = await r.call({ op: ACK, path: '/pos/v1/changes/ack', body: { messageNumber: N1 }, label: `ack ${N1}` });
    if (!expectStatus(r, ex, 200, `ack ${N1}`)) return;
    ctx.registry.addPlan({ action: 'ack', messageNumber: N1, checkId: 'C7', note: `снята регистрация ${msg.items.length} элементов` });
    if (ex.json?.messageNumber !== N1) r.fail(`ChangesAckResponse.messageNumber = ${ex.json?.messageNumber}, нужно ${N1}`, { code: 'ack-number' });
    const h = await health(ctx, r, 'после ack');
    if (h && h.lastAckMessageNumber !== N1) r.fail(`/health.lastAckMessageNumber = ${h.lastAckMessageNumber} после ack ${N1}`, { code: 'health-after' });
    ctx.data.lastAck = N1;
    ctx.data.ackedMessage = msg;
    r.pass(`ack ${N1}: 200${ex.json?.removedRegistrations !== undefined ? `, снято регистраций ${ex.json.removedRegistrations}` : ''}`);
  });
  const acked = ctx.get('C7');
  const ackOk = acked && acked.verdict !== 'FAIL' && acked.verdict !== 'SKIP' && ctx.data.ackedMessage;
  const reason = ctx.data.ackSkipped ? 'ack не отправлялся: сообщение пустое' : 'нет успешного ack (C7)';
  if (!ackOk) {
    for (const id of ['C8', 'C9', 'C10']) await ctx.skip(id, reason);
    return;
  }
  const N1 = ctx.data.lastAck;
  await ctx.run('C8', async (r) => {
    const ex = await r.call({ op: ACK, path: '/pos/v1/changes/ack', body: { messageNumber: N1 }, label: `повтор ack ${N1}` });
    if (ex.status === 409) { r.fail(`повтор подтверждения должен давать 200 без действий, пришёл ${statusText(ex)}`, { code: 'repeat-409' }); return; }
    expectStatus(r, ex, 200, `повтор ack ${N1}`);
    r.pass('200');
  });
  await ctx.run('C9', async (r) => {
    const big = N1 + 1000;
    const ex = await r.call({ op: ACK, path: '/pos/v1/changes/ack', body: { messageNumber: big }, label: `ack невыданного ${big}` });
    if (ex.status >= 200 && ex.status < 300) {
      r.fail(`ack номера ${big} (не выдавался) → ${ex.status}: нужен 409 POS_E_ACK_OUT_OF_ORDER`, { code: 'accepted' });
      ctx.registry.addPlan({ action: 'ack', messageNumber: big, checkId: 'C9', note: 'ack невыданного номера принят — 1С могла снять все регистрации узла «POS»' });
      return;
    }
    expectPosError(r, ex, 409, 'POS_E_ACK_OUT_OF_ORDER', `ack ${big}`);
    r.pass('409 POS_E_ACK_OUT_OF_ORDER');
  });
  await ctx.run('C10', async (r) => {
    const ex = await r.call({ op: CH, path: '/pos/v1/changes', query: { since: N1, limit: ctx.settings.limits.pageLimit }, label: 'после ack' });
    if (!expectStatus(r, ex, 200, 'чтение после ack')) return;
    const b = ex.json || {};
    if (b.messageNumber !== N1 + 1) r.fail(`номер следующего сообщения ${b.messageNumber}, нужен ${N1 + 1}`, { code: 'number' });
    if (Array.isArray(b.items) && b.items.length) {
      const again = b.items.filter((i) => ctx.data.ackedMessage.items.some((x) => x.type === i.type && x.ref === i.ref && x.dataVersion === i.dataVersion));
      if (again.length > b.items.length / 2 && again.length >= 3) r.fail(`регистрации не сняты: после ack снова ${b.items.length} элементов, из них ${again.length} те же`, { code: 'not-removed' });
      else r.warn(`после ack пришло ${b.items.length} новых элементов — возможно, данные меняли во время проверки`, { code: 'new-items' });
    } else if (Array.isArray(b.items) && (b.hasMore !== false || b.cursor !== null)) {
      r.fail('пустое сообщение должно быть ровно items=[], hasMore=false, cursor=null', { code: 'empty-shape' });
    }
    const h = await health(ctx, r, 'registrationBacklog после ack');
    if (h && h.registrationBacklog !== 0) {
      if (b.items && b.items.length === 0) r.warn(`registrationBacklog = ${h.registrationBacklog} при пустом сообщении — регистрации не сняты?`, { code: 'backlog' });
      else r.warn(`registrationBacklog = ${h.registrationBacklog} (не 0)`, { code: 'backlog' });
    }
    r.pass('после ack сообщение пустое');
  });
}

const lc = (v) => (typeof v === 'string' ? v.toLowerCase() : v);
const showV = (v) => (v === undefined ? 'нет поля' : v === null ? 'null' : typeof v === 'string' ? `«${v}»` : String(v));
const normSt = (s) => (typeof s === 'string' ? s.toLowerCase().replace(/ё/g, 'е').replace(/[\s_]+/g, '') : null);

/**
 * C14: объекты, созданные программой, приходят в следующем сообщении /changes с нашим externalId; затем ack.
 * Клиент K1 — Catalog_Партнеры (Требования §5.6). Заказ O1 — Document_ЗаказКлиента с externalId и ref заказа (§5.1
 * «в том числе заказов, созданных из POS»; §6.2 правило 8; §6.6 «Созданный документ регистрируется в плане обмена «POS»
 * как обычно. Элемент /changes для него содержит тот же externalId»; элемент с externalId = null POS пропускает, §5.1).
 * QR Q1 — QrPaymentStatus с externalId, текущим статусом (после отмены Q4 — cancelled) и reference выданного QR
 * (§6.14 п. 9, §7.10 «Каждое изменение записи … выдаётся в ближайшем сообщении /changes элементом QrPaymentStatus»).
 */
export async function runC14(ctx) {
  await ctx.run('C14', async (r) => {
    const cust = ctx.data.k1?.ref ? ctx.data.k1 : null;
    const o1 = ctx.data.o1?.ref ? ctx.data.o1 : null;
    const q1 = ctx.data.q1?.externalId ? ctx.data.q1 : null;
    if (!cust && !o1 && !q1) { r.skip('нет объектов, созданных программой (клиент K1, заказ O1, QR Q1)'); return; }
    const h = await health(ctx, r, 'текущий lastAck');
    const since = h?.lastAckMessageNumber ?? ctx.data.lastAck;
    const msg = await readMessage(ctx, r, since, { label: 'объекты из POS' });
    const N = msg.messageNumber ?? since + 1;
    const arrived = [];
    const missing = [];
    const notFound = (what, text, code) => {
      // Сообщение не дочитано: объекта может не быть в прочитанной части — это не доказывает ошибку 1С.
      if (!msg.complete) missing.push(what);
      else r.fail(text, { code });
    };

    if (cust) {
      const found = msg.items.find((i) => i.type === 'Catalog_Партнеры' && i.ref === cust.ref);
      if (!found) notFound('клиента из K1', `клиент из K1 (ref ${cust.ref}) не пришёл в сообщении ${N} как Catalog_Партнеры`, 'not-found');
      else {
        arrived.push('клиент');
        if (found.externalId !== cust.externalId) r.fail(`у клиента в /changes externalId = ${found.externalId ?? 'null'}, нужен наш ${cust.externalId}`, { code: 'external-id' });
      }
    }

    if (o1) {
      const ext = o1.body.externalId;
      const byRef = msg.items.find((i) => i.type === 'Document_ЗаказКлиента' && lc(i.ref) === lc(o1.ref));
      const byExt = byRef || msg.items.find((i) => i.type === 'Document_ЗаказКлиента' && lc(i.externalId) === lc(ext));
      if (!byExt) {
        notFound('заказа из O1', `заказ из O1 (ref ${o1.ref}, externalId ${ext}) не пришёл в сообщении ${N} элементом Document_ЗаказКлиента — созданный документ регистрируется в плане обмена «POS» как обычно (Требования §6.6 «Регистрация изменений», §5.1: «Документ.ЗаказКлиента … в том числе заказов, созданных из POS»)`, 'order-not-found');
      } else {
        arrived.push('заказ');
        if (byExt.externalId !== ext) {
          r.fail(`у заказа из O1 в /changes externalId = ${byExt.externalId ?? 'null'}, нужен наш ${ext} — для заказов, созданных через API, элемент содержит externalId из регистра POS_ВнешниеИдентификаторыPOS (Требования §6.2 правило 8, §6.6); элемент с externalId = null POS пропускает (§5.1), и статус заказа в POS из /changes не обновится`, { code: 'order-external-id' });
        }
        if (lc(byExt.ref) !== lc(o1.ref)) r.fail(`элемент Document_ЗаказКлиента с нашим externalId пришёл с ref ${byExt.ref}, а заказ создан с ref ${o1.ref} (ответ O1)`, { code: 'order-ref' });
        const cs = o1.cancelState;
        if (cs && (normSt(byExt.status) !== normSt(cs.status) || byExt.deletionMark !== cs.deletionMark)) {
          r.warn(`заказ из O1 в /changes: status ${showV(byExt.status)}, deletionMark = ${showV(byExt.deletionMark)}, а после отмены (O6) — status ${showV(cs.status)}, deletionMark = ${showV(cs.deletionMark)}; объект выгружается в текущем состоянии (Требования §6.2 правило 5)`, { code: 'order-state' });
        }
      }
    }

    if (q1) {
      const ext = q1.externalId;
      const found = msg.items.find((i) => i.type === 'QrPaymentStatus' && (lc(i.externalId) === lc(ext) || lc(i.ref) === lc(ext)));
      if (!found) {
        notFound('QR из Q1', `QR из Q1 (externalId ${ext}) не пришёл в сообщении ${N} элементом QrPaymentStatus — регистр POS_ОплатыQR входит в план обмена «POS», каждое изменение записи (создание, отмена…) выдаётся в ближайшем сообщении (Требования §6.14 п. 9, §7.10, §5.1, §8.4 «событие QR в /changes»); если включить регистр в план обмена на вашей платформе нельзя — сообщите (вопрос 70 раздела 10)`, 'qr-not-found');
      } else {
        arrived.push('QR');
        if (found.externalId !== ext) r.fail(`у QR из Q1 в /changes externalId = ${found.externalId ?? 'null'}, нужен наш ${ext} — externalId платежа POS (Требования §5.7 «QrPaymentStatus»)`, { code: 'qr-external-id' });
        if (lc(found.ref) !== lc(ext)) r.fail(`у QR из Q1 в /changes ref = ${found.ref ?? 'null'} — ключ записи, externalId платежа ${ext} (Требования §5.7)`, { code: 'qr-ref' });
        if (q1.cancelled && found.status !== 'cancelled') r.fail(`у QR из Q1 в /changes status ${showV(found.status)}, а QR отменён (Q4) — нужен cancelled: элемент несёт текущее состояние записи (Требования §7.10, §6.2 правило 5)`, { code: 'qr-status' });
        if (found.reference !== q1.reference) r.fail(`у QR из Q1 в /changes reference ${showV(found.reference)}, а QR выдан с reference ${showV(q1.reference)} (Требования §5.7: «выданный при создании QR»)`, { code: 'qr-reference' });
      }
    }

    if (msg.complete && !msg.empty && ctx.writeAllowed) {
      const ex = await r.call({ op: ACK, path: '/pos/v1/changes/ack', body: { messageNumber: msg.messageNumber }, label: `ack ${msg.messageNumber}` });
      if (ex.status === 200) {
        ctx.registry.addPlan({ action: 'ack', messageNumber: msg.messageNumber, checkId: 'C14' });
        ctx.data.lastAck = msg.messageNumber;
      } else r.warn(`ack ${msg.messageNumber} после C14: ${statusText(ex)}`, { code: 'ack' });
    }
    if (missing.length) {
      if (msg.stoppedBy === 'maxPages') r.skip(`сообщение больше предела программы (limits.maxPages) — в прочитанной части нет ${missing.join(', ')}; увеличьте limits.maxPages`);
      else r.warn(`сообщение не дочитано из-за ответа 1С (см. находки выше) — в прочитанной части нет ${missing.join(', ')}`, { code: 'incomplete' });
      return;
    }
    r.pass(`в сообщении ${msg.messageNumber} с нашим externalId: ${arrived.join(', ')}`);
  });
}

export { countsForHuman, lightItem };
