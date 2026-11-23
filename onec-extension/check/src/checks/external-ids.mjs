// X — сверка GET /pos/v1/external-ids (Требования §6.20; метод желательный: «метода нет» — МЕТОДА НЕТ, не ошибка).
import { readPages } from '../paging.mjs';
import { isoBishkek, parseIso } from '../report/time.mjs';
import { isPlatformAbsent } from '../rules.mjs';
import { netFailed, statusText } from './common.mjs';

const XID_ABSENT = 'МЕТОДА НЕТ — /external-ids желателен к запуску (нужен для ручной привязки заказа по номеру) и делается после основных методов (Требования §6.20, §8.2); КП-19 — если метод реализован';

const XID = 'GET /pos/v1/external-ids';

async function readXid(ctx, r, query, { label, maxPages = ctx.settings.limits.externalIdsMaxPages, report = true } = {}) {
  const records = [];
  let absent = false;
  const limit = Math.min(1000, Number(query.limit) || 1000);
  const res = await readPages({
    maxPages, limit, hardMax: 1000,
    // Ключ — externalId и тип (регистр POS_ВнешниеИдентификаторыPOS ищется «с учётом ТипОбъекта», Требования §4.7).
    keyOf: (it) => (it?.externalId ? `${it.externalId}${it.objectType ? ' / ' + it.objectType : ''}` : null),
    // Один externalId — один объект 1С (Требования §4.7 п. 1–2): та же запись с другой ссылкой — два объекта за одним
    // объектом POS, повтор создал второй документ.
    conflictOf: (a, b) => (a && b && a.ref !== b.ref ? `один externalId — два объекта 1С: ref ${a.ref ?? 'null'} и ${b.ref ?? 'null'} — повтор с тем же externalId создал второй объект (Требования §4.7: один externalId — один объект)` : null),
    labels: { item: 'externalId', dupInPage: 'запись регистра POS_ВнешниеИдентификаторыPOS выдаётся один раз (выдача без пропусков и повторов, Требования §8.4)' },
    onItem: (it) => records.push(it),
    report: (f) => { if (report) r.add(f.severity, f.text, { code: f.code, where: f.where }); },
    fetchPage: async (cursor, pageNo) => {
      const ex = await r.call({ op: XID, path: '/pos/v1/external-ids', query: { ...query, limit, ...(cursor ? { cursor } : {}) }, label: `${label}, страница ${pageNo}` });
      if (netFailed(r, ex, `страница ${pageNo}`)) return { ex, body: null };
      if (ex.status !== 200) {
        if (pageNo === 1 && isPlatformAbsent(ex)) { absent = true; return { ex, body: null }; }
        if (report) r.fail(`страница ${pageNo}: нужен 200, пришёл ${statusText(ex)}`, { code: 'status' });
        return { ex, body: null };
      }
      return { ex, body: ex.json };
    },
  });
  return { ...res, records, absent };
}

export async function runExternalIdsRead(ctx) {
  await ctx.run('X1', async (r) => {
    const since = isoBishkek(new Date(Date.now() - 7 * 86400000));
    const res = await readXid(ctx, r, { since, limit: 1000 }, { label: `since=${since}` });
    if (res.absent) { ctx.data.absent.add('X1'); r.absent(XID_ABSENT); return; }
    ctx.data.present.add('X1');
    ctx.data.xid = res.records;
    const types = {};
    for (const x of res.records) types[x?.objectType] = (types[x?.objectType] || 0) + 1;
    r.evidence = { since, pages: res.pages, records: res.records.length, byType: types };
    r.pass(`за 7 дней записей: ${res.records.length}, страниц: ${res.pages}`);
  });
  await ctx.run('X2', async (r) => {
    if (ctx.data.absent.has('X1')) { r.absent('МЕТОДА НЕТ (X1) — /external-ids желателен (Требования §6.20)'); return; }
    const ex = await r.call({ op: XID, path: '/pos/v1/external-ids', query: { limit: 10 }, schemaRun: r, label: 'без since' });
    if (netFailed(r, ex, 'без since')) return;
    if (ex.status !== 200) { r.warn(`без since ответ ${statusText(ex)} — по контракту (предложение) без since отдаются все записи`, { code: 'status' }); return; }
    // limit=10 — единственный запрос, где и небольшая тестовая база покажет, что 1С не ограничивает страницу
    // (контракт: «Записей на странице, не более 1000», limit ≤ 1000; POS при ручной привязке читает limit=500 по cursor).
    const n = Array.isArray(ex.json?.items) ? ex.json.items.length : null;
    if (n !== null && n > 10) {
      r.fail(`страница больше limit — 1С не ограничивает страницу: ${n} записей при limit=10 (контракт: limit — записей на странице)`, { code: 'over-limit' });
    }
    r.pass(`200 по схеме${n !== null ? `, записей на странице: ${n}` : ''}`);
  });
  await ctx.run('X3', async (r) => {
    if (ctx.data.absent.has('X1')) { r.absent('МЕТОДА НЕТ (X1) — /external-ids желателен (Требования §6.20)'); return; }
    const res = await readXid(ctx, r, { type: 'Клиент', limit: 1000 }, { label: 'type=Клиент', maxPages: 5 });
    const other = res.records.filter((x) => x?.objectType !== 'Клиент');
    if (other.length) r.fail(`type=Клиент, а пришли записи других типов: ${[...new Set(other.map((x) => x?.objectType))].join(', ')}`, { code: 'type-filter' });
    r.pass(`записей Клиент: ${res.records.length}`);
  });
}

const KIND_TO_TYPE = { Клиент: 'Клиент', Платеж: 'Платеж', Заказ: 'Заказ' };

export async function runX4(ctx) {
  await ctx.run('X4', async (r) => {
    const mine = ctx.registry.created.filter((c) => KIND_TO_TYPE[c.kind] && c.ref && !c.externalId.includes('('));
    const neg = ctx.data.notCreated || [];
    if (ctx.data.absent.has('X1')) { r.absent('МЕТОДА НЕТ (X1) — /external-ids желателен (Требования §6.20)'); return; }
    if (!mine.length && !neg.length) { r.skip('программа ничего не создала'); return; }
    const since = isoBishkek(new Date(ctx.startedAt.getTime() - 86400000));
    const res = await readXid(ctx, r, { since, limit: 1000 }, { label: `since=${since} (созданные проверкой)` });
    const byId = new Map(res.records.map((x) => [x?.externalId, x]));
    // Заказ O1 отменён в O6. Отмена пометкой удаления допустима (Требования §6.7 «Допустима и пометка удаления»), и тогда
    // /external-ids отдаёт его с deletionMark: true (§6.20 «помеченные объекты тоже возвращаются с deletionMark: true»).
    const o1 = ctx.data.o1;
    const markedByRun = (c) => c.checkId === 'O1' && o1?.body?.externalId === c.externalId && o1?.cancelState?.deletionMark === true;
    let ok = 0;
    for (const c of mine) {
      const x = byId.get(c.externalId);
      if (!x) { r.fail(`${c.kind} ${c.externalId} (${c.checkId}) нет в /external-ids`, { code: 'missing', where: c.externalId }); continue; }
      if (x.objectType !== KIND_TO_TYPE[c.kind]) r.fail(`${c.externalId}: objectType ${x.objectType}, нужен ${KIND_TO_TYPE[c.kind]}`, { code: 'type', where: c.externalId });
      if (x.ref !== c.ref) r.fail(`${c.externalId}: ref ${x.ref} не совпадает с ответом создания ${c.ref}`, { code: 'ref', where: c.externalId });
      if (c.number && x.number !== c.number) r.fail(`${c.externalId}: номер «${x.number}» не совпадает с ответом создания «${c.number}»`, { code: 'number', where: c.externalId });
      const want = markedByRun(c);
      if (x.deletionMark !== want) {
        if (want) r.fail(`${c.externalId}: deletionMark = ${x.deletionMark}, а заказ отменён пометкой удаления (O6: deletionMark = true) — /external-ids отдаёт пометку удаления объекта (Требования §6.20 «помеченные объекты тоже возвращаются с deletionMark: true»)`, { code: 'deleted', where: c.externalId });
        else r.fail(`${c.externalId}: deletionMark = ${x.deletionMark} — объект, созданный проверкой, на удаление не помечался${c.checkId === 'O1' && o1?.cancelState ? ' (O6 отменил заказ без пометки удаления: deletionMark = false)' : ''}`, { code: 'deleted', where: c.externalId });
      }
      ok++;
    }
    for (const n of neg) {
      if (byId.has(n.externalId)) r.fail(`${n.externalId} (${n.checkId}): объект не должен был создаваться, но есть в /external-ids`, { code: 'created', where: n.externalId });
    }
    r.evidence = { checked: mine.length, ok, notCreatedChecked: neg.length };
    r.pass(`созданных проверкой: ${mine.length}, найдено и совпадает: ${ok}`);
  });
}

const ORDER_SORT = 'порядок выдачи — по убыванию ДатаСоздания, первыми новые записи (контракт listExternalIds «первыми — новые записи»; Требования §6.20; КП-19 «второй запрос — заказы КП-8, КП-15 от новых к старым»)';
const at = (v) => { const d = parseIso(v); return d ? d.getTime() : null; };
const show = (v) => (v === undefined ? 'нет поля' : v === null ? 'null' : `«${String(v)}»`);

/**
 * X5 — второй запрос КП-19 (Требования §8.3): GET /external-ids?type=Заказ&limit=500 без since, как при ручной привязке
 * заказа (§6.20: POS читает не больше 20 страниц по 500 и ищет заказ по номеру и дате). Заказы этого прогона (O1, O3) —
 * самые новые: первыми на первой странице; запись старше начала проверки перед ними — порядок по возрастанию.
 */
export async function runX5(ctx) {
  await ctx.run('X5', async (r) => {
    if (ctx.data.absent.has('X1')) { r.absent('МЕТОДА НЕТ (X1) — /external-ids желателен (Требования §6.20)'); return; }
    const mine = ctx.registry.created.filter((c) => c.kind === 'Заказ' && c.ref && !c.unknown && !c.externalId.includes('('));
    if (!mine.length) { r.skip('программа не создала заказов (O1, O3) — сравнивать порядок не с чем'); return; }
    const ex = await r.call({ op: XID, path: '/pos/v1/external-ids', query: { type: 'Заказ', limit: 500 }, label: 'type=Заказ&limit=500 без since (ручная привязка, КП-19)' });
    if (netFailed(r, ex, 'без since')) return;
    if (ex.status !== 200) { r.warn(`без since ответ ${statusText(ex)} — по контракту (предложение) без since отдаются все записи; ручная привязка заказа читает именно так (Требования §6.20)`, { code: 'status' }); return; }
    const items = Array.isArray(ex.json?.items) ? ex.json.items : [];
    const other = items.filter((x) => x?.objectType !== 'Заказ');
    if (other.length) r.fail(`type=Заказ, а пришли записи других типов: ${[...new Set(other.map((x) => x?.objectType))].join(', ')}`, { code: 'type-filter' });
    const pos = mine.map((c) => items.findIndex((x) => x?.externalId === c.externalId));
    const lost = mine.filter((c, i) => pos[i] < 0);
    if (lost.length) {
      const names = lost.map((c) => `${c.checkId} (${c.number || c.externalId})`).join(', ');
      if (ex.json?.hasMore === true) {
        r.fail(`заказов этого прогона ${names} нет на первой странице (limit=500), хотя они самые новые — ${ORDER_SORT}; иначе ручная привязка не найдёт свежий заказ, когда записей станет больше 20 страниц по 500`, { code: 'not-first' });
      } else {
        r.fail(`заказов этого прогона ${names} нет в ответе без since — без since метод возвращает все записи (Требования §6.20)`, { code: 'missing' });
      }
    }
    const found = pos.filter((p) => p >= 0);
    if (found.length) {
      // Перед заказами прогона — только записи новее начала проверки (другие заказы, созданные за это время).
      const first = Math.min(...found);
      const start = ctx.startedAt.getTime() - 60000;
      const older = items.slice(0, first).find((x) => { const t = at(x?.date); return t !== null && t < start; });
      if (older) {
        const c = mine[pos.indexOf(first)];
        r.fail(`первыми идут старые записи: на позиции ${items.indexOf(older) + 1} — заказ ${show(older.number)} от ${show(older.date)}, а заказ этого прогона ${c.checkId} (${show(c.number)}) — только на позиции ${first + 1}: ${ORDER_SORT}`, { code: 'order', where: 'старые записи раньше новых' });
      }
      // Между заказами прогона: созданный позже (дата документа позже хотя бы на секунду) идёт раньше.
      for (let i = 0; i < mine.length; i++) {
        for (let k = i + 1; k < mine.length; k++) {
          const ti = at(mine[i].date), tk = at(mine[k].date);
          if (pos[i] >= 0 && pos[k] >= 0 && pos[i] < pos[k] && ti !== null && tk !== null && tk - ti >= 1000) {
            r.fail(`заказ ${mine[k].checkId} (${show(mine[k].number)}, ${show(mine[k].date)}) создан позже заказа ${mine[i].checkId} (${show(mine[i].number)}, ${show(mine[i].date)}), а идёт после него — ${ORDER_SORT}`, { code: 'order', where: 'заказы прогона' });
          }
        }
      }
    }
    r.evidence = { items: items.length, hasMore: ex.json?.hasMore ?? null, positions: Object.fromEntries(mine.map((c, i) => [c.checkId, pos[i] >= 0 ? pos[i] + 1 : null])) };
    r.pass(`заказы прогона (${found.length} из ${mine.length}) — первыми на странице, новые раньше старых`);
  });
}
