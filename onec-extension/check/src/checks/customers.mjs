// K — клиенты: POST /customers (запись), GET /customers?phone, GET /customers/{ref}/receivables.
import { parseIso } from '../report/time.mjs';
import { expectStatus, expectPosError, netFailed, statusText, looksAbsent, burst, rnd, absentRequired } from './common.mjs';

const CREATE = 'POST /pos/v1/customers';
const FIND = 'GET /pos/v1/customers';
const RECV = 'GET /pos/v1/customers/{ref}/receivables';

function localForm(e164) {
  const d = String(e164).replace(/\D/g, '');
  return '0' + d.slice(-9);
}

const last9 = (p) => String(p ?? '').replace(/\D/g, '').slice(-9);

/**
 * Кандидаты с другим номером (контракт GET /customers: «Сравниваются только цифры номера, по последним 9 цифрам»;
 * CustomerCandidate.phone — «Найденный номер»). Номер в протокол не пишется — только ref кандидата.
 */
function foreignCandidates(list, phone) {
  const want = last9(phone);
  if (want.length < 9 || !Array.isArray(list)) return [];
  return list.filter((c) => c && typeof c === 'object' && typeof c.phone === 'string' && last9(c.phone).length === 9 && last9(c.phone) !== want);
}

const RECV_ABSENT = { what: 'долг клиента GET /customers/{ref}/receivables', section: '§6.12', stage: '3 «Чтение»' };

/** Пустая дата 1С (Дата(1, 1, 1)) или дата раньше 1900 года — не значение (см. правило E5 «date-empty»). */
export const emptyDate = (v) => typeof v === 'string' && /^\d{4}-/.test(v) && Number(v.slice(0, 4)) < 1900;

const SNAP_MIN = 5;
const money = (v) => (typeof v === 'string' && /^-?\d+\.\d{2}$/.test(v) ? Number(v) : null);
const minutes = (ms) => {
  const m = Math.round(ms / 60000);
  return m >= 60 ? `${Math.floor(m / 60)} ч ${m % 60} мин` : `${m} мин`;
};

/**
 * Итог долга клиента — в ответе GET /receivables (K8) и в блоке receivables ответа /check (CK4, «те же поля итога»,
 * Требования §6.5): правила приёма POS (контракт CustomerReceivables `x-pos-rejects`, Требования §6.12) и свежесть снимка:
 * «snapshotAt — текущее время сервера 1С на момент расчёта» (§6.12 «Правила на стороне 1С»); POS продаёт в долг только по
 * снимку не старше 60 минут от snapshotAt (§6.12 «Правило POS для продажи в долг»). Допуск — 5 минут, как у правила
 * «snapshotAt позже момента ответа больше чем на 5 минут».
 */
export function receivablesFindings(ctx, r, b, { ex, what, rej }) {
  const bal = money(b.balance), od = money(b.overdueAmount), cl = money(b.creditLimit);
  if (od !== null && bal !== null && (od < 0 || od > Math.max(bal, 0))) rej(`overdueAmount ${b.overdueAmount} вне 0…max(balance, 0) (balance ${b.balance})`, 'overdueAmount');
  if (cl !== null && cl < 0) rej(`creditLimit ${b.creditLimit} < 0`, 'creditLimit');
  const snap = parseIso(b.snapshotAt);
  if (!snap) return null;
  if (snap.getTime() > Date.now() + SNAP_MIN * 60000) { rej(`snapshotAt ${b.snapshotAt} позже «сейчас + 5 мин» — проверьте часы 1С`, 'snapshotAt'); return null; }
  const asked = ex.startedAt instanceof Date ? ex.startedAt.getTime() : Date.now();
  const age = asked - snap.getTime();
  if (age > SNAP_MIN * 60000) {
    const h = parseIso(ctx.data.health?.serverTime), hx = ctx.data.healthEx;
    const skew = h && hx?.startedAt ? h.getTime() - (hx.startedAt.getTime() + (hx.ms || 0) / 2) : null;
    const clock = skew !== null && Math.abs(skew) > SNAP_MIN * 60000 ? `; часы 1С (serverTime в /health) расходятся с этим компьютером на ${minutes(Math.abs(skew))} — проверьте и их (H2)` : '';
    r.fail(`${what}: snapshotAt ${b.snapshotAt} — на ${minutes(age)} раньше момента запроса: снимок не на момент расчёта — snapshotAt — текущее время сервера 1С на момент расчёта, не дата последнего движения регистра и не время кэша (Требования §6.12 «Правила на стороне 1С», «Метод только читает данные, без кэширования»)${age > 60 * 60000 ? '; снимок старше 60 минут — POS откажет в продаже в долг «данные о долге устарели» (§6.12 «Правило POS для продажи в долг»)' : ''}${clock}`, { code: 'snapshot-old', where: what });
    return age;
  }
  return null;
}

export async function runCustomersRead(ctx) {
  await ctx.run('K7', async (r) => {
    const phone = ctx.data.refs?.phone || ctx.settings.phone;
    const probe = await r.call({ op: FIND, path: '/pos/v1/customers', query: { phone: phone || '+996000000000' }, absentProbe: true, label: phone ? 'телефон в виде +996…' : 'обнаружение метода' });
    if (looksAbsent(ctx, probe)) {
      absentRequired(ctx, r, 'K7', { what: 'поиск клиента по телефону GET /customers?phone=', section: '§6.10', stage: '3 «Чтение»', platform405: probe.status === 405 });
      return;
    }
    if (netFailed(r, probe, 'поиск по телефону')) return;
    if (!phone) { r.skip('метод есть, но нет телефона для проверки: укажите phone в настройках (телефон клиента тестовой копии)'); return; }
    if (!expectStatus(r, probe, 200, 'поиск по +996…')) return;
    const otherA = foreignCandidates(probe.json, phone);
    if (otherA.length) {
      r.fail(`кандидат с другим телефоном — поиск не фильтрует по номеру: ${otherA.length} из ${probe.json.length} (последние 9 цифр не совпадают с запросом; ref ${otherA.slice(0, 3).map((c) => c.ref).join(', ')}) — кассир свяжет продажу не с тем клиентом`, { code: 'other-phone' });
    }
    const b = await r.call({ op: FIND, path: '/pos/v1/customers', query: { phone: localForm(phone) }, label: 'телефон в виде 0XXXXXXXXX' });
    if (netFailed(r, b, 'поиск по 0XXXXXXXXX')) return;
    if (b.status === 400) {
      r.warn('поиск по виду 0XXXXXXXXX → 400: POS передаёт +996…, но телефон из старых карточек лучше приводить к одному виду', { code: 'local-400' });
    } else if (expectStatus(r, b, 200, 'поиск по 0XXXXXXXXX')) {
      const otherB = foreignCandidates(b.json, phone);
      if (otherB.length && !otherA.length) {
        r.fail(`кандидат с другим телефоном при поиске по 0XXXXXXXXX — поиск не фильтрует по номеру: ${otherB.length} из ${b.json.length} (ref ${otherB.slice(0, 3).map((c) => c.ref).join(', ')})`, { code: 'other-phone' });
      }
      const refs = (j) => new Set((Array.isArray(j) ? j : []).map((x) => x?.ref));
      const s1 = refs(probe.json), s2 = refs(b.json);
      const same = s1.size === s2.size && [...s1].every((x) => s2.has(x));
      if (!same) r.fail(`разный результат для +996… (${s1.size}) и 0XXXXXXXXX (${s2.size}) — телефон нужно нормализовать до поиска`, { code: 'different' });
    }
    r.evidence = { candidates: Array.isArray(probe.json) ? probe.json.length : null };
    r.pass(`кандидатов: ${Array.isArray(probe.json) ? probe.json.length : '?'}`);
  });
  // K9 — первым: случайный GUID показывает, есть ли метод (обязательный, Требования §6.12).
  await ctx.run('K9', async (r) => {
    const ex = await r.call({ op: RECV, path: `/pos/v1/customers/${rnd()}/receivables`, absentProbe: true, noRetry: true, label: 'несуществующий GUID (есть ли метод)' });
    if (netFailed(r, ex, 'несуществующий клиент')) return;
    if (looksAbsent(ctx, ex)) {
      // Метод мог ответить 404 платформы на неизвестный GUID; известный клиент покажет, есть ли метод.
      const ref = ctx.data.refs?.customerRef;
      let present = false;
      if (ref) {
        const ex2 = await r.call({ op: RECV, path: `/pos/v1/customers/${ref}/receivables`, absentProbe: true, label: 'известный клиент (есть ли метод)' });
        present = !ex2.error && !looksAbsent(ctx, ex2);
      }
      if (!present) {
        absentRequired(ctx, r, 'K9', RECV_ABSENT);
        return;
      }
    }
    ctx.data.present.add('K9');
    if (expectPosError(r, ex, 404, 'POS_E_NOT_FOUND', 'несуществующий клиент')) r.pass('404 POS_E_NOT_FOUND');
  });
  await ctx.run('K8', async (r) => {
    if (ctx.data.absent.has('K9')) { r.skip('метода долга клиента нет (K9 — ОШИБКА)'); return; }
    const ref = ctx.data.refs?.customerRef;
    if (!ref) { r.skip('нет клиента: укажите refs.customerRef в настройках или запустите с --allow-write и перерегистрацией'); return; }
    const ex = await r.call({ op: RECV, path: `/pos/v1/customers/${ref}/receivables`, label: 'долг клиента' });
    if (netFailed(r, ex, 'долг клиента')) return;
    if (ex.status === 404 && ex.isPosError) { r.warn(`клиент ${ref} из /changes не найден методом долгов (404) — проверьте, что это клиент`, { code: 'not-found' }); return; }
    if (!expectStatus(r, ex, 200, 'долг клиента')) return;
    const b = ex.json || {};
    const rej = (t, where = null) => r.fail(`POS не применит ответ: ${t}`, { code: 'reject', where });
    if (b.customerRef !== undefined && b.customerRef !== ref) rej(`customerRef ${b.customerRef} ≠ ref пути ${ref}`, 'customerRef');
    receivablesFindings(ctx, r, b, { ex, what: 'долг клиента', rej });
    const docs = Array.isArray(b.documents) ? b.documents : [];
    const seen = new Set();
    for (const [i, d] of docs.entries()) {
      if (d && seen.has(d.documentRef)) rej(`documents[${i}].documentRef повторяется`, `documents[${i}].documentRef`);
      if (d) seen.add(d.documentRef);
      if (d && (typeof d.number !== 'string' || !d.number.trim())) rej(`documents[${i}].number пустой`, `documents[${i}].number`);
      // Пустая дата 1С вместо null: «к оплате» — dueDate не позже даты снимка и remaining > 0 (Требования §6.12).
      if (d && emptyDate(d.dueDate)) {
        r.fail(`documents[${i}].dueDate ${JSON.stringify(d.dueDate)} — пустая дата 1С вместо null: POS сочтёт срок наступившим и покажет документ «к оплате»; срок не задан — null (Требования §6.12 dueDate «null — срок не задан», «к оплате — dueDate не позже даты снимка и remaining больше нуля»)`, { code: 'due-empty', where: 'documents[*].dueDate' });
      }
    }
    // Код клиента — из /changes (по GUID клиента в 1С не найти); имя не показывается (ПДн).
    const partner = (ctx.data.message?.items || []).find((i) => i.type === 'Catalog_Партнеры' && i.ref === ref);
    ctx.data.k8 = { ref, code: partner?.code ?? null, balance: b.balance, documents: docs.length };
    r.evidence = { documents: docs.length, balance: b.balance, overdueAmount: b.overdueAmount, creditAllowed: b.creditAllowed };
    r.pass(`долг ${b.balance}, документов ${docs.length}`);
  });
}

export async function runCustomersWrite(ctx) {
  const synth = ctx.synth;
  let k1 = null;
  await ctx.run('K1', async (r) => {
    const body = synth.customer();
    const ex = await r.call({ op: CREATE, path: '/pos/v1/customers', body, label: 'новый клиент «ПРОВЕРКА POS»' });
    if (netFailed(r, ex, 'создание клиента')) {
      ctx.registry.addCreated({ kind: 'Клиент', externalId: body.externalId, checkId: 'K1', unknown: true, note: 'результат неизвестен (нет ответа)' });
      return;
    }
    if (ex.status === 200) r.fail('200 вместо 201 на первое создание (externalId новый) — 200 только для повтора', { code: '200' });
    else if (ex.status !== 201) { r.fail(`новый клиент: нужен 201, пришёл ${statusText(ex)}`, { code: 'status' }); return; }
    const j = ex.json || {};
    ctx.registry.addCreated({ kind: 'Клиент', externalId: body.externalId, ref: j.ref ?? null, number: j.code ?? null, checkId: 'K1' });
    if (j.created !== true) r.fail(`created = ${JSON.stringify(j.created)} — для нового клиента нужно true`, { code: 'created' });
    if (j.externalId !== body.externalId) r.fail('externalId ответа не равен externalId запроса', { code: 'external-id' });
    k1 = { body, ref: j.ref, code: j.code, contractorRef: j.contractorRef ?? null, externalId: body.externalId, phone: body.phone };
    ctx.data.k1 = k1;
    r.pass(`201, ref ${j.ref}, код ${j.code ?? 'null'}`);
  });
  await ctx.run('K2', async (r) => {
    if (!k1?.ref) { r.skip('нет клиента из K1'); return; }
    const ex = await r.call({ op: CREATE, path: '/pos/v1/customers', body: k1.body, label: 'повтор того же externalId' });
    if (ex.status === 201) {
      ctx.registry.addCreated({ kind: 'Клиент', externalId: k1.externalId + ' (повтор)', ref: ex.json?.ref ?? null, checkId: 'K2', note: 'повтор создал второй объект' });
      r.fail(`повтор создал второй объект: 201${ex.json?.ref && ex.json.ref !== k1.ref ? ` с новым ref ${ex.json.ref}` : ''} — нужен 200 с тем же ref`, { code: 'dup' });
      return;
    }
    if (!expectStatus(r, ex, 200, 'повтор')) return;
    const j = ex.json || {};
    if (j.ref !== k1.ref) r.fail(`повтор вернул другой ref: ${j.ref} (был ${k1.ref})`, { code: 'ref' });
    if ((j.code ?? null) !== (k1.code ?? null)) r.fail(`повтор вернул другой код: ${j.code} (был ${k1.code})`, { code: 'code' });
    // Контрагент — часть клиента: новый contractorRef на повтор значит, что 1С снова создала контрагента (Требования §4.7 п. 1:
    // «нашли — вернуть 200 с уже существующим объектом, ничего не создавать и не изменять»).
    if ((j.contractorRef ?? null) !== (k1.contractorRef ?? null)) r.fail(`повтор вернул другого контрагента: contractorRef ${j.contractorRef ?? 'null'} (был ${k1.contractorRef ?? 'null'}) — на повтор ничего не создавать (Требования §4.7 п. 1)`, { code: 'contractor' });
    if (j.created !== false) r.fail(`created = ${JSON.stringify(j.created)} — для повтора нужно false`, { code: 'created' });
    r.pass('200, тот же ref, created=false');
  });
  await ctx.run('K3', async (r) => {
    const body = synth.customer();
    await burst(ctx, r, { op: CREATE, path: '/pos/v1/customers', body, kind: 'Клиент', numberOf: (j) => j?.code ?? null, same: ['code', 'contractorRef'] });
  });
  await ctx.run('K4', async (r) => {
    if (!k1?.ref) { r.skip('нет клиента из K1'); return; }
    const body = synth.customer({ phone: k1.phone, failOnDuplicate: true });
    const ex = await r.call({ op: CREATE, path: '/pos/v1/customers', body, label: 'другой externalId, тот же телефон' });
    if (ex.status === 201 || ex.status === 200) {
      ctx.registry.addCreated({ kind: 'Клиент', externalId: body.externalId, ref: ex.json?.ref ?? null, number: ex.json?.code ?? null, checkId: 'K4', note: 'создан дубль по телефону' });
      r.fail(`дубль по телефону создан (${ex.status}) — при failOnDuplicate=true нужен 409 POS_E_DUPLICATE`, { code: 'created' });
      return;
    }
    if (!expectPosError(r, ex, 409, 'POS_E_DUPLICATE', 'дубль по телефону')) return;
    ctx.data.notCreated = [...(ctx.data.notCreated || []), { externalId: body.externalId, checkId: 'K4' }];
    const cands = ex.json?.details?.candidates;
    if (!Array.isArray(cands) || !cands.length) { r.fail('в ответе 409 нет details.candidates — POS не сможет связать клиента с найденным', { code: 'no-candidates' }); return; }
    if (!cands.some((c) => c && c.ref === k1.ref)) r.fail(`details.candidates не содержит ref клиента из K1 (${k1.ref})`, { code: 'no-k1' });
    r.pass(`409 POS_E_DUPLICATE, кандидатов ${cands.length}`);
  });
  await ctx.run('K5', async (r) => {
    if (!k1?.ref) { r.skip('нет клиента из K1'); return; }
    const body = synth.customer({ phone: k1.phone, failOnDuplicate: false });
    const ex = await r.call({ op: CREATE, path: '/pos/v1/customers', body, label: 'тот же телефон, failOnDuplicate=false' });
    if (netFailed(r, ex, 'failOnDuplicate=false')) return;
    if (ex.status === 409) {
      ctx.data.notCreated = [...(ctx.data.notCreated || []), { externalId: body.externalId, checkId: 'K5' }];
      r.warn('failOnDuplicate=false не поддержан: 409 вместо 201 (поле контракта — предложение; если не согласны, напишите нам)', { code: 'proposed' });
      return;
    }
    if (!expectStatus(r, ex, 201, 'failOnDuplicate=false')) return;
    const j5 = ex.json || {};
    // 201 и created=true, а ref — клиента из K1: новая карточка не создана, вернулся существующий клиент (контракт
    // POST /customers: «при failOnDuplicate=false проверка дублей не выполняется и карточка создаётся — 201»).
    if (j5.ref && j5.ref === k1.ref) {
      r.fail(`при failOnDuplicate=false вернулся существующий клиент из K1 (ref ${j5.ref}) — нужна новая карточка: проверка дублей не выполняется, клиент создаётся (контракт POST /customers, Требования §6.11)`, { code: 'existing' });
      return;
    }
    if (j5.contractorRef && k1.contractorRef && j5.contractorRef === k1.contractorRef) r.fail(`новый клиент получил контрагента клиента из K1 (contractorRef ${j5.contractorRef}) — у новой карточки свой контрагент`, { code: 'existing-contractor' });
    if (j5.created !== true) r.fail(`created = ${JSON.stringify(j5.created)} — для новой карточки нужно true`, { code: 'created' });
    ctx.registry.addCreated({ kind: 'Клиент', externalId: body.externalId, ref: j5.ref ?? null, number: j5.code ?? null, checkId: 'K5' });
    r.pass(`201, новый клиент ${j5.ref}`);
  });
  await ctx.run('K6', async (r) => {
    const body = synth.customer({ phone: '0700000000' });
    const ex = await r.call({ op: CREATE, path: '/pos/v1/customers', body, dataError: true, label: 'телефон не E.164' });
    if (netFailed(r, ex, 'телефон не E.164')) return;
    if (ex.status === 201 || ex.status === 200) {
      ctx.registry.addCreated({ kind: 'Клиент', externalId: body.externalId, ref: ex.json?.ref ?? null, checkId: 'K6', note: 'создан с неверным телефоном' });
      r.fail(`клиент с телефоном не в формате +996XXXXXXXXX создан (${ex.status}) — нужен 400 или 422`, { code: 'created' });
      return;
    }
    ctx.data.notCreated = [...(ctx.data.notCreated || []), { externalId: body.externalId, checkId: 'K6' }];
    if (ex.status >= 500) { r.fail(`ошибка данных отдана как ${statusText(ex)} — нужен 400 или 422`, { code: '5xx' }); return; }
    if (![400, 422].includes(ex.status) || !ex.isPosError) { r.fail(`нужен 400 или 422 в едином формате, пришёл ${statusText(ex)}`, { code: 'status' }); return; }
    r.pass(statusText(ex));
  });
}

