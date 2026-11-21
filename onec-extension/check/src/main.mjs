// Программа проверки API 1С (расширение OptomstroyPOS): точка входа, порядок прогона, коды выхода,
// Ctrl+C и аварийный протокол. Запуск: Proverka_API_1C.cmd [флаги] или node main.mjs [флаги].
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { parseCli, helpText } from './cli.mjs';
import { loadContract, PROGRAM_DIR } from './contract.mjs';
import { Validator } from './schema.mjs';
import { Redactor, Masker } from './mask.mjs';
import { createConsole } from './console.mjs';
import { Prompter } from './prompt.mjs';
import { loadSettings, saveSettings, wizard, defaultSettings } from './settings.mjs';
import { obtainSecrets, SettingsError } from './secrets.mjs';
import { HttpClient, parseBaseUrl } from './http.mjs';
import { RunContext, VERDICT_RU } from './context.mjs';
import { Registry } from './registry.mjs';
import { Synth } from './synth.mjs';
import { CATALOG, GROUPS, resolveSelection } from './checks/index.mjs';
import { DEFECT_IDS } from './mock/defects.mjs';
import { buildModel } from './report/model.mjs';
import { writeProtocol } from './report/json.mjs';
import { TOOL_VERSION, stripQuotes } from './util.mjs';
import { runS1, runS2, runS3A1, runA2toA5, runA6, runA7, runA8, runExpectNoAccess } from './checks/access.mjs';
import { runHealth } from './checks/health.mjs';
import { runChangesRead, runChangesWrite, runC14 } from './checks/changes.mjs';
import { runImages } from './checks/images.mjs';
import { runExternalIdsRead, runX4, runX5 } from './checks/external-ids.mjs';
import { runCustomersRead, runCustomersWrite } from './checks/customers.mjs';
import { runPayments } from './checks/payments.mjs';
import { runOrdersRead, runOrdersWrite } from './checks/orders.mjs';
import { runReturnsRead, runReturnsWrite } from './checks/returns.mjs';
import { runQrRead, runQrWrite } from './checks/qr.mjs';
import { runCatalogRead, runCheckCart } from './checks/check-cart.mjs';
import { runManual } from './checks/manual.mjs';
import { finalizeCross, runTimings } from './checks/cross.mjs';

const ROOT_DIR = path.resolve(PROGRAM_DIR, '..');
let live = null; // для Ctrl+C и аварийного протокола

function printCatalog(say) {
  let g = null;
  for (const d of CATALOG) {
    if (d.group !== g) { g = d.group; say(`\n${g} — ${GROUPS[g]}`); }
    say(`  ${d.id.padEnd(5)} ${d.write ? 'W' : 'R'}  ${d.title}`);
  }
}

async function confirmWrite(ctx) {
  const b = ctx.http.base;
  const h = ctx.data.health || {};
  const pub = b.publication;
  const lines = [
    'ВНИМАНИЕ: проверка записи создаст в базе тестовые объекты «ПРОВЕРКА POS» (клиенты, оплата 1.00 KGS',
    'непроведённая, заказ 1.00 KGS с отменой; пробный QR — только после отдельного вопроса) и подтвердит (ack)',
    'сообщения плана обмена «POS».',
    'Если к этой копии подключена тестовая система POS, подтверждённые изменения она не получит.',
    'Делайте это только на ТЕСТОВОЙ КОПИИ базы.',
    `Сервер: ${b.host}   Публикация: ${pub || '—'}   Конфигурация: ${h.configuration || '?'} ${h.configurationVersion || ''}`,
  ];
  // Оплаты и заявка на возврат — по тестовому клиенту «ПРОВЕРКА POS» (K1); другой клиент — только из настроек, и он назван.
  const own = ctx.settings.refs?.customerRef;
  if (own) {
    const p = (ctx.data.message?.items || []).find((i) => i.type === 'Catalog_Партнеры' && i.ref === own);
    lines.push(`Если тестовый клиент не создастся, оплаты 1.00 KGS будут привязаны к клиенту из настроек: ref ${own}${p?.code ? `, код ${p.code}` : ''}.`);
  } else lines.push('Оплаты 1.00 KGS привязываются только к тестовому клиенту «ПРОВЕРКА POS»; клиентов базы программа не трогает.');
  ctx.out.say('');
  for (const l of lines) ctx.out.say(l);
  if (pub && !/test|тест|copy|копи|dev/i.test(pub)) ctx.out.say('Имя публикации не похоже на тестовую копию — проверьте.');
  const expected = pub || 'ДА';
  const a = await ctx.prompter.line(`Чтобы продолжить, введите ${pub ? `имя публикации (${pub})` : '«ДА»'}; другой ответ — отмена: `);
  if (a !== null && a.trim() === expected) return true;
  ctx.writeRefusedReason = a === null ? 'запись не подтверждена: нет ввода (запуск без консоли)' : 'запись не подтверждена: введено не то имя';
  ctx.out.say('Запись отменена: проверки записи будут пропущены, чтение продолжается.');
  return false;
}

async function main(argv) {
  const redactor = new Redactor();
  const masker = new Masker({ redactor });
  let flags;
  const early = createConsole({ redactor, masker });
  try { flags = parseCli(argv); } catch (e) { early.say(`Ошибка: ${e.message}`); return 2; }
  if (flags.help) { early.raw(helpText()); return 0; }
  let contract;
  try { contract = loadContract(); } catch (e) { early.say(`Ошибка: не загружен контракт программы (${e.message}) — переустановите программу из архива`); return 2; }
  if (flags.version) {
    early.say(`Проверка API 1С ${TOOL_VERSION}; программа sha256 ${contract.meta.programSha256}${contract.meta.programModified ? ' (ФАЙЛЫ ПРОГРАММЫ ИЗМЕНЕНЫ после сборки)' : ''}; контракт onec-http-service ${contract.version}; sha256 YAML ${contract.meta.yamlSha256}${contract.meta.jsonSha256 ? `; JSON ${contract.meta.jsonSha256}` : ''}; git blob ${contract.meta.gitBlob}; Node.js ${process.version}`);
    return 0;
  }
  if (flags.list) { early.say('Каталог проверок (R — чтение, W — запись):'); printCatalog(early.say); return 0; }
  if (flags.demoDefect && !flags.demo) { early.say('Ошибка: --demo-defect только вместе с --demo'); return 2; }
  if (flags.demoDefect && !DEFECT_IDS.has(flags.demoDefect.toUpperCase())) { early.say(`Ошибка: неизвестный дефект ${flags.demoDefect}`); return 2; }
  if (flags.demoDefect) flags.demoDefect = flags.demoDefect.toUpperCase();
  const sel = resolveSelection(flags.checks);
  if (sel && sel.unknown.length) { early.say(`Ошибка: неизвестные проверки или группы: ${sel.unknown.join(', ')} (список: --list)`); return 2; }

  const out = createConsole({ redactor, masker, verbose: flags.verbose });
  const prompter = new Prompter({ write: (s) => out.raw(s) });
  const startedAt = new Date();
  out.say(`Проверка API 1С (расширение OptomstroyPOS) ${TOOL_VERSION} — контракт ${contract.version}, «Требования к API 1С» 1.2.1; сборка ${contract.meta.programSha256.slice(0, 12)}`);
  if (contract.meta.programModified) out.say('Внимание: файлы программы изменены после сборки — для сдачи используйте программу из архива как есть.');

  // ---------------------------------------------------------------- настройки и секреты
  let settings, demo = null, secrets = null;
  const settingsFile = flags.config ? path.resolve(flags.config) : path.join(ROOT_DIR, 'nastrojki.json');
  const settingsDir = path.dirname(settingsFile);
  let wizardUsed = false;
  try {
    if (flags.demo) {
      const password = crypto.randomBytes(18).toString('base64url');
      const clientKey = crypto.randomBytes(24).toString('base64url');
      const { startMock } = await import('./mock/server.mjs');
      demo = await startMock({ samplesDir: contract.paths.samples, defect: flags.demoDefect, password, clientKey });
      settings = defaultSettings();
      settings.baseUrl = demo.baseUrl;
      secrets = { password, clientKey, sources: { password: 'демо', clientKey: 'демо' }, warnings: [] };
      out.say(`ДЕМО: имитатор 1С на образцах контракта 1.2.0 (${demo.baseUrl.replace(/^http:\/\//, '')})${flags.demoDefect ? `, дефект ${flags.demoDefect}` : ''}. Это не ваша 1С.`);
    } else {
      const ld = loadSettings(settingsFile);
      for (const w of ld.warnings) out.say(`Внимание (настройки): ${w}`);
      settings = ld.settings;
      if (!ld.exists) {
        if (flags.config) throw new SettingsError(`файл настроек ${path.basename(settingsFile)} не найден`);
        if (flags.expectNoAccess) {
          const a = await prompter.line('Адрес публикации до /hs (тот же, что на компьютере с доступом): ');
          if (!a || !a.trim()) throw new SettingsError('адрес публикации не введён');
          settings.baseUrl = a.trim();
        } else {
          settings = await wizard(prompter, out.say, settings);
          wizardUsed = true;
        }
      }
      if (!settings.baseUrl) throw new SettingsError('в настройках не указан адрес публикации (baseUrl)');
    }
    if (flags.out) settings.outDir = flags.out;
  } catch (e) {
    out.say(`Ошибка настроек: ${e.code === 'CANCELLED' ? 'отменено пользователем' : e.message}`);
    out.say('Проверка не выполнена (код 2); протокол не записан — причина на экране.');
    prompter.close();
    return 2;
  }

  let base;
  try { base = parseBaseUrl(settings.baseUrl); } catch (e) { out.say(`Ошибка настроек: ${e.message}`); out.say('Проверка не выполнена (код 2); протокол не записан — причина на экране.'); return 2; }
  if (base.scheme === 'http' && !flags.allowHttp && !demo) {
    out.say(`Ошибка: адрес ${base.scheme}://${base.host} без шифрования. По «Требованиям к API 1С» (§4.2) публикация — только по HTTPS. Если это осознанно (тестовый стенд) — запустите с --allow-http.`);
    return 2;
  }
  const banners = [];
  if (flags.insecure && base.scheme === 'https') banners.push('СЕРТИФИКАТ НЕ ПРОВЕРЯЛСЯ (--insecure)');
  // Запускатели .cmd очищают NODE_EXTRA_CA_CERTS; если программу запустили иначе, а переменная задана, —
  // корневые сертификаты из неё участвовали в проверке TLS: это видно в протоколе.
  if (process.env.NODE_EXTRA_CA_CERTS && base.scheme === 'https' && !demo) banners.push('ИСПОЛЬЗОВАНЫ КОРНЕВЫЕ СЕРТИФИКАТЫ ИЗ NODE_EXTRA_CA_CERTS этого компьютера (запуск не через Proverka_API_1C.cmd)');
  if (base.scheme === 'http' && !demo) banners.push('HTTP БЕЗ ШИФРОВАНИЯ (--allow-http)');
  if (banners.length) out.banner(banners);

  // Корневой сертификат — ПОСЛЕ мастера (вопрос «4)» мастера действует уже на этот запуск) и флага --ca.
  // --ca — относительно текущей папки, caFile из настроек — относительно папки настроек; кавычки снимаются.
  let caFile = null;
  if (!demo) {
    if (flags.ca) caFile = path.resolve(process.cwd(), stripQuotes(flags.ca));
    else if (settings.caFile) caFile = path.resolve(settingsDir, stripQuotes(settings.caFile));
    if (caFile && base.scheme === 'https') {
      const why = checkPem(caFile);
      if (why) {
        out.say(`Ошибка настроек: ${why}`);
        out.say('Проверка не выполнена (код 2); протокол не записан — причина на экране.');
        prompter.close();
        return 2;
      }
    }
  }
  const outDir = path.isAbsolute(settings.outDir || '') ? settings.outDir : path.join(flags.out ? process.cwd() : settingsDir, settings.outDir || 'protokoly');

  if (!flags.expectNoAccess && !demo) {
    try {
      secrets = await obtainSecrets(settings, prompter, settingsDir);
    } catch (e) {
      out.say(e.code === 'CANCELLED' ? 'Отменено пользователем.' : `Ошибка настроек: ${e.message}`);
      out.say('Проверка не выполнена (код 2); протокол не записан — причина на экране.');
      prompter.close();
      return 2;
    }
    if (wizardUsed) {
      const a = await prompter.yesNo(`Сохранить настройки (без пароля и ключа) в ${path.basename(settingsFile)}?`, { def: 'y' });
      if (a === 'y') {
        try { saveSettings(settingsFile, settings); out.say(`Настройки сохранены: ${settingsFile}`); } catch (e) { out.say(`Настройки не сохранены: ${e.code || e.message}`); }
      }
    }
  }
  if (secrets) {
    redactor.add(secrets.password);
    redactor.add(secrets.token);
    redactor.add(secrets.clientKey);
    if (secrets.password) redactor.addBasic(settings.user, secrets.password);
  }
  if (!demo && !flags.expectNoAccess) {
    out.say(flags.allowWrite ? 'Режим: с записью (после подтверждения).' : 'Режим: только чтение. Проверку записи запускайте с --allow-write (или Proverka_API_1C_zapis.cmd).');
  }

  let http;
  try {
    http = new HttpClient({
      base,
      auth: { scheme: settings.auth, user: settings.user, password: secrets?.password, token: secrets?.token },
      clientKey: secrets?.clientKey,
      caFile: caFile && !demo ? caFile : null,
      insecure: !!flags.insecure || !!flags.expectNoAccess,
      timeoutScale: flags.timeoutScale,
      connectTimeoutMs: contract.connectTimeoutMs,
    });
  } catch (e) {
    out.say(`Ошибка настроек: файл корневого сертификата не прочитан (${e.code || 'ошибка чтения'})`);
    out.say('Проверка не выполнена (код 2); протокол не записан — причина на экране.');
    return 2;
  }

  const ctx = new RunContext({
    contract, validator: new Validator(contract),
    masker, redactor, out, prompter, settings, flags, http, secrets: secrets || {}, demo, caFile,
    registry: new Registry(), synth: new Synth(contract.paths.samples),
    startedAt, pollMs: demo ? 50 : 5000,
  });
  ctx.banners = banners;
  if (sel) { ctx.selected = sel.sel; ctx.requested = sel.requested; }
  live = { ctx, startedAt, outDir, demo };

  let aborted = null;
  try {
    if (flags.expectNoAccess) {
      out.say(`Проверка «нет доступа» с этого компьютера: ${base.host}:${base.port} (пароль и ключ не нужны)`);
      await runExpectNoAccess(ctx);
    } else {
      out.rule();
      await runS1(ctx);
      await runS2(ctx);
      await runS3A1(ctx);
      await runHealth(ctx);
      await runA2toA5(ctx);
      await runA8(ctx);
      out.rule();
      // чтение
      await runChangesRead(ctx);
      await runImages(ctx);
      await runExternalIdsRead(ctx);
      await runCustomersRead(ctx);
      await runOrdersRead(ctx);
      await runReturnsRead(ctx);
      await runQrRead(ctx);
      await runCatalogRead(ctx);
      // запись
      if (demo) { ctx.writeAllowed = true; ctx.writeConfirmed = true; }
      else if (flags.allowWrite) {
        ctx.writeConfirmed = await confirmWrite(ctx);
        ctx.writeAllowed = ctx.writeConfirmed;
      }
      out.rule();
      await runChangesWrite(ctx);
      await runCustomersWrite(ctx);
      await runPayments(ctx);
      await runOrdersWrite(ctx);
      await runReturnsWrite(ctx);
      await runQrWrite(ctx);
      await runCheckCart(ctx);
      await runA6(ctx);
      await runA7(ctx);
      await runC14(ctx);
      await runX4(ctx);
      await runX5(ctx);
      out.rule();
      await runManual(ctx);
      await ctx.skip('M2', 'проверяется на ДРУГОМ компьютере сети: Proverka_API_1C.cmd --expect-no-access (пароль не нужен)');
      await runTimings(ctx);
    }
  } catch (e) {
    if (e && (e.code === 'ABORT' || e.code === 'CANCELLED')) aborted = e.code === 'CANCELLED' ? 'прервано пользователем (Ctrl+C)' : e.reason;
    else aborted = `сбой программы: ${e && e.message ? e.message : String(e)}`;
    out.say(`Проверка прервана: ${aborted}`);
  }
  return finish(ctx, { startedAt, outDir, demo, aborted });
}

async function finish(ctx, { startedAt, outDir, demo, aborted }) {
  live = null;
  // Прерванный прогон: незаконченная проверка — ПРОПУЩЕНО (не ПРОЙДЕНО без ответа 1С).
  if (aborted) for (const id of ctx.order) { const r = ctx.get(id); if (r && !r.done) { r.skip(`не завершена: ${aborted}`); r.done = true; } }
  ctx.registry.finalizePending();
  // Сквозные правила — только в обычном прогоне (в проверке «нет доступа» они ни о чём не говорят).
  if (!ctx.flags.expectNoAccess) {
    await finalizeCross(ctx);
    for (const d of CATALOG.filter((x) => x.group === 'E')) {
      const r = ctx.get(d.id);
      ctx.out.say(`[${d.id}] ${d.title}: ${VERDICT_RU[r.verdict]}${r.summaryLine ? ` — ${r.summaryLine}` : ''}`);
    }
  }
  let bad = 0;
  for (const id of ctx.order) { const v = ctx.get(id)?.verdict; if (v === 'FAIL' || v === 'MANUAL_NO') bad++; }
  // --checks: всё, что выбрал человек, пропущено — «ничего не проверено», код 2 (не зелёный итог).
  let nothing = false;
  if (!aborted && ctx.requested && ctx.requested.size) {
    nothing = [...ctx.requested].every((id) => { const r = ctx.get(id); return !r || !ctx.order.includes(id) || r.verdict === 'SKIP'; });
  }
  const exitCode = aborted || nothing ? 2 : (bad ? 1 : 0);
  const model = buildModel(ctx, { startedAt, finishedAt: new Date(), exitCode, aborted, nothingChecked: nothing });
  let written = null;
  try {
    written = writeProtocol(model, { outDir, redactor: ctx.redactor, demo: !!demo, startedAt });
  } catch (e) {
    ctx.out.say(`Протокол не записан: ${e.code || e.message}`);
  }
  ctx.out.rule();
  const cov = model.coverage;
  if (aborted) ctx.out.say(`ПРОВЕРКА ПРЕРВАНА: ${aborted}. Итог неполный.`);
  else if (nothing) ctx.out.say('Итог: ничего не проверено — все выбранные проверки пропущены (причины — в строках выше). Код 2.');
  else if (bad) ctx.out.say(`Итог: ошибки — ${bad}. Что исправить — в протоколе.`);
  else ctx.out.say(cov.complete ? 'Итог: ошибок нет.' : 'Итог: ошибок нет, но проверка неполная.');
  ctx.out.say(`ПРОЙДЕНО ${model.summary.PASS}, ОШИБКА ${model.summary.FAIL}, ЗАМЕЧАНИЕ ${model.summary.WARN}, ПРОПУЩЕНО ${model.summary.SKIP}, МЕТОДА НЕТ ${model.summary.ABSENT}`);
  ctx.out.say(cov.text);
  if (written) {
    if (written.fallback) ctx.out.say(`Нет прав на запись в папку протоколов — протокол записан в ${written.dir}`);
    ctx.out.say('Протокол:');
    for (const f of written.files) ctx.out.say(`  ${f}`);
    ctx.out.say('Отправьте файл .html (или все три) разработчикам POS. Паролей и ключа в протоколе нет.');
  }
  if (ctx.registry.created.length) {
    ctx.out.say(`Созданы тестовые объекты «ПРОВЕРКА POS»: ${ctx.registry.created.length} — список и как удалить — в протоколе.`);
    for (const c of ctx.registry.created.filter((x) => x.unknown)) ctx.out.say(`  ВНИМАНИЕ (${c.checkId}): ${c.kind}${c.externalId !== '—' ? ` ${c.externalId}` : ''} — ${c.note || 'результат неизвестен'}`);
  }
  for (const p of ctx.registry.exchangePlan.filter((x) => x.checkId !== 'C6' && x.checkId !== 'C7' && x.checkId !== 'C14' && x.checkId !== 'C11' && x.checkId !== 'C12')) {
    ctx.out.say(`  ВНИМАНИЕ (${p.checkId}): план обмена «POS» — ${p.note || (p.action === 'ack' ? `ack ${p.messageNumber}` : 'перерегистрация')}`);
  }
  ctx.out.say(`Код выхода: ${exitCode}`);
  try { ctx.http.close(); } catch { /* закрыт */ }
  try { ctx.prompter.close(); } catch { /* закрыт */ }
  if (demo) await demo.close();
  return exitCode;
}

/** Корневой сертификат: файл читается и это текст PEM; иначе — понятная причина (без содержимого файла). */
function checkPem(file) {
  let buf;
  try { buf = fs.readFileSync(file); } catch (e) {
    return `файл корневого сертификата не прочитан (${e.code || 'ошибка чтения'}): ${path.basename(file)} — укажите путь к файлу .pem (кавычки не нужны)`;
  }
  if (!buf.toString('latin1').includes('-----BEGIN CERTIFICATE-----')) {
    return `файл корневого сертификата ${path.basename(file)} — не PEM: нужен текст, начинающийся с -----BEGIN CERTIFICATE----- (экспорт «Файлы X.509 (.CER) в кодировке Base64»)`;
  }
  return null;
}

let interrupted = false;
process.on('SIGINT', async () => {
  if (interrupted) process.exit(2);
  interrupted = true;
  if (live) {
    const { ctx, startedAt, outDir, demo } = live;
    ctx.out.say('\nПрервано (Ctrl+C) — пишется частичный протокол…');
    try { await finish(ctx, { startedAt, outDir, demo, aborted: 'прервано пользователем (Ctrl+C)' }); } catch { /* как есть */ }
  }
  process.exit(2);
});

main(process.argv.slice(2)).then(
  (code) => { process.exitCode = code; setTimeout(() => process.exit(code), 50).unref(); },
  async (e) => {
    const r = live?.ctx?.redactor;
    const msg = e && e.message ? e.message : String(e);
    process.stdout.write(`Сбой программы: ${r ? r.redact(msg) : msg}\n`);
    if (live) {
      const { ctx, startedAt, outDir, demo } = live;
      try { await finish(ctx, { startedAt, outDir, demo, aborted: `сбой программы: ${msg}` }); } catch { /* как есть */ }
    }
    process.exit(2);
  },
);
