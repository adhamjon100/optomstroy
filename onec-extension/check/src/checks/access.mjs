// S — связь и защита канала; A — доступ; M2 — «нет доступа» с другого компьютера.
import dns from 'node:dns/promises';
import { AbortRun } from '../context.mjs';
import { explainNetError } from '../tls-explain.mjs';
import { netFailed, statusText, looksAbsent, rnd } from './common.mjs';
import { doubleEncoded } from '../rules.mjs';

const NO_KEY = 'без заголовка X-POS-Client-Key';
const WRONG_KEY = 'с неверным X-POS-Client-Key';
// Тело POST «без ключа»: неразбираемый JSON. Правильная 1С проверяет ключ до разбора и отвечает 401; 1С без проверки
// ключа споткнётся о разбор и ничего не создаст.
export const BROKEN_JSON = '{"externalId":';

const HEALTH = 'GET /pos/v1/health';
// Сбои, при которых TCP-соединения не было: это не сертификат и не TLS.
const NO_TCP = new Set(['ECONNREFUSED', 'ENOTFOUND', 'EAI_AGAIN', 'EHOSTUNREACH', 'ENETUNREACH']);
// Номер версии платформы 1С:Предприятие: 8.2.x.y, 8.3.25.1374, 8.5.1.100…
const PLATFORM_VERSION = /(?<![\d.])8\.[2-5]\.\d{1,2}\.\d{2,5}(?![\d.])/;

export async function runS1(ctx) {
  await ctx.run('S1', async (r) => {
    const b = ctx.http.base;
    r.evidence = { scheme: b.scheme, host: b.host, port: b.port };
    for (const n of b.notes) r.info(n, { code: 'url-note' });
    if (ctx.demo) {
      r.infoVerdict('ДЕМО: имитатор на этом компьютере по http://127.0.0.1 — у настоящей 1С нужен HTTPS');
      return;
    }
    if (b.scheme === 'http') {
      r.warn('HTTP без шифрования (--allow-http): по Требованиям §4.2 публикация — только по HTTPS, TLS 1.2 и выше', { code: 'http' });
    }
    if (!b.endsWithHs) r.warn(`путь публикации «${b.basePath || '/'}» не кончается на /hs — сегмент hs типовой (проверьте адрес)`, { code: 'no-hs' });
    r.pass(`${b.scheme}://${b.host}:${b.port}, публикация «${b.publication || '?'}»`);
  });
}

export async function runS2(ctx) {
  await ctx.run('S2', async (r) => {
    if (ctx.http.base.scheme !== 'https') {
      if (ctx.demo) r.infoVerdict('ДЕМО: имитатор без TLS');
      else r.skip('адрес http:// — TLS не используется (по Требованиям §4.2 нужен HTTPS)');
      return;
    }
    const res = await ctx.http.probeTls();
    const t = res.info;
    if (t) {
      r.evidence.tls = { protocol: t.protocol, subject: t.subject, issuer: t.issuer, validTo: t.validTo };
      ctx.data.tls = { ...t, verified: !!res.ok };
    }
    if (res.ok) {
      if (t.protocol && !/^TLSv1\.[23]$/.test(t.protocol)) r.fail(`протокол ${t.protocol} — нужен TLS 1.2 или новее`);
      const to = t.validTo ? Date.parse(t.validTo) : NaN;
      if (Number.isFinite(to)) {
        const days = Math.floor((to - Date.now()) / 86400000);
        if (days < 30) r.warn(`сертификат истекает через ${days} дн. (${t.validTo}) — замените заранее`, { code: 'expiring' });
      }
      if (ctx.flags.insecure) r.warn('указан --insecure, но сертификат и так проходит проверку — флаг не нужен', { code: 'insecure-needless' });
      r.pass(`${t.protocol}, сертификат проверен, действует до ${t.validTo}`);
      return;
    }
    const info = explainNetError(res.error, ctx.http.base);
    if (info.kind === 'tls' && ctx.flags.insecure) {
      r.warn(`СЕРТИФИКАТ НЕ ПРОВЕРЯЛСЯ (--insecure): ${info.text}`, { code: 'insecure' });
      ctx.data.tls = { ...(t || {}), verified: false };
      r.summary = 'проверка сертификата отключена флагом --insecure';
      return;
    }
    if (NO_TCP.has(info.code)) {
      // TCP-соединения нет вовсе (отказ, имя не найдено, сеть недоступна): до сертификата и TLS дело не дошло — S2 не
      // проверялась, причину показывает S3 («Публикация отвечает»), где тот же сбой связи останавливает прогон.
      // Тайм-аут и сброс соединения остаются здесь: сервер мог принять TCP и не завершить TLS.
      r.skip(`сертификат не проверен: соединение с публикацией не установлено (${info.code}) — причина в S3`);
      return;
    }
    r.fail(info.text, { code: info.code });
    throw new AbortRun(`нет защищённого соединения: ${info.text}`);
  });
}

/** S3 и A1 — один запрос /health; H1–H3 разбирают тот же ответ. */
export async function runS3A1(ctx) {
  let ex = null;
  await ctx.run('S3', async (r) => {
    ex = await r.call({ op: HEALTH, path: '/pos/v1/health', schemaRun: ctx.runObj('H1'), label: 'пользователь и ключ' });
    ctx.data.healthEx = ex;
    if (ex.error) {
      r.fail(ex.errorInfo.text, { code: ex.errorInfo.code });
      throw new AbortRun(`нет связи с публикацией: ${ex.errorInfo.text}`);
    }
    if (ex.status === 404 && !ex.isPosError) {
      r.fail('404 от веб-сервера: неверный адрес публикации или расширение не опубликовано (проверьте адрес до /hs и публикацию HTTP-сервисов расширения)', { code: '404' });
      throw new AbortRun('неверный адрес публикации (404)');
    }
    if (ex.status === 503 && ex.posCode === 'POS_E_MAINTENANCE') {
      r.fail('503 POS_E_MAINTENANCE: обмен приостановлен — выключите константу ОбменПриостановлен и запустите проверку снова', { code: 'maintenance' });
      throw new AbortRun('обмен приостановлен (503 POS_E_MAINTENANCE)');
    }
    r.pass(`публикация отвечает: HTTP ${ex.status} за ${Math.round(ex.ms)} мс`);
  });
  await ctx.run('A1', async (r) => {
    r.note(`тот же запрос, что в S3 (№${ex.n})`);
    if (ex.status === 200) {
      ctx.data.health = ex.json && typeof ex.json === 'object' ? ex.json : null;
      ctx.data.healthRequestId = ex.requestId;
      if (!ctx.data.health) {
        // Разный текст для трёх разных случаев: JSON-строка с JSON внутри (закодировано дважды), JSON не объект, не JSON.
        const twice = doubleEncoded(ex.json);
        const why = twice
          ? 'ответ 200 — JSON закодирован дважды: тело — строка, внутри которой JSON объекта Health (ЗаписатьJSON от готовой строки JSON); нужен сам объект'
          : ex.json !== undefined && !ex.jsonError
            ? `ответ 200 — JSON, но не объект (пришло: ${Array.isArray(ex.json) ? 'список' : ex.json === null ? 'null' : typeof ex.json === 'string' ? 'строка' : typeof ex.json === 'number' ? 'число' : 'true/false'}) — /health должен вернуть объект Health`
            : 'ответ 200 без JSON — /health должен вернуть объект Health';
        r.fail(why, { code: twice ? 'double-json' : 'not-object' });
        throw new AbortRun(twice ? '/health вернул JSON, закодированный дважды' : '/health вернул не объект JSON');
      }
      r.pass('200 с пользователем и ключом');
      return;
    }
    if (ex.status === 401 || ex.status === 403) {
      r.fail(`${statusText(ex)}: неверный пользователь, пароль или ключ клиента (или у пользователя нет роли POS_ИнтеграцияPOS)`, { code: 'auth' });
      throw new AbortRun(`нет доступа с этими пользователем и ключом (${ex.status})`);
    }
    r.fail(`/health ответил ${statusText(ex)} — нужен 200`, { code: 'status' });
    throw new AbortRun(`/health ответил ${statusText(ex)}`);
  });
}

function check401(r, ctx, ex, what, { requirePosBody }) {
  if (netFailed(r, ex, what)) return;
  ctx.data.unauth = ctx.data.unauth || [];
  if (ex.status === 401 || ex.status === 403) ctx.data.unauth.push({ checkId: r.id, text: ex.text || '', headers: ex.headers });
  if (ex.status >= 200 && ex.status < 300) {
    r.fail(`${what} — ответ ${ex.status} с данными: ключ не проверяется`, { code: 'accepted' });
    return;
  }
  if (ex.status !== 401) { r.fail(`${what} — нужен 401, пришёл ${statusText(ex)}`, { code: 'status' }); return; }
  if (requirePosBody) {
    if (!ex.isPosError) r.fail(`${what} — 401 без тела, нет тела ошибки POS_E_UNAUTHORIZED (отказ по ключу формирует код расширения, тело обязательно)`, { code: 'no-body' });
    else if (ex.posCode !== 'POS_E_UNAUTHORIZED') r.fail(`${what} — код ${ex.posCode}, нужен POS_E_UNAUTHORIZED`, { code: 'code' });
  }
}

export async function runA2toA5(ctx) {
  await ctx.run('A2', async (r) => {
    const ex = await r.call({ op: HEALTH, path: '/pos/v1/health', key: 'none', noSchema: false, label: NO_KEY });
    if (ex.status >= 200 && ex.status < 300) { r.fail(`${NO_KEY} ответ 200 — ключ клиента не проверяется`, { code: 'accepted' }); return; }
    check401(r, ctx, ex, NO_KEY, { requirePosBody: true });
    r.pass('401 POS_E_UNAUTHORIZED');
  });
  await ctx.run('A3', async (r) => {
    const ex = await r.call({ op: HEALTH, path: '/pos/v1/health', key: 'wrong', label: 'неверный ключ' });
    if (ex.status >= 200 && ex.status < 300) { r.fail('с неверным X-POS-Client-Key ответ 200 — ключ не сверяется', { code: 'accepted' }); return; }
    check401(r, ctx, ex, 'с неверным ключом', { requirePosBody: true });
    r.pass('401 POS_E_UNAUTHORIZED');
  });
  await ctx.run('A4', async (r) => {
    const what = ctx.settings.auth === 'bearer' ? 'неверный JWT' : 'неверный пароль';
    const ex = await r.call({ op: HEALTH, path: '/pos/v1/health', auth: 'wrong', label: `${what} (одна попытка)` });
    r.note('одна попытка — на случай блокировки пользователя после нескольких неудачных входов');
    if (ex.status >= 200 && ex.status < 300) { r.fail(`${what} принят — ответ ${ex.status}`, { code: 'accepted' }); return; }
    check401(r, ctx, ex, what, { requirePosBody: false });
    r.pass(`401${ex.isPosError ? ' ' + ex.posCode : ' (ответ платформы)'}`);
  });
  await ctx.run('A5', async (r) => {
    const ex = await r.call({ op: HEALTH, path: '/pos/v1/health', auth: 'none', label: 'без Authorization, с ключом' });
    if (ex.status >= 200 && ex.status < 300) { r.fail(`без Authorization ответ ${ex.status} — публикация доступна без пользователя`, { code: 'accepted' }); return; }
    check401(r, ctx, ex, 'без Authorization', { requirePosBody: false });
    r.pass('401');
  });
}

export async function runA8(ctx) {
  await ctx.run('A8', async (r) => {
    if (ctx.demo) { r.infoVerdict('ДЕМО: пароль и ключ созданы программой'); return; }
    const s = ctx.secrets;
    if (ctx.settings.auth === 'basic') {
      if ((s.password || '').length < 16) r.warn('пароль технического пользователя короче 16 символов — справочник §4.4 рекомендует длинный случайный пароль', { code: 'short' });
      if (s.password && s.password === s.clientKey) r.warn('ключ клиента совпадает с паролем — это должны быть разные секреты', { code: 'same' });
    } else if (s.token && s.token === s.clientKey) r.warn('ключ клиента совпадает с JWT', { code: 'same' });
    if ((s.clientKey || '').length < 16) r.warn('ключ клиента короче 16 символов', { code: 'short-key' });
    for (const w of s.warnings || []) r.warn(w, { code: 'nonascii' });
    r.pass('длина и различие проверены (значения в протокол не пишутся)');
  });
}

/** Пути «без ключа» для A6: GET — путь со случайным GUID; POST — неразбираемое тело (только с записью). */
function a6Targets(ctx) {
  const lastAck = ctx.data.health?.lastAckMessageNumber ?? 0;
  const list = [
    { op: 'GET /pos/v1/changes', path: '/pos/v1/changes', query: { since: lastAck, limit: 1 } },
    { op: 'GET /pos/v1/images/{ref}', path: `/pos/v1/images/${rnd()}`, presence: 'I3' },
    { op: 'GET /pos/v1/external-ids', path: '/pos/v1/external-ids', query: { limit: 1 } },
    { op: 'GET /pos/v1/customers/{ref}/receivables', path: `/pos/v1/customers/${rnd()}/receivables`, presence: 'K9' },
    { op: 'GET /pos/v1/customers', path: '/pos/v1/customers', query: { phone: '+996000000000' }, presence: 'K7' },
    { op: 'GET /pos/v1/orders/{uuid}/status', path: `/pos/v1/orders/${rnd()}/status`, presence: 'O0' },
    { op: 'GET /pos/v1/returns/{uuid}/status', path: `/pos/v1/returns/${rnd()}/status`, presence: 'R0' },
    { op: 'GET /pos/v1/payments/{externalId}/status', path: `/pos/v1/payments/${rnd()}/status`, presence: 'Q0' },
    { op: 'GET /pos/v1/catalog/{ref}', path: `/pos/v1/catalog/${rnd()}`, presence: 'CC1' },
  ];
  const post = [
    { op: 'POST /pos/v1/changes/ack', path: '/pos/v1/changes/ack' },
    // Перерегистрация без ключа — только если человек сам выбрал перерегистрацию (C6): тела у метода нет, и 1С без
    // проверки ключа выполнила бы полную перерегистрацию.
    ...(ctx.data.reregistered ? [{ op: 'POST /pos/v1/changes/reregister', path: '/pos/v1/changes/reregister' }] : []),
    { op: 'POST /pos/v1/customers', path: '/pos/v1/customers' },
    { op: 'POST /pos/v1/payments', path: '/pos/v1/payments' },
    { op: 'POST /pos/v1/orders', path: '/pos/v1/orders', presence: 'O0' },
    { op: 'POST /pos/v1/orders/status', path: '/pos/v1/orders/status', presence: 'O0' },
    { op: 'POST /pos/v1/orders/{uuid}/cancel', path: `/pos/v1/orders/${rnd()}/cancel`, presence: 'O0' },
    { op: 'POST /pos/v1/payments/qr', path: '/pos/v1/payments/qr', presence: 'Q0' },
    { op: 'POST /pos/v1/payments/{externalId}/qr/cancel', path: `/pos/v1/payments/${rnd()}/qr/cancel`, presence: 'Q0' },
    { op: 'POST /pos/v1/returns', path: '/pos/v1/returns', presence: 'R0' },
    { op: 'POST /pos/v1/check', path: '/pos/v1/check', presence: 'CK1' },
  ];
  return { get: list, post };
}

export async function runA6(ctx) {
  await ctx.run('A6', async (r) => {
    const { get, post } = a6Targets(ctx);
    const targets = [...get, ...(ctx.writeAllowed ? post : [])];
    if (!ctx.writeAllowed) r.note('POST-методы без ключа проверяются только с --allow-write (запрос POST)');
    else if (!ctx.data.reregistered) r.note('POST /changes/reregister без ключа не вызывался: перерегистрацию (C6) не выбирали');
    let checked = 0;
    const absent = [];
    // Каждый метод — дважды: без ключа и с неверным ключом (Требования §4.4 «Ключ клиента и вход» п. 3: «Запрос без
    // ключа или с неверным ключом → 401 POS_E_UNAUTHORIZED … даже при верном пароле»). Код, который проверяет только
    // «ключ заполнен», пропускает неверный ключ — это видно только по второму запросу.
    const MODES = [
      { key: 'none', label: NO_KEY, words: 'без ключа', prefix: '' },
      { key: 'wrong', label: WRONG_KEY, words: 'с неверным ключом', prefix: 'wrong-key-' },
    ];
    for (const t of targets) {
      if (t.presence && ctx.data.absent.has(t.presence)) { absent.push(t.op); continue; }
      const isPost = (t.method || t.op.split(' ')[0]) === 'POST';
      const isRereg = t.path === '/pos/v1/changes/reregister';
      const name = t.op || `${t.method} ${t.path}`;
      for (const m of MODES) {
        const ex = await r.call({
          op: t.op, method: t.method, path: t.path, query: t.query, key: m.key,
          rawBody: isPost && !isRereg ? BROKEN_JSON : undefined,
          noSchema: true, absentProbe: true, label: m.label,
        });
        if (netFailed(r, ex, `${name} (${m.words})`)) continue;
        ctx.data.unauth = ctx.data.unauth || [];
        if (ex.status === 401) ctx.data.unauth.push({ checkId: 'A6', text: ex.text || '', headers: ex.headers });
        if (m.key === 'none' && ex.status !== 401 && !(ex.status >= 200 && ex.status < 300) && looksAbsent(ctx, ex)) { absent.push(name); break; }
        if (m.key === 'none') checked++;
        if (ex.status >= 200 && ex.status < 300) {
          r.fail(`${name}: ${m.words} ответ ${ex.status} — ключ ${m.key === 'none' ? 'не проверяется' : 'не сверяется (проверено только, что заголовок заполнен?)'} в методе`, { code: m.prefix + 'accepted', where: `${name} (${m.words})` });
          if (isPost) noteWriteSideEffect(ctx, r, t, ex);
        } else if (ex.status === 403) {
          r.fail(`${name}: ${m.words} ${statusText(ex)} — нужен 401 POS_E_UNAUTHORIZED: 403 POS_E_FORBIDDEN — только пользователь без роли POS_ИнтеграцияPOS (Требования §4.4 п. 3, §8.4 «аутентификация»)`, { code: m.prefix + 'status', where: `${name} (${m.words})` });
        } else if (ex.status !== 401) {
          r.fail(`${name}: ${m.words} ${statusText(ex)} — ключ не проверяется в методе (нужен 401 POS_E_UNAUTHORIZED до разбора запроса; Требования §4.4 п. 3)`, { code: m.prefix + 'status', where: `${name} (${m.words})` });
        } else if (!ex.isPosError || ex.posCode !== 'POS_E_UNAUTHORIZED') {
          r.fail(`${name}: ${m.words} 401 без тела POS_E_UNAUTHORIZED`, { code: m.prefix + 'no-body', where: `${name} (${m.words})` });
        }
      }
    }
    r.evidence = { checked, absent, modes: MODES.map((m) => m.words) };
    if (absent.length) r.note(`не проверялись (метода нет): ${absent.join('; ')}`);
    r.pass(`проверено методов: ${checked} (без ключа и с неверным ключом)`);
  });
}

export async function runA7(ctx) {
  await ctx.run('A7', async (r) => {
    const list = ctx.data.unauth || [];
    const h = ctx.data.health || {};
    const values = ['apiVersion', 'extensionVersion', 'platform', 'configuration', 'configurationVersion']
      .map((k) => [k, h[k]]).filter(([k, v]) => typeof v === 'string' && v.length >= 3 && k !== 'apiVersion');
    let bad = 0;
    for (const u of list) {
      // Тело и заголовки ответа 401 (WWW-Authenticate realm, Server, X-Powered-By…): версии и имя конфигурации из
      // /health не должны быть видны без пароля (контракт GET /health, КП-1: «401 без сведений о системе»).
      const hdrs = Object.entries(u.headers || {}).map(([n, x]) => [n, Array.isArray(x) ? x.join(', ') : String(x ?? '')]);
      for (const [k, v] of values) {
        if (u.text.includes(v)) { r.fail(`в ответе 401 сведения о системе: ${k} (${u.checkId})`, { code: 'leak-' + k, where: u.checkId }); bad++; }
        const inHdr = hdrs.find(([, x]) => x.includes(v));
        if (inHdr) { r.fail(`в заголовке ${inHdr[0]} ответа 401 сведения о системе: ${k} (${u.checkId})`, { code: 'leak-header-' + k, where: u.checkId }); bad++; }
      }
      // Номер версии платформы 1С (8.3.x.y) в заголовке ответа без пароля — даже если /health показал другое значение.
      for (const [n, x] of hdrs) {
        if (PLATFORM_VERSION.test(x) && !values.some(([, v]) => x.includes(v))) {
          r.fail(`в заголовке ${n} ответа 401 номер версии платформы 1С (${u.checkId}) — без пароля сведений о системе быть не должно`, { code: 'leak-header-platform', where: u.checkId });
          bad++;
        }
      }
      if (/пользовател[ья] .*не найден|не найден пользовател|user .*not found|Неверное имя пользователя/i.test(u.text)) {
        r.fail(`в ответе 401 сведения о системе: текст выдаёт, что пользователя нет (${u.checkId})`, { code: 'leak-user', where: u.checkId });
        bad++;
      }
      const srv = u.headers?.server;
      if (srv && !PLATFORM_VERSION.test(String(srv)) && /1C|1С|Apache\/\d|IIS\/\d/i.test(srv)) r.info(`заголовок Server: «${String(srv).slice(0, 60)}» — сведения о веб-сервере (не ошибка)`, { code: 'server-header' });
    }
    if (!list.length) { r.skip('ответов 401 нет (A2–A6 не выполнялись)'); return; }
    r.pass(`ответов 401 проверено: ${list.length}${bad ? '' : ', сведений о системе нет'}`);
  });
}

/** Запрос записи, который не должен был ничего сделать, ответил 2xx: что могло измениться в 1С — в реестр протокола. */
export function noteWriteSideEffect(ctx, r, t, ex) {
  const path = t.path || '';
  if (path === '/pos/v1/changes/reregister') {
    ctx.registry.addPlan({ action: 'reregister', checkId: r.id, note: `${t.op || path} без ключа ответил ${ex.status} — 1С могла выполнить перерегистрацию` });
  } else if (path === '/pos/v1/changes/ack') {
    ctx.registry.addPlan({ action: 'ack', messageNumber: null, checkId: r.id, note: `${t.op || path} без ключа ответил ${ex.status} — 1С могла снять регистрации` });
  } else {
    ctx.registry.addSuspect({ checkId: r.id, what: `${t.op || `POST ${path}`}: ответ ${ex.status} на запрос, который ничего не должен был создать`, ref: ex.json?.ref ?? null });
  }
}

/** M2: запуск на ДРУГОМ компьютере; успех — отказ в доступе. Секреты не нужны. */
export async function runExpectNoAccess(ctx) {
  await ctx.run('M2', async (r) => {
    const b = ctx.http.base;
    // Имя должно найтись на этом компьютере: иначе ответ «нет связи» ничего не говорит об ограничении доступа.
    let ip = b.host;
    if (!/^[\d.]+$|:/.test(b.host)) {
      try { ip = (await dns.lookup(b.host)).address; } catch (e) {
        const code = e?.code || 'ENOTFOUND';
        r.skip(`проверка не выполнена: имя ${b.host} не найдено на этом компьютере (${code})`);
        throw new AbortRun(`проверка «нет доступа» не выполнена: имя ${b.host} не найдено на этом компьютере (${code}) — укажите тот же адрес, что работает на сервере POS, или IP-адрес публикации`);
      }
    }
    const where = `${ip}:${b.port}`;
    r.evidence = { host: b.host, ip, port: b.port };
    const ex = await r.call({ op: HEALTH, path: '/pos/v1/health', auth: 'none', key: 'none', noSchema: true, noRetry: true, label: `с этого компьютера (${where}), без пароля и ключа`, timeoutMs: 10000 });
    if (ex.error) {
      const code = ex.errorInfo?.code || '';
      if (['ECONNREFUSED', 'CONNECT_TIMEOUT', 'ETIMEDOUT', 'ECONNRESET'].includes(code)) {
        const how = code === 'ECONNREFUSED' ? 'отказ в соединении' : code === 'ECONNRESET' ? 'соединение сброшено' : 'соединение не установлено за отведённое время';
        r.pass(`доступа нет: ${where} — ${how} (${code})`);
        return;
      }
      if (['ENOTFOUND', 'EAI_AGAIN', 'EHOSTUNREACH', 'ENETUNREACH'].includes(code)) {
        r.skip(`проверка не выполнена: ${ex.errorInfo.text}`);
        throw new AbortRun(`проверка «нет доступа» не выполнена: ${ex.errorInfo.text} — запустите на компьютере в той же сети магазина, адрес — как на сервере POS (лучше IP)`);
      }
      r.fail(`с этого компьютера соединение с ${where} установлено, но ${ex.errorInfo.text} — порт публикации доступен (по Требованиям §4.2 доступ — только с адреса сервера POS)`, { code: 'reachable' });
      return;
    }
    if (ex.status === 403) { r.pass(`доступа нет: ${where} — 403 по адресу`); return; }
    r.fail(`публикация доступна с этого компьютера: ${where} → HTTP ${ex.status} (по Требованиям §4.2 доступ — только с адреса сервера POS)`, { code: 'reachable' });
  });
}
