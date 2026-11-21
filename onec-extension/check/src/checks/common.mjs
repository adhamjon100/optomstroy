// Общие помощники проверок.
import crypto from 'node:crypto';
import { isPlatformAbsent } from '../rules.mjs';
import { plural } from '../util.mjs';
import { parseIso, isoBishkek } from '../report/time.mjs';

/** Расхождение часов 1С с этим компьютером по serverTime из /health (мс; 1С впереди — больше нуля) или 0. */
export function healthSkewMs(ctx) {
  const h = parseIso(ctx.data.health?.serverTime), hx = ctx.data.healthEx;
  return h && hx?.startedAt ? h.getTime() - (hx.startedAt.getTime() + (hx.ms || 0) / 2) : 0;
}

const hm = (ms) => {
  const m = Math.round(Math.abs(ms) / 60000);
  return m >= 60 ? `${Math.floor(m / 60)} ч${m % 60 ? ` ${m % 60} мин` : ''}` : `${m} мин`;
};

/** Допуск «дата документа — момент запроса»: час (очередь, медленная 1С, расхождение часов — с запасом). */
export const DOC_DATE_TOLERANCE_MS = 60 * 60000;

/**
 * Дата только что созданного документа (date ответа 201 заказа или оплаты, createdAt QR) против момента запроса
 * (Требования §4.3: «Дата и время — ISO 8601 со смещением +06:00 (Бишкек…)»). Верны: момент создания в 1С (≈ момент
 * запроса) или момент из запроса (sentAt — createdAt заказа, receivedAt оплаты). Дата, отстоящая от обоих больше чем на
 * час, — время сервера 1С в другом часовом поясе с подписью +06:00 (сервер во Франкфурте — на 5 ч позади Бишкека):
 * POS покажет документ с неверной датой и не найдёт его при ручной привязке по номеру и дате (§6.20). Расхождение
 * часов из /health (H2) учитывается. Формат даты проверяет E5; здесь — только момент.
 */
export function documentDateFindings(ctx, r, { date, sentAt = null, sentField = null, ex, what }) {
  const d = parseIso(date);
  if (!d || !(ex?.startedAt instanceof Date)) return;
  const sent = parseIso(sentAt);
  if (sent && Math.abs(d.getTime() - sent.getTime()) <= 1000) return;
  const asked = ex.startedAt.getTime() + (ex.ms || 0) / 2;
  const diff = d.getTime() - asked;
  const skew = healthSkewMs(ctx);
  if (Math.min(Math.abs(diff), Math.abs(diff - skew)) <= DOC_DATE_TOLERANCE_MS) return;
  const sentText = sent && sentField ? ` и не равна ${sentField} запроса (${sentAt})` : '';
  r.fail(`${what}: ${date} — на ${hm(diff)} ${diff < 0 ? 'раньше' : 'позже'} момента запроса (${isoBishkek(new Date(asked))})${sentText}: даты — время Бишкека со смещением +06:00 (Требования §4.3 «Дата и время — ISO 8601 со смещением +06:00 (Бишкек, без перехода на летнее время)»). Похоже, 1С берёт время сервера в другом часовом поясе и подписывает его +06:00 (сервер во Франкфурте — на 5 ч позади Бишкека): проверьте ЧасовойПоясИнформационнойБазы() — нужен "Asia/Bishkek" (УстановитьЧасовойПоясИнформационнойБазы("Asia/Bishkek")), дату документа берите ТекущаяДатаСеанса() в этом поясе; иначе POS покажет документ с неверной датой и не найдёт его при ручной привязке по номеру и дате (§6.20)`, { code: 'date-tz', where: what });
}

/**
 * «Метода нет» у метода, обязательного по Требованиям (x-priority: must): ОШИБКА с разделом и этапом работ.
 * stage — этап «Порядка работ» (Требования §8.2), на котором метод делается: если этап ещё не начат, ошибка уйдёт,
 * когда метод появится.
 */
export function absentRequired(ctx, r, id, { what, section, stage, platform405 = false }) {
  ctx.data.absent.add(id);
  r.fail(`МЕТОДА НЕТ — ${what}${platform405 ? ' (шаблон URL есть, а обработчика этого HTTP-метода нет — ответ 405)' : ''}: метод обязателен (Требования к API 1С ${section}; делается на этапе ${stage} раздела 8.2)`, { code: 'absent-required' });
}

export function rnd() {
  return crypto.randomUUID();
}

/** Сетевой сбой → FAIL с объяснением; true, если сбой был. */
export function netFailed(run, ex, what = 'запрос') {
  if (!ex.error) return false;
  run.fail(`${what} — ${ex.errorInfo ? ex.errorInfo.text : ex.error.message}`, { code: 'net-' + (ex.errorInfo?.code || 'err') });
  return true;
}

export function statusText(ex) {
  if (ex.error) return ex.errorInfo ? ex.errorInfo.code : 'ошибка связи';
  return `${ex.status}${ex.posCode ? ' ' + ex.posCode : ''}`;
}

/** Ожидаемый статус; иначе FAIL. */
export function expectStatus(run, ex, statuses, what) {
  const list = Array.isArray(statuses) ? statuses : [statuses];
  if (netFailed(run, ex, what)) return false;
  if (!list.includes(ex.status)) {
    run.fail(`${what}: ожидался ${list.join(' или ')}, пришёл ${statusText(ex)}`, { code: 'status' });
    return false;
  }
  return true;
}

/** Ожидаемая ошибка: статус и код POS. */
export function expectPosError(run, ex, statuses, codes, what) {
  const st = Array.isArray(statuses) ? statuses : [statuses];
  const cs = Array.isArray(codes) ? codes : [codes];
  if (netFailed(run, ex, what)) return false;
  if (!st.includes(ex.status)) {
    run.fail(`${what}: нужен ${st.join(' или ')} ${cs.join(' или ')}, пришёл ${statusText(ex)}`, { code: 'status' });
    return false;
  }
  if (!ex.isPosError) {
    run.fail(`${what}: ${ex.status} без тела ошибки в едином формате (нужен ${cs.join(' или ')})`, { code: 'no-pos-body' });
    return false;
  }
  if (!cs.includes(ex.posCode)) {
    run.fail(`${what}: код ${ex.posCode}, нужен ${cs.join(' или ')}`, { code: 'code' });
    return false;
  }
  return true;
}

/**
 * Метода нет: 404 или 405 платформы (не тело POS_E_*, не JSON-объект). 405 платформа 1С отвечает, когда шаблон URL
 * есть, а обработчика этого HTTP-метода нет (например, шаблон /customers только для POST, а запрос — GET).
 */
export function looksAbsent(ctx, ex) {
  return isPlatformAbsent(ex);
}

export function ref(ctx, key) {
  return ctx.data.refs?.[key] || null;
}

/** Параллельный запуск: K3, PAY3, O3. */
export async function concurrent(n, fn) {
  return Promise.all(Array.from({ length: n }, (_, i) => fn(i)));
}

/**
 * Повтор с тем же externalId возвращает тот же объект (Требования §4.7 п. 1: «вернуть 200 с уже существующим объектом:
 * номер, дата, статус»): кроме ref сравниваются поля same (номер, дата, контрагент…). Возвращает тексты расхождений.
 */
export function sameObjectDiffs(first, again, same) {
  const out = [];
  if (!first || !again) return out;
  for (const k of same) {
    const a = first[k] ?? null, b = again[k] ?? null;
    if (JSON.stringify(a) !== JSON.stringify(b)) out.push(`${k}: «${b ?? 'null'}» (было «${a ?? 'null'}»)`);
  }
  return out;
}

/**
 * Значение поля для сравнения ответов одного объекта: путь через точку (`totals.total`); деньги («1.00», «1.0») — числом
 * с двумя знаками, чтобы разная запись одной суммы не считалась расхождением (формат проверяет E5).
 */
export function fieldValue(j, key) {
  let v = j;
  for (const p of key.split('.')) v = v && typeof v === 'object' ? v[p] : undefined;
  if (typeof v === 'string' && /^-?\d+(\.\d+)?$/.test(v.trim()) && /(^|\.)(total|subtotal|discount|amount)$/.test(key)) return Number(v).toFixed(2);
  return JSON.stringify(v ?? null);
}

/**
 * Десять одновременных запросов с одним новым externalId (K3, PAY3, O3): ровно один 201, остальные 200,
 * у всех один ref и те же поля same (номер, дата, контрагент); 423/503 POS_E_LOCKED допускается — такой запрос
 * повторяется один раз через 2 с.
 * @returns {{ref:string|null, created:object|null}}
 */
export async function burst(ctx, r, { op, path, body, kind, refOf = (j) => j?.ref, numberOf = (j) => j?.number ?? j?.code ?? null, same = ['number', 'date'] }) {
  const sleep = (ms) => new Promise((res) => setTimeout(res, ms));
  const first = await concurrent(10, (i) => r.call({ op, path, body, label: `одновременный запрос ${i + 1} из 10` }));
  const final = [];
  for (const ex of first) {
    if (!ex.error && (ex.status === 423 || ex.status === 503) && ex.posCode === 'POS_E_LOCKED') {
      await sleep(2000 * ctx.flags.timeoutScale);
      const again = await r.call({ op, path, body, label: 'повтор после POS_E_LOCKED' });
      if (again.status !== 200) r.fail(`после POS_E_LOCKED повтор через 2 с: нужен 200 с тем же объектом, пришёл ${again.error ? again.errorInfo.code : again.status}`, { code: 'locked-retry' });
      final.push(again);
    } else final.push(ex);
  }
  const by = {};
  for (const ex of final) { const k = ex.error ? 'сбой' : String(ex.status); by[k] = (by[k] || 0) + 1; }
  const refs = new Set(final.filter((ex) => ex.status === 200 || ex.status === 201).map((ex) => refOf(ex.json)).filter(Boolean));
  const created = final.find((ex) => ex.status === 201) || final.find((ex) => ex.status === 200);
  const c201 = by['201'] || 0;
  r.evidence = { statuses: by, distinctRefs: refs.size };
  if (created) {
    ctx.registry.addCreated({ kind, externalId: body.externalId, ref: refOf(created.json), number: numberOf(created.json), date: created.json?.date ?? null, checkId: r.id });
    for (const ref of refs) if (ref !== refOf(created.json)) ctx.registry.addCreated({ kind, externalId: body.externalId + ' (дубль)', ref, checkId: r.id, note: 'лишний объект от одновременных запросов' });
  } else if (final.some((ex) => ex.error)) {
    ctx.registry.addCreated({ kind, externalId: body.externalId, checkId: r.id, unknown: true, note: 'результат неизвестен (нет ответа)' });
  }
  if (refs.size > 1) r.fail(`10 одновременных запросов создали ${refs.size} ${plural(refs.size, 'объект', 'объекта', 'объектов')} — нужен один (управляемая блокировка по externalId)`, { code: 'many' });
  else if (created) {
    // Тот же ref, но другой номер, дата или контрагент: повтор создал или перезаписал часть объекта.
    const ok = final.filter((ex) => (ex.status === 200 || ex.status === 201) && ex.json && typeof ex.json === 'object');
    const fields = new Map();
    for (const k of same) {
      const vals = new Set(ok.map((ex) => fieldValue(ex.json, k)));
      if (vals.size > 1) fields.set(k, vals.size);
    }
    for (const [k, n] of fields) {
      r.fail(`ответы на 10 одновременных запросов с одним externalId: ref один, а ${k} — ${n} разных значений; повтор возвращает тот же объект с тем же ${k} (Требования §4.7 п. 1) — похоже, повтор создаёт или перезаписывает часть объекта`, { code: 'same-' + k });
    }
  }
  if (c201 !== 1) r.fail(`ответов 201: ${c201} — нужен ровно один 201, остальные 200 (ответы: ${Object.entries(by).map(([k, v]) => `${k}×${v}`).join(', ')})`, { code: 'count-201' });
  const others = final.filter((ex) => ex.error || (ex.status !== 200 && ex.status !== 201));
  if (others.length) r.fail(`ответы не 200/201: ${others.map((ex) => ex.error ? ex.errorInfo.code : ex.status).join(', ')}`, { code: 'other' });
  r.pass(`один объект, ответы: ${Object.entries(by).map(([k, v]) => `${k}×${v}`).join(', ')}`);
  return { ref: created ? refOf(created.json) : null, created };
}
