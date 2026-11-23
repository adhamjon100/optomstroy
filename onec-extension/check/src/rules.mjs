// Сквозные правила E1–E3, E7–E12 для одного ответа (E4–E6 — из валидатора схем).
import { hasCyrillic, jsonErrorWhere } from './util.mjs';
import { blankProductNames } from './mask.mjs';

export const STATUS_CODES = {
  400: ['POS_E_BAD_REQUEST'],
  401: ['POS_E_UNAUTHORIZED'],
  403: ['POS_E_FORBIDDEN'],
  404: ['POS_E_NOT_FOUND'],
  409: ['POS_E_DUPLICATE', 'POS_E_STATE', 'POS_E_ACK_OUT_OF_ORDER', 'POS_E_STOCK', 'POS_E_PRICE', 'POS_E_CREDIT'],
  422: ['POS_E_VALIDATION'],
  423: ['POS_E_LOCKED'],
  500: ['POS_E_INTERNAL'],
  503: ['POS_E_LOCKED', 'POS_E_MAINTENANCE', 'POS_E_QR_UNAVAILABLE'],
};

// Суммы в тексте ошибки (E9). Сначала убираются GUID и даты, разделители тысяч (пробел, неразрывный и узкий
// неразрывный пробел) и десятичная запятая → точка: «15 300,00» (Формат 1С по умолчанию) = «15300.00».
const GUID_OR_DATE_G = /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|\d{4}-\d{2}-\d{2}(?:[T ][\d:.]+(?:Z|[+-]\d{2}:?\d{2})?)?|\d{2}\.\d{2}\.\d{4}(?:\s+\d{1,2}:\d{2}(?::\d{2})?)?/g;
// Число с единицей измерения (2.70 кг, 0.45 мм, 1.50 м, 12.00 шт, 3.00 %) или размер (3х2.50, 30.00х60.00) — не деньги:
// в магазине стройматериалов это наименования и количества товаров (Требования §4.6 запрещают в message телефоны, ИНН,
// имена клиентов и суммы долга; наименования товаров не запрещены).
const UNIT = String.raw`(?:кг|мг|г|мм|см|дм|м2|м²|м3|м³|кв\.?\s?м|пог\.?\s?м|п\.\s?м|мл|м|л|шт|%)(?![\p{L}\d])`;
const SIZE_BEFORE = String.raw`(?<!\d\s?[хХxX×*]\s?)`;
const SIZE_AFTER = String.raw`(?!\s?[хХxX×*]\s?\d)`;
const AMOUNT_G = new RegExp(String.raw`(?<![\d.])${SIZE_BEFORE}\d+\.\d{2}(?!\d)${SIZE_AFTER}(?!\s?${UNIT})|(?<![\d.])${SIZE_BEFORE}\d+(?=\s?(?:сом|KGS)(?!\p{L}))`, 'gu');
// Слова «долга» — только целым словом: «долговечная», «Ограничитель лимита»… — не долг (основа внутри слова).
// Внутри «…» после «товар», «номенклатура», «картинка товара» — наименование товара («Плитка Керамин Сальдо»), не долг.
const DEBT_WORD = String.raw`(?<!\p{L})(?:долг(?:а|у|ом|е|и|ов|ам|ами|ах)?|задолженн\p{L}*|сальдо|лимит(?:а|у|ом|е|ы|ов)?|аванс(?:а|у|ом|е|ы|ов)?|кредит(?:а|у|ом|е|ы|ов)?|переплат\p{L}*)(?!\p{L})`;
const DEBT_BEFORE = new RegExp(String.raw`${DEBT_WORD}[^.;!?\n]{0,40}$`, 'iu');
const DEBT_AFTER = new RegExp(String.raw`^\s*(?:сом\p{L}*|KGS)?\s*(?:долг(?:а|у|ом|е|и|ов)?|задолженн\p{L}*)(?!\p{L})`, 'iu');
/** {debt: сумма рядом со словом «долг», «задолженность», «лимит»…; other: прочая сумма от 1000 с копейками}. */
export function sumsIn(text) {
  let t = String(text ?? '').replace(GUID_OR_DATE_G, ' ');
  t = t.replace(/(\d)[    ](?=\d{3}(?!\d))/g, '$1').replace(/(\d),(\d{2})(?!\d)/g, '$1.$2');
  const words = blankProductNames(t);
  let debt = false, other = false;
  for (const m of t.matchAll(AMOUNT_G)) {
    const before = words.slice(Math.max(0, m.index - 60), m.index);
    const after = words.slice(m.index + m[0].length, m.index + m[0].length + 30);
    if (DEBT_BEFORE.test(before) || DEBT_AFTER.test(after)) debt = true;
    else if (/^\d{4,}\.\d{2}$/.test(m[0])) other = true;
  }
  return { debt, other };
}

// 405 — платформа 1С: шаблон URL есть, а обработчика для этого HTTP-метода нет (например, /customers только для POST).
const PLATFORM_STATUSES = new Set([401, 404, 405, 500, 503]);
const utf8 = new TextDecoder('utf-8', { fatal: true });

/** Разбор тела ответа: BOM, UTF-8, JSON, признак тела ошибки POS. */
export function parseExchange(ex) {
  const buf = ex.body || Buffer.alloc(0);
  ex.size = buf.length;
  ex.contentType = ex.headers?.['content-type'] || null;
  ex.bom = buf.length >= 3 && buf[0] === 0xef && buf[1] === 0xbb && buf[2] === 0xbf;
  const raw = ex.bom ? buf.subarray(3) : buf;
  ex.utf8ok = true;
  try { ex.text = utf8.decode(raw); } catch { ex.utf8ok = false; ex.text = raw.toString('latin1'); }
  ex.json = undefined;
  ex.jsonError = null;
  const looksJson = /^\s*[[{"]/.test(ex.text) || /json/i.test(ex.contentType || '');
  if (ex.text.trim() && looksJson && !(ex.isBinary && ex.status < 400)) {
    // Текст V8 не сохраняется: он по-английски и цитирует кусок тела (там могут быть имя клиента или секрет).
    try { ex.json = JSON.parse(ex.text); } catch {
      const w = jsonErrorWhere(ex.text);
      ex.jsonErrorPos = w;
      ex.jsonError = w ? `строка ${w.line}, столбец ${w.col}` : 'позиция неизвестна';
    }
  }
  ex.isPosError = ex.status >= 400 && ex.json && typeof ex.json === 'object' && !Array.isArray(ex.json)
    && typeof ex.json.code === 'string' && /^POS_E_/.test(ex.json.code);
  // Ошибка, отданная со статусом 2xx: тело {code: 'POS_E_…', message} при 200 (Требования, приложение А.1: у кода свой HTTP-статус).
  ex.errorIn2xx = ex.status >= 200 && ex.status < 300 && !!ex.json && typeof ex.json === 'object' && !Array.isArray(ex.json)
    && typeof ex.json.code === 'string' && /^POS_E_/.test(ex.json.code) && typeof ex.json.message === 'string';
  ex.platform = ex.status >= 400 && !ex.isPosError && !(ex.json && typeof ex.json === 'object');
  ex.posCode = ex.isPosError ? ex.json.code : null;
  return ex;
}

/** Похоже ли на «ответ платформы» (метод/URL не существует): 404 без тела POS. */
export function isPlatform404(ex) {
  return ex.status === 404 && !ex.isPosError;
}

/**
 * «Метода нет»: 404 (адреса нет среди шаблонов) или 405 (шаблон есть, обработчика этого HTTP-метода нет) — ответ
 * платформы или веб-сервера, без JSON-объекта в теле. Тело-объект JSON без кода POS — ответил код расширения.
 */
export function isPlatformAbsent(ex) {
  return !ex.error && (ex.status === 404 || ex.status === 405) && !ex.isPosError && !(ex.json && typeof ex.json === 'object');
}

/**
 * Строки JSON с одиночным суррогатом (\ud83d без пары — половина эмодзи, обрезанного Лев()): такую строку нельзя
 * записать в UTF-8. Возвращает до 3 путей.
 */
export function loneSurrogates(v, path = '', out = []) {
  if (out.length >= 3) return out;
  if (typeof v === 'string') { if (!v.isWellFormed()) out.push(path || '(значение)'); return out; }
  if (Array.isArray(v)) { v.forEach((x, i) => loneSurrogates(x, `${path}[${i}]`, out)); return out; }
  if (v && typeof v === 'object') {
    for (const [k, x] of Object.entries(v)) {
      if (!k.isWellFormed() && out.length < 3) out.push(`${path ? path + '.' : ''}(имя поля)`);
      loneSurrogates(x, path ? `${path}.${k}` : k, out);
    }
  }
  return out;
}

/** Тело — JSON-строка, в которой лежит JSON-объект или массив (ответ закодирован дважды). */
export function doubleEncoded(j) {
  if (typeof j !== 'string' || !/^\s*[[{]/.test(j)) return false;
  try { const x = JSON.parse(j); return !!x && typeof x === 'object'; } catch { return false; }
}

// Буквы кыргызского алфавита, которых нет в русском: ң, ө, ү.
const KY_LETTERS = /[ңөүҢӨҮ]/;

/**
 * @param ex разобранный обмен
 * @param op операция контракта или null (контрольный запрос на несуществующий путь)
 * @param spec параметры вызова: {dataError, allowStatuses, absentProbe, image, noBodyExpected}
 * @param env {masker, errorCodes}
 * @returns {{rule:string, severity:string, code:string, text:string, hint?:string}[]}
 */
export function crossRules(ex, op, spec, env) {
  const out = [];
  const add = (rule, severity, code, text, hint) => out.push({ rule, severity, code, text, hint: hint || null });
  const st = ex.status;

  // E10 — время: таймаут POS (x-timeout-ms) и цели Требований §4.9 («/check — не более 3 с», «формирование страницы
  // /changes — не более 20 с»).
  if (ex.error && ex.error.code === 'RESPONSE_TIMEOUT') {
    add('E10', 'FAIL', 'timeout', `нет ответа за ${Math.round(ex.timeoutMs / 1000)} с — POS считает результат неизвестным (x-timeout-ms контракта)`);
  } else if (!ex.error && st) {
    if (op && op.path === '/pos/v1/check' && ex.ms > 3000) add('E10', 'WARN', 'check-3s', `проверка корзины ${(ex.ms / 1000).toFixed(1)} с — дольше цели 3 с (Требования §4.9)`);
    if (op && op.path === '/pos/v1/changes' && ex.ms > 20000) add('E10', 'WARN', 'page-20s', `страница /changes ${Math.round(ex.ms / 1000)} с — дольше 20 с (Требования §4.9)`);
  }
  if (ex.error || !st) return out;

  const is2xx = st >= 200 && st < 300;
  const reqId = ex.requestId;
  const echo = ex.headers['x-request-id'];

  // E1 — версия API
  if (is2xx) {
    const v = ex.headers['x-pos-api-version'];
    if (v === undefined) add('E1', 'FAIL', 'no-version', 'нет заголовка X-POS-API-Version: 1', 'Заголовок X-POS-API-Version: 1 — в каждом успешном ответе расширения.');
    else if (String(v).trim() !== '1') add('E1', 'FAIL', 'bad-version', `X-POS-API-Version: «${v}» — нужно 1`);
  }

  // E2 — X-Request-Id
  if (is2xx || ex.isPosError) {
    if (!echo) add('E2', 'FAIL', 'no-echo', 'нет заголовка X-Request-Id в ответе — нужно вернуть значение из запроса', 'Ответ.Заголовки.Вставить("X-Request-Id", Запрос.Заголовки.Получить("X-Request-Id"))');
    else if (String(echo).trim().toLowerCase() !== reqId) add('E2', 'FAIL', 'echo-differs', 'X-Request-Id ответа не совпадает с запросом');
  }
  if (ex.isPosError && typeof ex.json.requestId === 'string' && ex.json.requestId.toLowerCase() !== reqId) {
    add('E2', 'FAIL', 'body-reqid', 'requestId в теле ошибки не совпадает с X-Request-Id запроса');
  }

  // E3 — JSON, UTF-8 без BOM, Content-Type
  const jsonExpected = (is2xx && !spec.image && !spec.noBodyExpected && !(st === 202) && !(st === 204))
    || ex.isPosError || (st >= 400 && ex.json && typeof ex.json === 'object');
  if (jsonExpected) {
    if (ex.bom) add('E3', 'FAIL', 'bom', 'тело начинается с BOM (EF BB BF) — JSON нужен в UTF-8 без BOM', 'ЗаписьJSON: ПараметрыЗаписиJSON / ЗаписьТекста с ИспользованиеByteOrderMark.НеИспользовать; HTTPСервисОтвет.УстановитьТелоИзСтроки(Текст, КодировкаТекста.UTF8, ИспользованиеByteOrderMark.НеИспользовать).');
    if (!ex.utf8ok) add('E3', 'FAIL', 'not-utf8', 'тело не в UTF-8 (похоже на windows-1251) — JSON нужен в UTF-8', 'УстановитьТелоИзСтроки(Текст, КодировкаТекста.UTF8, …)');
    const ct = String(ex.contentType || '');
    if (!ct) add('E3', 'FAIL', 'no-ct', 'нет заголовка Content-Type — нужно application/json; charset=utf-8');
    else if (!/^application\/(.+\+)?json\b/i.test(ct)) add('E3', 'FAIL', 'not-json-ct', `ответ не JSON (Content-Type: ${ct.slice(0, 60)}) — нужно application/json; charset=utf-8`);
    else {
      const cs = /charset\s*=\s*"?([\w-]+)/i.exec(ct);
      if (!cs) add('E3', 'WARN', 'no-charset', 'в Content-Type нет charset=utf-8');
      else if (!/^utf-?8$/i.test(cs[1])) add('E3', 'FAIL', 'bad-charset', `charset=${cs[1]} — нужно utf-8`);
    }
    if (ex.text.trim() === '' && is2xx) add('E3', 'FAIL', 'empty', 'пустое тело ответа — ожидался JSON');
    else if (ex.jsonError) add('E3', 'FAIL', 'bad-json', `тело — неверный JSON (${ex.jsonError})`, 'Собирайте JSON через ЗаписьJSON / ЗаписатьJSON, не склейкой строк: кавычки и переводы строки в наименованиях тогда экранируются сами.');
    else if (doubleEncoded(ex.json)) {
      add('E3', 'FAIL', 'double-json', 'тело — JSON-строка, внутри которой ещё один JSON: ответ закодирован дважды (ЗаписатьJSON от уже готовой строки JSON) — нужен сам объект',
        'Пишите структуру в ответ через ЗаписатьJSON один раз; строку, уже полученную из ЗаписатьJSON, отдавайте телом как есть (УстановитьТелоИзСтроки), не кодируйте её снова.');
    }
    if (ex.json !== undefined && !ex.jsonError) {
      const lone = loneSurrogates(ex.json);
      if (lone.length) {
        add('E3', 'WARN', 'lone-surrogate', `строка с половиной символа (одиночный суррогат) в ${lone.join(', ')} — такую строку нельзя записать в UTF-8 (Требования §4.3: JSON в UTF-8); POS сохранит вместо символа «�» или отклонит элемент`,
          'Строку обрезают посреди эмодзи (Лев(Наименование, N)): обрезайте по символам целиком или уберите эмодзи из наименования.');
      }
    }
  }

  // E7 — ошибка со статусом 2xx: POS примет такой ответ за обычный (срез без строк, пустой список).
  if (ex.errorIn2xx) {
    add('E7', 'FAIL', 'error-200', `ошибка отдана со статусом ${st} (${String(ex.json.code).slice(0, 40)}) — нужен HTTP-код из приложения А.1 Требований (например, 404 для POS_E_NOT_FOUND): ответ ${st} POS примет за обычный`,
      'Ошибку возвращайте с HTTP-кодом из приложения А.1 Требований: Новый HTTPСервисОтвет(404) для POS_E_NOT_FOUND, 400 для POS_E_BAD_REQUEST, 422 для POS_E_VALIDATION…');
  }

  // E7–E9 — ошибки
  if (st >= 400) {
    if (ex.isPosError) {
      const b = ex.json;
      const code = b.code;
      if (!env.errorCodes.includes(code)) add('E7', 'FAIL', 'code-unknown', `код ошибки не из перечня ErrorCode: «${String(code).slice(0, 40)}»`);
      else {
        const allowed = STATUS_CODES[st];
        if (allowed && !allowed.includes(code)) add('E7', 'FAIL', 'code-status', `код не соответствует HTTP-статусу: ${st} с ${code} (по приложению А.1 Требований для ${st} — ${allowed.join(', ')})`);
        else if (!allowed) add('E7', 'WARN', 'status-unusual', `HTTP-статус ${st} не из приложения А.1 Требований`);
        if (op && op.errorCodes.length && !op.errorCodes.includes(code)) add('E7', 'WARN', 'code-not-op', `код ${code} не указан в x-error-codes метода ${op.method} ${op.path}`);
      }
      if (st === 423 && op && !['/pos/v1/orders', '/pos/v1/check'].includes(op.path)) add('E7', 'WARN', '423-other', `423 у ${op.path}: по контракту 423 — только у /orders и /check, у остальных методов блокировка — 503 POS_E_LOCKED`);
      if (typeof b.message !== 'string') add('E7', 'FAIL', 'no-message', 'в теле ошибки нет строки message');
      if (typeof b.requestId !== 'string') add('E7', 'FAIL', 'no-requestid', 'в теле ошибки нет requestId');
      if (b.details !== undefined && b.details !== null && (typeof b.details !== 'object' || Array.isArray(b.details))) add('E7', 'FAIL', 'details-type', 'details должен быть объектом');
      // E8 — текст
      const msg = typeof b.message === 'string' ? b.message : '';
      // Язык текста в контракте 1.2.0 и Требованиях не задан (message — «текст для журнала без ПДн», §4.6): текст
      // не по-русски — ЗАМЕЧАНИЕ, не ОШИБКА.
      if (typeof b.message === 'string') {
        if (!msg.trim()) add('E8', 'WARN', 'empty-msg', 'текст ошибки (message) пустой — в журнале POS не будет видно, что случилось (Требования §4.6: message — текст для журнала)');
        else if (!hasCyrillic(msg)) add('E8', 'WARN', 'not-ru', 'текст ошибки не по-русски — журнал POS разбирают сотрудники магазина и мы, удобнее русский текст (язык в Требованиях не задан, поэтому замечание)');
        else if (KY_LETTERS.test(msg)) add('E8', 'WARN', 'not-ru-ky', 'текст ошибки похож на кыргызский (буквы ң, ө, ү) — журнал POS разбирают по-русски; язык в Требованиях не задан, поэтому замечание. Проверьте язык пользователя pos_hs и НСтр()');
        if (/Ошибка при вызове метода контекста|\{[^{}]*\(\d+\)\}|ОбщийМодуль\.|Error calling context method|Ошибка выполнения запроса/.test(msg)) {
          add('E8', 'WARN', 'exception', 'текст ошибки похож на текст исключения 1С — нужен понятный бухгалтеру текст');
        }
        if (msg.length > 500) add('E8', 'WARN', 'long-msg', `текст ошибки длиннее 500 символов (${msg.length})`);
      }
      // E9 — ПДн
      const texts = [msg];
      for (const l of (b.details && Array.isArray(b.details.lines)) ? b.details.lines : []) if (l && typeof l.text === 'string') texts.push(l.text);
      for (const t of texts) {
        for (const kind of env.masker.findPii(t)) add('E9', 'FAIL', `pii-${kind}`, `в тексте ошибки ${kind} — персональные данные в message недопустимы (Требования §4.6, контракт Error.message)`);
        for (const kind of env.masker.maybePii(t)) add('E9', 'WARN', `maybe-${kind}`, `в тексте ошибки, ${kind} — проверьте: имён клиентов, телефонов, ИНН и адресов в message быть не должно (Требования §4.6)`);
        const sums = sumsIn(t);
        if (sums.debt) add('E9', 'FAIL', 'pii-debt-sum', 'в тексте ошибки сумма долга (рядом со словом «долг», «задолженность», «лимит»…) — суммы долга в message недопустимы (Требования §4.6, контракт: Error.message без сумм долга)');
        else if (sums.other) add('E9', 'WARN', 'sum', 'в тексте ошибки число, похожее на сумму — суммы долга в тексте не нужны');
      }
    } else if (ex.json && typeof ex.json === 'object') {
      add('E7', 'FAIL', 'bad-format', `тело ошибки не по формату {code, message, details?, requestId} (статус ${st})`);
    } else if (PLATFORM_STATUSES.has(st)) {
      add('E7', 'INFO', 'platform', `ответ ${st} без тела ошибки POS — допустимо только как ответ платформы (неверный пароль, неизвестный адрес, сбой до старта сеанса)`);
    } else {
      add('E7', 'FAIL', 'no-body', `ответ ${st} без тела ошибки в едином формате {code, message, requestId}`);
    }
  }

  // E11 — ошибка данных не 5xx
  if (spec.dataError && (st >= 500 || ex.posCode === 'POS_E_INTERNAL')) {
    add('E11', 'FAIL', 'data-500', `ошибка данных отдана как ${st}${ex.posCode ? ' ' + ex.posCode : ''} — нужен 400 или 422: POS будет повторять запрос, который всё равно не пройдёт (Требования §4.6 «Коды ошибок»)`);
  }

  // E12 — статус есть среди ответов операции
  if (op && !op.responses[String(st)] && !(spec.absentProbe && (st === 404 || st === 405)) && !(spec.allowStatuses || []).includes(st)) {
    add('E12', 'WARN', 'status-not-in-contract', `HTTP ${st} нет среди ответов ${op.method} ${op.path} в контракте (есть: ${Object.keys(op.responses).join(', ')})`);
  }
  return out;
}
