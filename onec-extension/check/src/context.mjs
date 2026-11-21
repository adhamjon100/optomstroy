// Движок прогона: результаты проверок, обмены с автоматическим разбором (схема, правила E), находки.
import { parseExchange, crossRules } from './rules.mjs';
import { explainNetError } from './tls-explain.mjs';
import { maskQueryPhone, MASK_TEXT } from './mask.mjs';
import { CATALOG, CATALOG_BY_ID } from './checks/index.mjs';
import { CREATING_OPS } from './registry.mjs';
import { foreignPathsOf } from './schema.mjs';
import { sleep } from './util.mjs';

// Сетевые ошибки, которые повтор не исправит (сертификат, имя, размер, заголовок): GET с ними не повторяется.
const NOT_TRANSIENT_NET = new Set(['ENOTFOUND', 'BODY_TOO_LARGE', 'ERR_INVALID_URL', 'ERR_INVALID_CHAR', 'ERR_INVALID_HTTP_TOKEN',
  'ERR_HTTP_INVALID_HEADER_VALUE', 'EPROTO', 'ERR_SSL_WRONG_VERSION_NUMBER']);

/** Временная ошибка по правилу x-get-retry (сеть, таймаут, 5xx, POS_E_LOCKED, POS_E_MAINTENANCE) — текст, иначе null. */
export function transientReason(ex) {
  if (ex.error) {
    const c = String(ex.error.code || '');
    if (NOT_TRANSIENT_NET.has(c) || /CERT|TLS|SSL|SELF_SIGNED|HOSTNAME|ALTNAME/i.test(c) || ex.errorInfo?.kind === 'tls') return null;
    if (c === 'RESPONSE_TIMEOUT') return 'нет ответа за отведённое время';
    return `нет связи (${ex.errorInfo?.code || c || 'сеть'})`;
  }
  if (!ex.status) return null;
  if (ex.status >= 500) return `${ex.status}${ex.posCode ? ' ' + ex.posCode : ''}`;
  if (ex.posCode === 'POS_E_LOCKED' || ex.posCode === 'POS_E_MAINTENANCE') return `${ex.status} ${ex.posCode}`;
  return null;
}

export const SEVERITY_ORDER = { FAIL: 3, WARN: 2, INFO: 1 };
export const VERDICT_RU = {
  PASS: 'ПРОЙДЕНО', FAIL: 'ОШИБКА', WARN: 'ЗАМЕЧАНИЕ', SKIP: 'ПРОПУЩЕНО', MANUAL_YES: 'ВРУЧНУЮ: ДА',
  MANUAL_NO: 'ВРУЧНУЮ: НЕТ', ABSENT: 'МЕТОДА НЕТ', INFO: 'СВЕДЕНИЯ',
};
export const KIND_RU = { auto: 'АВТО', semi: 'ПОЛУАВТО', manual: 'ВРУЧНУЮ' };
// Ответ «нет» на шаг-действие («сделайте в 1С … и нажмите Enter»): шаг не сделан — спросить снова, не «сделано».
const NOT_DONE = new Set(['н', 'нет', 'n', 'no', 'ytn', 'y']);

export class AbortRun extends Error {
  constructor(reason, exitCode = 2) { super(reason); this.reason = reason; this.exitCode = exitCode; this.code = 'ABORT'; }
}

const MAX_GROUPS = 150;
const MAX_DETAILED_EXCHANGES = 12;
const BODY_LIMIT = 8 * 1024;

function pathPattern(p) {
  return String(p || '').replace(/\[\d+\]/g, '[*]');
}

export class CheckRun {
  constructor(def, ctx) {
    this.def = def;
    this.id = def.id;
    this.ctx = ctx;
    this.explicit = null;
    this.summary = '';
    this.groups = new Map();
    this.findings = [];
    this.findingsTruncated = 0;
    this.requests = [];
    this.exchanges = [];
    this.evidence = {};
    this.notes = [];
    this.manual = null;
    this.startedAt = null;
    this.ms = 0;
    this.done = false;
  }

  /** Находка: группировка по правилу, коду и шаблону пути (items[*].price). */
  add(severity, text, { rule = null, code = null, where = null, hint = null } = {}) {
    const key = `${severity}|${rule}|${code || text}|${pathPattern(where)}`;
    const g = this.groups.get(key);
    if (g) { g.count++; return g; }
    if (this.groups.size >= MAX_GROUPS) { this.findingsTruncated++; return null; }
    const f = { severity, rule, code, where, text, hint, count: 1 };
    this.groups.set(key, f);
    this.findings.push(f);
    return f;
  }

  fail(text, o) { return this.add('FAIL', text, o); }
  warn(text, o) { return this.add('WARN', text, o); }
  info(text, o) { return this.add('INFO', text, o); }
  note(text) { this.notes.push(text); }

  set(verdict, summary) { this.explicit = verdict; if (summary) this.summary = summary; return this; }
  pass(summary) { if (summary) this.passText = summary; return this; }

  /** Краткий итог для консоли и сводной таблицы. */
  get summaryLine() {
    const v = this.verdict;
    if (v === 'FAIL') {
      const f = this.findings.find((x) => x.severity === 'FAIL');
      const n = this.findings.filter((x) => x.severity === 'FAIL').reduce((a, x) => a + x.count, 0);
      return f ? f.text + (n > 1 ? ` (и ещё ${n - 1})` : '') : (this.summary || '');
    }
    if (v === 'WARN' && !this.summary && !this.passText) {
      const f = this.findings.find((x) => x.severity === 'WARN');
      return f ? f.text : '';
    }
    return this.summary || this.passText || '';
  }
  skip(reason) { return this.set('SKIP', reason); }
  absent(text) { return this.set('ABSENT', text); }
  infoVerdict(text) { return this.set('INFO', text); }

  worst() {
    let w = 0;
    for (const f of this.findings) w = Math.max(w, SEVERITY_ORDER[f.severity] || 0);
    return w;
  }

  get verdict() {
    const w = this.worst();
    const e = this.explicit;
    if (e === 'SKIP' || e === 'ABSENT' || e === 'MANUAL_YES' || e === 'MANUAL_NO') {
      return w === 3 ? 'FAIL' : e;
    }
    if (w === 3) return 'FAIL';
    if (w === 2) return 'WARN';
    if (e === 'INFO') return 'INFO';
    return 'PASS';
  }

  call(spec) {
    return this.ctx.exchange(this, spec);
  }
}

export class RunContext {
  constructor(o) {
    Object.assign(this, o);
    this.runs = new Map();
    this.order = [];
    this.reqN = 0;
    this.responses = 0;
    this.timings = new Map();
    this.data = { names: new Set(), absent: new Set(), present: new Set() };
    this.aborted = null;
    this.selected = null;
    this.writeAllowed = false;
    this.writeConfirmed = false;
    this.writeRefusedReason = null;
    this.banners = [];
    for (const d of CATALOG) if (d.group === 'E') this.#ensureRun(d.id);
  }

  #ensureRun(id) {
    let r = this.runs.get(id);
    if (!r) {
      const def = CATALOG_BY_ID.get(id);
      if (!def) throw new Error(`Нет проверки ${id} в каталоге`);
      r = new CheckRun(def, this);
      this.runs.set(id, r);
    }
    return r;
  }

  get(id) { return this.runs.get(id) || null; }

  /** Объект проверки до её запуска (например, H1 — для находок схемы из запроса S3). */
  runObj(id) { return this.#ensureRun(id); }

  isSelected(id) {
    return !this.selected || this.selected.has(id);
  }

  /** Сквозная находка (правила E). */
  cross(rule, severity, text, { code = null, where = null, hint = null } = {}) {
    const r = this.#ensureRun(rule);
    r.add(severity, text, { rule, code, where, hint });
    r.evidence.violations = (r.evidence.violations || 0) + (severity === 'FAIL' || severity === 'WARN' ? 1 : 0);
  }

  /**
   * Запуск проверки: учитывает выбор --checks, запрет записи, ошибки реализации.
   * @param {string} id
   * @param {(run: CheckRun) => Promise<void>} impl
   */
  async run(id, impl) {
    if (!this.isSelected(id)) return null;
    const r = this.#ensureRun(id);
    if (r.done) return r;
    this.order.push(id);
    r.startedAt = Date.now();
    this.current = r;
    try {
      if (r.def.write && !this.writeAllowed) {
        r.skip(this.writeRefusedReason || 'запись не разрешена: запустите с --allow-write (Proverka_API_1C_zapis.cmd)');
      } else {
        await impl(r);
      }
    } catch (e) {
      if (e && (e.code === 'ABORT' || e.code === 'CANCELLED')) {
        r.ms = Date.now() - r.startedAt;
        r.done = true;
        // Проверка не закончена: без своей ОШИБКИ и без явного результата — ПРОПУЩЕНО, не ПРОЙДЕНО.
        const why = e.code === 'CANCELLED' ? 'прервано пользователем' : (e.reason || e.message);
        if (!r.explicit && r.worst() < 3) r.skip(`не завершена: ${why}`);
        else if (!r.summary && !r.findings.length) r.summary = why;
        this.#printLine(r);
        throw e;
      }
      r.fail(`сбой программы при проверке: ${e && e.message ? e.message : String(e)}`, { code: 'internal' });
      if (this.out.verbose && e && e.stack) this.out.debug(String(e.stack).split('\n').slice(0, 4).join(' | '));
    }
    r.ms = Date.now() - r.startedAt;
    r.done = true;
    this.#printLine(r);
    return r;
  }

  #printLine(r) {
    const v = VERDICT_RU[r.verdict];
    const line = r.summaryLine;
    const s = line ? ` — ${line}` : '';
    this.out.say(`[${r.id}] ${r.def.title}: ${v}${s}`);
    if (r.verdict === 'FAIL' || this.out.verbose) {
      for (const f of r.findings.filter((x) => x.severity === 'FAIL' || this.out.verbose).slice(r.verdict === 'FAIL' ? 1 : 0, 5)) {
        this.out.say(`      ${f.severity === 'FAIL' ? 'ошибка' : f.severity === 'WARN' ? 'замечание' : 'сведения'}: ${f.text}${f.count > 1 ? ` (×${f.count})` : ''}`);
      }
    }
  }

  /** Пропуск без запуска (зависимость не выполнена и т. п.). */
  async skip(id, reason) {
    return this.run(id, async (r) => { r.skip(reason); });
  }

  timeoutFor(spec, op) {
    if (spec.timeoutMs) return spec.timeoutMs;
    if (op) return op.timeoutMs;
    return this.contract.defaultTimeoutMs;
  }

  /**
   * Обмен с 1С. GET при временной ошибке повторяется так же, как это делает POS (контракт 1.2.0, info.x-get-retry:
   * «только GET и только при временной ошибке (сеть, таймаут, 5xx, POS_E_LOCKED, POS_E_MAINTENANCE) — до 3 попыток
   * с паузами 0,5 и 1 с»): каждая попытка — отдельный запрос в протоколе, повтор — СВЕДЕНИЯ, ответ только с последней
   * попытки — ЗАМЕЧАНИЕ; проверка видит последний ответ. Без повтора — запросы, где ошибка ожидается нарочно
   * (spec.noRetry: M1, M2, C5, K9, I3, обнаружение методов; ошибка данных; неверный или пустой пароль/ключ).
   */
  async exchange(run, spec) {
    const method = spec.method || (spec.op ? this.contract.op(spec.op).method : 'GET');
    const rt = this.contract.getRetry;
    const deliberate = spec.noRetry || spec.dataError || (spec.auth && spec.auth !== 'normal') || (spec.key && spec.key !== 'normal');
    if (method !== 'GET' || deliberate || !rt || !(rt.maxAttempts > 1)) return this.#exchangeOnce(run, spec);
    const max = rt.maxAttempts;
    const seen = [];
    for (let attempt = 1; ; attempt++) {
      const label = attempt === 1 ? spec.label : `${spec.label || 'запрос'} — повтор ${attempt} из ${max}`;
      const ex = await this.#exchangeOnce(run, attempt === 1 ? spec : { ...spec, label });
      ex.attempt = attempt;
      const why = transientReason(ex);
      const where = `${run.id}: GET ${maskQueryPhone(ex.path)}`;
      const was = () => seen.join('; ');
      if (!why) {
        if (attempt === max) {
          run.warn(`ответ получен только с последней, ${max}-й попытки (до этого: ${was()}) — у POS запаса нет: ещё одна временная ошибка, и чтение не удастся; проверьте блокировки и загрузку 1С`, { code: 'get-retry-last', where });
        } else if (attempt > 1) {
          run.info(`временная ошибка (${was()}) — ответ получен с ${attempt}-й попытки; POS повторяет GET так же (x-get-retry: до ${max} попыток)`, { code: 'get-retry', where });
        }
        return ex;
      }
      seen.push(why);
      if (attempt >= max) {
        run.info(`временная ошибка во всех ${max} попытках (${was()}) — как и у POS, чтение не удалось`, { code: 'get-retry-failed', where });
        return ex;
      }
      const d = rt.delaysMs[Math.min(attempt - 1, rt.delaysMs.length - 1)] ?? 1000;
      if (this.out.verbose) this.out.debug(`временная ошибка (${why}) — повтор через ${(d / 1000).toLocaleString('ru-RU')} с`);
      await sleep(Math.max(10, Math.round(d * (this.flags?.timeoutScale ?? 1))));
    }
  }

  /** Одна попытка: запрос, разбор, правила E, схема ответа; запись в протокол. */
  async #exchangeOnce(run, spec) {
    const op = spec.op ? this.contract.op(spec.op) : null;
    const method = spec.method || op?.method || 'GET';
    const timeoutMs = this.timeoutFor({ ...spec, method }, op);
    // Запрос, который может создать объект: в реестр ДО отправки (обрыв, таймаут, Ctrl+C — объект всё равно в протоколе).
    const kind = op && CREATING_OPS[op.key];
    const pending = kind && spec.body && typeof spec.body === 'object' && typeof spec.body.externalId === 'string'
      ? this.registry.addPending({ kind, externalId: spec.body.externalId, checkId: run.id }) : null;
    let rec;
    try {
      rec = await this.http.request({
        method, path: spec.path, query: spec.query, body: spec.body !== undefined ? spec.body : spec.rawBody,
        headers: spec.headers || {}, auth: spec.auth || 'normal', key: spec.key || 'normal', timeoutMs,
        maxBytes: spec.image ? 32 * 1024 * 1024 : 64 * 1024 * 1024,
      });
    } catch (e) {
      if (pending) this.registry.settlePending(pending, 'rejected');
      // Заголовок не отправить (например, ключ с русскими буквами): это настройки, а не ошибка 1С — код 2.
      if (e && (e.code === 'ERR_INVALID_CHAR' || e.code === 'ERR_INVALID_HTTP_TOKEN' || e.code === 'ERR_HTTP_INVALID_HEADER_VALUE')) {
        throw new AbortRun('пароль, ключ клиента или JWT содержит недопустимые для заголовка символы (русские буквы, пробелы?) — проверьте раскладку клавиатуры при вводе');
      }
      throw e;
    }
    const ex = { n: ++this.reqN, checkId: run.id, op, ...rec, isBinary: !!spec.image };
    parseExchange(ex);
    if (ex.error) ex.errorInfo = explainNetError(ex.error, this.http.base);
    else if (ex.status) this.responses++;
    if (pending) {
      const j = ex.json && typeof ex.json === 'object' ? ex.json : {};
      const outcome = ex.error ? 'unknown' : (ex.status >= 200 && ex.status < 300 ? 'created' : 'rejected');
      this.registry.settlePending(pending, outcome, { ref: j.ref ?? null, number: j.number ?? j.code ?? j.reference ?? null, date: j.date ?? null });
    }
    // правила E
    const findings = crossRules(ex, op, spec, { masker: this.masker, errorCodes: this.contract.errorCodes });
    const shownPath = maskQueryPhone(ex.path);
    const whereBase = `${run.id}: ${method} ${shownPath}${ex.status ? ' → ' + ex.status : ''}`;
    for (const f of findings) this.cross(f.rule, f.severity, f.text, { code: f.code, where: whereBase, hint: f.hint });
    ex.cross = findings;
    // схема ответа 2xx и тела ошибки
    if (!spec.noSchema && op && ex.status && ex.json !== undefined && !ex.jsonError) {
      let schema = null;
      if (ex.status >= 200 && ex.status < 300) schema = this.contract.responseSchema(op, ex.status);
      else if (ex.isPosError) schema = { $ref: '#/components/schemas/Error' };
      if (schema) {
        const target = spec.schemaRun || run;
        const { errors, truncated } = this.validator.validate(ex.json, schema);
        for (const e of errors) {
          if (e.rule === 'E4' || e.rule === 'E5' || e.rule === 'E6') {
            this.cross(e.rule, e.severity, e.text, { code: e.code, where: `${whereBase}, поле ${pathPattern(e.path)}`, hint: e.hint });
            target.add('INFO', `нарушение формата — см. ${e.rule}: ${e.text}`, { rule: e.rule, code: 'see-' + e.code, where: e.path });
          } else {
            target.add(e.severity, e.text, { rule: e.rule === 'SCHEMA' ? 'К' : e.rule, code: e.code, where: e.path, hint: e.hint });
          }
        }
        if (truncated) target.findingsTruncated += truncated;
        else ex.foreignPaths = foreignPathsOf(errors);
        ex.schemaOk = !errors.some((e) => e.severity === 'FAIL');
      }
    }
    // 2xx, где по контракту JSON, а тело не разобрано (оборвано, HTML, пусто): без этой находки проверка, читающая
    // `ex.json || {}`, показала бы ПРОЙДЕНО с пустыми значениями.
    if (!spec.noSchema && !spec.image && op && ex.status >= 200 && ex.status < 300 && (ex.json === undefined || ex.jsonError)
      && this.contract.responseSchema(op, ex.status)) {
      (spec.schemaRun || run).add('FAIL', `ответ ${ex.status} не JSON — POS не сможет его разобрать (подробно — правило E3)`, { rule: 'E3', code: 'not-json-2xx' });
      ex.schemaOk = false;
    }
    // имена клиентов — в маску (для E9 и протокола)
    if (ex.json && typeof ex.json === 'object' && ex.status < 400) this.masker.collectNames(ex.json);
    // время
    const tkey = op ? op.key : `${method} ${spec.path}`;
    if (!ex.error) {
      if (!this.timings.has(tkey)) this.timings.set(tkey, { ms: [], timeoutMs });
      this.timings.get(tkey).ms.push(ex.ms);
    }
    // запись в протокол
    const light = {
      n: ex.n, method, path: shownPath, status: ex.status, ms: Math.round(ex.ms), timeoutMs, requestId: ex.requestId,
      label: spec.label || null, error: ex.errorInfo ? ex.errorInfo.text : null,
    };
    run.requests.push(light);
    if (run.exchanges.length < MAX_DETAILED_EXCHANGES) run.exchanges.push(this.#detail(ex, spec, light));
    if (this.out.verbose) this.out.debug(`${method} ${shownPath} → ${ex.status ?? ex.errorInfo?.code} за ${Math.round(ex.ms)} мс`);
    return ex;
  }

  #detail(ex, spec, light) {
    const mode = 'known';
    let reqBody = null;
    if (ex.reqBody != null) {
      try { reqBody = JSON.stringify(this.masker.maskJson(JSON.parse(ex.reqBody), { mode: 'known' }), null, 2); } catch { reqBody = this.masker.maskText(ex.reqBody); }
      reqBody = cut(reqBody, BODY_LIMIT);
    }
    let resBody = null;
    if (ex.status) {
      if (spec.image && ex.status === 200) resBody = `(файл, ${ex.size} байт)`;
      else if (ex.json !== undefined && !ex.jsonError) {
        let j = this.masker.maskJson(ex.json, { mode, foreignPaths: this.#foreignPaths(ex) });
        if (j && typeof j === 'object' && Array.isArray(j.items) && (j.items.length > 6)) j = summarizeItems(j);
        resBody = cut(JSON.stringify(j, null, 2), BODY_LIMIT);
      } else if (ex.size) {
        resBody = this.#bodySummary(ex);
      } else resBody = '(пустое тело)';
    }
    const pick = ['x-pos-api-version', 'x-request-id', 'content-type', 'content-length', 'etag', 'www-authenticate'];
    const resHeaders = {};
    for (const h of pick) if (ex.headers[h] !== undefined) resHeaders[h] = String(ex.headers[h]).slice(0, 200);
    return { ...light, reqHeaders: ex.reqHeaders, reqBody, resHeaders, resBody, bom: ex.bom || false };
  }

  /**
   * Поля ответа, которых нет в контракте 1.2.0 (их значения в протокол идут скрытыми): из разбора схемы, а если его не
   * было (noSchema, предел находок) — отдельным разбором без предела. Тело ошибки — по схеме Error, и тело не в формате
   * POS ({error: …}) тоже: всё, чего нет в Error, скрыто.
   */
  #foreignPaths(ex) {
    if (ex.foreignPaths) return ex.foreignPaths;
    const op = ex.op;
    if (!ex.status || ex.json === undefined || ex.jsonError || !ex.json || typeof ex.json !== 'object') return null;
    let schema = null;
    if (ex.status >= 200 && ex.status < 300) schema = op ? this.contract.responseSchema(op, ex.status) : null;
    else if (ex.status >= 400 && !Array.isArray(ex.json)) schema = { $ref: '#/components/schemas/Error' };
    if (!schema) return null;
    try { ex.foreignPaths = this.validator.foreignPaths(ex.json, schema); } catch { ex.foreignPaths = null; }
    return ex.foreignPaths;
  }

  /**
   * Тело, которое не разобрано как JSON: сырой текст в протокол не идёт (в нём могут быть имена и адреса клиентов,
   * которых маска ещё не знает). Пишутся размер, Content-Type, место ошибки разбора, для HTML — заголовок <title>,
   * для похожего на JSON — «скелет»: ключи, скобки и числа, строки-значения заменены на [текст скрыт].
   */
  #bodySummary(ex) {
    const ct = String(ex.contentType || 'нет').slice(0, 80);
    if (!ex.utf8ok) return `(не UTF-8, ${ex.size} байт, Content-Type: ${ct})`;
    const text = ex.text || '';
    if (/html/i.test(ct) || /^\s*</.test(text)) {
      const t = /<title[^>]*>([\s\S]{0,300}?)<\/title>/i.exec(text);
      const title = t ? this.masker.maskText(t[1].replace(/\s+/g, ' ').trim()).slice(0, 160) : null;
      return `(HTML-страница, ${ex.size} байт, Content-Type: ${ct}${title ? `, заголовок «${title}»` : ''}; текст страницы в протокол не пишется)`;
    }
    const head = `(не JSON: ${ex.size} байт, Content-Type: ${ct}${ex.jsonError ? `, ошибка разбора: ${ex.jsonError}` : ''}; текст в протокол не пишется — ниже скелет: ключи, скобки и числа)`;
    if (!/^\s*[[{]/.test(text)) return head;
    return `${head}\n${cut(jsonSkeleton(text, this.masker), 2048)}`;
  }

  // ---------------------------------------------------------------- ручные шаги

  get manualAllowed() {
    return !this.flags.noManual && this.prompter.interactive;
  }

  /** Вопрос «да / нет / пропустить». Enter без ответа — «пропустить» (не «нет»): пустой ответ не записывается ошибкой. */
  async askYesNo(run, question, { def = 's', allowSkip = true } = {}) {
    if (!this.manualAllowed) return null;
    const t0 = Date.now();
    const a = await this.prompter.yesNo(question, { def, allowSkip });
    run.manual = { question, answer: a === 'y' ? 'да' : a === 'n' ? 'нет' : a === 's' ? 'пропустить' : 'нет ответа', at: new Date(), ms: Date.now() - t0 };
    return a;
  }

  /**
   * «Сделайте в 1С … и нажмите Enter». Возвращает 'done' (Enter или другой ответ, кроме «нет» и «пропустить»),
   * 'skip' («п», «пропустить»), 'refused' (три раза «нет» — шаг не сделан) или null (нет консоли, конец ввода).
   * «н», «нет», «n» — не «сделано»: человек отвечает, что шаг не выполнен, — программа спрашивает снова.
   */
  async waitEnter(run, text, { allowSkip = true } = {}) {
    if (!this.manualAllowed) return null;
    for (let i = 0; i < 3; i++) {
      const again = i > 0 ? 'Шаг не выполнен? Сделайте его в 1С и нажмите Enter' + (allowSkip ? ' (или «п» — пропустить шаг)' : '') + '. ' : '';
      const a = await this.prompter.line(again + (allowSkip
        ? `${text} — нажмите Enter (или введите «п» и Enter, чтобы пропустить): `
        : `${text} — нажмите Enter: `));
      if (a === null) return null;
      const t = a.trim().toLowerCase();
      if (allowSkip && ['п', 'пропустить', 's', 'skip', 'g'].includes(t)) return 'skip';
      if (NOT_DONE.has(t)) continue;
      return 'done';
    }
    return 'refused';
  }
}

function cut(s, n) {
  if (s == null) return s;
  const b = Buffer.from(s, 'utf8');
  if (b.length <= n) return s;
  return b.subarray(0, n).toString('utf8').replace(/�$/, '') + `\n… ещё ${b.length - n} байт`;
}

/**
 * Скелет тела, похожего на JSON, но не разобранного: ключи (латиница), скобки, запятые, true/false/null и числа
 * (длинные — через маску: телефон или ИНН числом); строки-значения и прочий текст — скрыты.
 */
export function jsonSkeleton(text, masker) {
  const out = [];
  const n = Math.min(text.length, 64 * 1024);
  let i = 0;
  while (i < n) {
    const c = text[i];
    if ('{}[],:'.includes(c)) { out.push(c === ',' ? ', ' : c === ':' ? ': ' : c); i++; continue; }
    if (c === ' ' || c === '\t' || c === '\r' || c === '\n') { i++; continue; }
    if (c === '"') {
      let j = i + 1;
      while (j < n && text[j] !== '"' && text[j] !== '\n') { if (text[j] === '\\') j++; j++; }
      const raw = text.slice(i + 1, j);
      let k = j + 1;
      while (k < n && /\s/.test(text[k])) k++;
      const isKey = text[k] === ':';
      // ключ латиницей, GUID и дата — не ПДн, остаются (по ним видно, где сломан JSON); прочие строки скрыты.
      const keep = isKey ? /^[A-Za-z_][A-Za-z0-9_]{0,60}$/.test(raw)
        : /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(raw) || /^\d{4}-\d{2}-\d{2}(T[\d:.]+([+-]\d{2}:\d{2}|Z)?)?$/.test(raw);
      out.push(keep ? `"${raw}"` : `"${MASK_TEXT}"`);
      i = j + 1;
      continue;
    }
    const m = /^(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null)(?![A-Za-zА-Яа-яЁё0-9_])/.exec(text.slice(i, i + 64));
    if (m) { out.push(m[1].length > 6 ? masker.maskText(m[1]) : m[1]); i += m[1].length; continue; }
    // прочий текст (имя без кавычек, обрывок) — скрыт целиком
    let j = i;
    while (j < n && !'{}[],:"'.includes(text[j])) j++;
    out.push('…');
    i = j;
  }
  if (text.length > n) out.push(' …');
  return out.join('');
}

/** Для /changes: первые 2 элемента каждого типа и счётчики, не страница целиком. */
function summarizeItems(j) {
  const byType = new Map();
  for (const it of j.items) {
    const t = (it && it.type) || (it && it.objectType) || '?';
    if (!byType.has(t)) byType.set(t, []);
    byType.get(t).push(it);
  }
  const items = [];
  const counts = {};
  for (const [t, arr] of byType) { counts[t] = arr.length; items.push(...arr.slice(0, 2)); }
  return { ...j, items, '…': `в протоколе — первые 2 элемента каждого типа из ${j.items.length}`, счётчики: counts };
}
