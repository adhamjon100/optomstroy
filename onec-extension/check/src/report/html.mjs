// Протокол HTML: один файл, стили внутри, без скриптов, CSP; всё, что пришло от 1С, экранируется.
import { GROUPS } from '../checks/index.mjs';
import { humanBishkek } from './time.mjs';

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const SEV_RU = { FAIL: 'ошибка', WARN: 'замечание', INFO: 'сведения' };

export function srcText(s) {
  const out = [];
  if (s.contract?.length) out.push('контракт: ' + s.contract.join(', '));
  if (s.ref?.length) out.push('Требования ' + s.ref.join(', '));
  if (s.kp?.length) out.push(s.kp.join(', '));
  if (s.ac?.length) out.push(s.ac.join(', '));
  return out.join('; ');
}

const CSS = `
:root{--fg:#1d2330;--muted:#5b6475;--line:#d5dae3;--bg:#fff;--soft:#f4f6f9;--ok:#1f7a3a;--bad:#b42318;--warn:#9a6700;--info:#3456a3;--skip:#6b7280}
*{box-sizing:border-box}body{margin:0;padding:24px 28px;font:14px/1.45 "Segoe UI",Arial,sans-serif;color:var(--fg);background:var(--bg);max-width:1100px}
h1{font-size:22px;margin:0 0 8px}h2{font-size:18px;margin:28px 0 8px;border-bottom:2px solid var(--line);padding-bottom:4px}h3{font-size:15px;margin:18px 0 6px}
table{border-collapse:collapse;width:100%;margin:6px 0 12px;page-break-inside:auto}tr{page-break-inside:avoid}th,td{border:1px solid var(--line);padding:4px 6px;text-align:left;vertical-align:top;overflow-wrap:anywhere}th{background:var(--soft)}
td.v{white-space:nowrap;font-weight:600}.PASS{color:var(--ok)}.FAIL{color:var(--bad)}.WARN{color:var(--warn)}.INFO{color:var(--info)}.SKIP,.ABSENT{color:var(--skip)}.MANUAL_YES{color:var(--ok)}.MANUAL_NO{color:var(--bad)}
.banner{border:2px solid var(--bad);background:#fff4f2;color:var(--bad);font-weight:700;padding:8px 12px;margin:8px 0}
.banner.demo{border-color:var(--info);background:#eef3ff;color:var(--info)}
.total{font-size:18px;font-weight:700;margin:6px 0}.muted{color:var(--muted)}tr.grp td{background:var(--soft);font-weight:600}
pre{background:var(--soft);border:1px solid var(--line);padding:6px 8px;white-space:pre-wrap;word-break:break-word;font:12px/1.35 Consolas,monospace;margin:4px 0}
details{margin:4px 0}summary{cursor:pointer}.ex{border-left:3px solid var(--line);padding-left:8px;margin:6px 0}.hint{color:var(--muted)}
@media print{body{padding:0;max-width:none}details{display:block}details>summary{list-style:none}}
`;

/** Строка итога: прервано / ничего не проверено / ошибки / ошибок нет, но неполно / ошибок нет. */
export function totalLine(m) {
  const s = m.summary;
  const bad = s.FAIL + s.MANUAL_NO;
  if (m.aborted) return { cls: 'SKIP', text: `Проверка прервана — итог неполный${bad ? ` (найдено ошибок: ${bad})` : ''}` };
  if (m.nothingChecked) return { cls: 'SKIP', text: 'Ничего не проверено — все выбранные проверки пропущены' };
  if (bad) return { cls: 'FAIL', text: `Ошибки: ${bad}` };
  if (m.coverage && !m.coverage.complete) return { cls: 'WARN', text: 'Ошибок нет, проверка неполная' };
  return { cls: 'PASS', text: 'Ошибок нет' };
}

export function renderHtml(m) {
  const o = [];
  o.push('<!doctype html><html lang="ru"><head><meta charset="utf-8">');
  o.push(`<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">`);
  o.push('<meta name="viewport" content="width=device-width, initial-scale=1">');
  o.push(`<title>Протокол проверки API 1С${m.mode.demo ? ' — ДЕМО' : ''}</title><style>${CSS}</style></head><body>`);
  o.push('<h1>Протокол проверки API 1С (расширение OptomstroyPOS)</h1>');
  if (m.mode.demo) o.push('<div class="banner demo">ДЕМО — имитатор, не ваша 1С. Результаты показывают, как выглядит проверка.</div>');
  for (const b of m.banners) o.push(`<div class="banner">${esc(b)}</div>`);
  if (m.aborted) o.push(`<div class="banner">ПРОВЕРКА ПРЕРВАНА: ${esc(m.aborted)}</div>`);

  // Шапка
  const t = m.target;
  const rows = [
    ['Дата и время', `${esc(humanBishkek(new Date(Date.parse(m.startedAt))))} — ${esc(m.finishedAt.slice(11, 19))}`],
    ['Программа', `${esc(m.tool.name)} ${esc(m.tool.version)} (каталог проверок ${esc(m.tool.checksCatalog)}), сборка sha256 ${esc(m.tool.programSha256 || '—')}${m.tool.programModified ? ' — ФАЙЛЫ ПРОГРАММЫ ИЗМЕНЕНЫ после сборки' : ''}, Node.js ${esc(m.environment.node)}`],
    ['Контракт', `onec-http-service ${esc(m.contract.version)}; sha256 YAML ${esc(m.contract.yamlSha256)}${m.contract.jsonSha256 ? `; JSON ${esc(m.contract.jsonSha256)}` : ''}; git blob ${esc(m.contract.gitBlob)}`],
    ['Документы', '«Требования к API 1С» 1.2.1 (20.11.2026; требования — как в 1.2 от 04.11.2026); контрольный пример — 18 §7.2 (= Требования §8.3)'],
    ['Сервер', t ? `${esc(t.scheme)}://${esc(t.host)}:${esc(t.port)}${t.tls ? `; TLS ${esc(t.tls.protocol || '?')}, сертификат ${t.tls.insecure ? 'НЕ ПРОВЕРЯЛСЯ' : t.tls.verified ? 'проверен' : '?'}${t.tls.validTo ? `, до ${esc(t.tls.validTo)}` : ''}` : ''}` : '—'],
    ['Пользователь', `${esc(m.auth.user || '—')}, вход: ${m.auth.scheme === 'bearer' ? 'JWT' : 'пароль (Basic)'}`],
    ['Режим', `${m.mode.expectNoAccess ? 'проверка «нет доступа» (M2)' : m.mode.allowWrite ? (m.mode.writeConfirmed ? 'с записью (подтверждено)' : 'с записью — НЕ подтверждено, выполнено только чтение') : 'только чтение'}${m.mode.demo ? ', ДЕМО' : ''}${m.mode.manual ? ', с ручными шагами' : ', без ручных шагов'}`],
    ['1С', m.health.extensionVersion ? `расширение ${esc(m.health.extensionVersion)}, платформа ${esc(m.health.platform)}, ${esc(m.health.configuration)} ${esc(m.health.configurationVersion)}` : '—'],
  ];
  if (m.timezoneNote) rows.push(['Часовой пояс', esc(m.timezoneNote)]);
  o.push('<table>' + rows.map(([k, v]) => `<tr><th style="width:150px">${k}</th><td>${v}</td></tr>`).join('') + '</table>');

  // Итог
  const s = m.summary;
  const t0 = totalLine(m);
  o.push(`<h2>Итог</h2><div class="total ${t0.cls}">${esc(t0.text)}</div>`);
  if (m.coverage) o.push(`<p class="${m.coverage.complete ? 'muted' : 'WARN'}">${esc(m.coverage.text)}</p>`);
  o.push(`<p>ПРОЙДЕНО ${s.PASS} · ОШИБКА ${s.FAIL} · ЗАМЕЧАНИЕ ${s.WARN} · СВЕДЕНИЯ ${s.INFO} · ПРОПУЩЕНО ${s.SKIP} · МЕТОДА НЕТ ${s.ABSENT} · ВРУЧНУЮ: ДА ${s.MANUAL_YES} · ВРУЧНУЮ: НЕТ ${s.MANUAL_NO}. Код выхода ${m.exitCode}.</p>`);

  // Сводная таблица
  o.push('<h2>Сводная таблица</h2><table><tr><th>ID</th><th>Проверка</th><th>Результат</th><th>Кратко</th></tr>');
  let g = null;
  for (const c of m.checks) {
    if (c.group !== g) { g = c.group; o.push(`<tr class="grp"><td colspan="4">${esc(GROUPS[g] || g)}</td></tr>`); }
    o.push(`<tr><td>${esc(c.id)}</td><td>${esc(c.title)}${c.write ? ' <span class="muted">(запись)</span>' : ''}</td><td class="v ${c.verdict}">${esc(c.verdictRu)}</td><td>${esc(c.summary)}</td></tr>`);
  }
  o.push('</table>');

  // Что исправить
  const fails = m.checks.filter((c) => c.verdict === 'FAIL' || c.verdict === 'MANUAL_NO');
  o.push('<h2>Что исправить</h2>');
  if (!fails.length) o.push('<p>Ошибок нет.</p>');
  else {
    o.push('<ol>');
    for (const c of fails) {
      const fs = c.findings.filter((f) => f.severity === 'FAIL');
      o.push(`<li><b>${esc(c.id)} ${esc(c.title)}</b> <span class="muted">(${esc(srcText(c.sources))})</span><ul>`);
      if (c.verdict === 'MANUAL_NO') o.push(`<li>Ручная проверка: ответ «нет» — ${esc(c.manual?.question || '')}${c.advice ? `<br><span class="hint">Подсказка: ${esc(c.advice)}</span>` : ''}</li>`);
      for (const f of fs.slice(0, 15)) {
        o.push(`<li>${esc(f.text)}${f.count > 1 ? ` <span class="muted">(×${f.count})</span>` : ''}${f.where ? `<br><span class="muted">где: ${esc(f.where)}</span>` : ''}${f.hint ? `<br><span class="hint">Подсказка: ${esc(f.hint)}</span>` : ''}</li>`);
      }
      if (fs.length > 15) o.push(`<li class="muted">… ещё ${fs.length - 15} видов ошибок — в разделе «Подробно»</li>`);
      o.push('</ul></li>');
    }
    o.push('</ol>');
  }

  // Созданные объекты
  o.push('<h2>Созданные объекты</h2>');
  if (!m.createdObjects.length) o.push('<p>Программа ничего не создавала.</p>');
  else {
    o.push('<p>Найдите и удалите эти объекты на тестовой копии после проверки.</p><table><tr><th>Вид</th><th>externalId</th><th>ref / номер</th><th>Проверка</th><th>Как найти</th><th>Как удалить</th></tr>');
    for (const c of m.createdObjects) {
      o.push(`<tr><td>${esc(c.kind)}${c.unknown ? '<br><b>результат неизвестен</b>' : ''}${c.note ? `<br><span class="muted">${esc(c.note)}</span>` : ''}</td><td>${esc(c.externalId)}</td><td>${esc(c.ref || '—')}<br>${esc(c.number || '')}${c.date ? `<br>${esc(c.date)}` : ''}</td><td>${esc(c.checkId)}</td><td>${esc(c.find)}</td><td>${esc(c.how)}</td></tr>`);
    }
    o.push('</table>');
  }
  if (m.exchangePlanChanges.length) {
    o.push('<h3>Изменения плана обмена «POS»</h3><table><tr><th>Действие</th><th>Номер сообщения</th><th>Проверка</th><th>Пояснение</th></tr>');
    for (const p of m.exchangePlanChanges) o.push(`<tr><td>${p.action === 'ack' ? 'подтверждение (ack)' : 'перерегистрация'}</td><td>${esc(p.messageNumber ?? '—')}</td><td>${esc(p.checkId)}</td><td>${esc(p.note || '')}</td></tr>`);
    o.push('</table><p class="muted">Подтверждённые сообщения снимают регистрации узла «POS» тестовой копии: если к копии подключена тестовая система POS, эти изменения она не получит.</p>');
  }

  // Ручные шаги
  const man = m.checks.filter((c) => c.manual);
  o.push('<h2>Ручные шаги</h2>');
  if (!man.length) o.push('<p>Ручных ответов нет.</p>');
  else {
    o.push('<table><tr><th>ID</th><th>Вопрос</th><th>Ответ</th><th>Время</th></tr>');
    for (const c of man) o.push(`<tr><td>${esc(c.id)}</td><td>${esc(c.manual.question)}</td><td class="v ${c.verdict}">${esc(c.manual.answer)}</td><td>${esc(c.manual.at.slice(11, 19))}</td></tr>`);
    o.push('</table>');
  }

  // Подробно
  o.push('<h2>Подробно</h2>');
  for (const c of m.checks) {
    o.push(`<details${c.verdict === 'FAIL' ? ' open' : ''}><summary><b>${esc(c.id)}</b> ${esc(c.title)} — <span class="${c.verdict}">${esc(c.verdictRu)}</span></summary><div class="ex">`);
    o.push(`<p class="muted">${esc(c.kindRu)}${c.write ? ', запись' : ''}${c.optional ? ', необязательно' : ''}. Источник: ${esc(srcText(c.sources) || '—')}</p>`);
    if (c.summary) o.push(`<p>${esc(c.summary)}</p>`);
    for (const n of c.notes) o.push(`<p class="muted">${esc(n)}</p>`);
    if (c.findings.length) {
      o.push('<table><tr><th>Вид</th><th>Находка</th><th>Где</th></tr>');
      for (const f of c.findings) o.push(`<tr><td class="${f.severity}">${SEV_RU[f.severity]}${f.rule ? ` <span class="muted">${esc(f.rule)}</span>` : ''}</td><td>${esc(f.text)}${f.count > 1 ? ` <span class="muted">(×${f.count})</span>` : ''}${f.hint ? `<br><span class="hint">${esc(f.hint)}</span>` : ''}</td><td>${esc(f.where || '')}</td></tr>`);
      o.push('</table>');
      if (c.findingsTruncated) o.push(`<p class="muted">… ещё находок: ${c.findingsTruncated}</p>`);
    }
    if (c.evidence && Object.keys(c.evidence).length && c.id !== 'L1') o.push(`<details><summary>Данные проверки</summary><pre>${esc(JSON.stringify(c.evidence, null, 2))}</pre></details>`);
    if (c.requests.length) {
      o.push(`<details><summary>Запросы (${c.requests.length})</summary>`);
      const det = new Map(c.exchanges.map((e) => [e.n, e]));
      for (const q of c.requests) {
        const e = det.get(q.n);
        o.push(`<div class="ex"><b>№${q.n}</b> ${esc(q.method)} ${esc(q.path)} → <b>${esc(q.status ?? q.error ?? '—')}</b>, ${esc(q.ms)} мс (таймаут ${esc(q.timeoutMs)} мс)${q.label ? ` — <span class="muted">${esc(q.label)}</span>` : ''}`);
        if (e) {
          o.push(`<details><summary>запрос → ответ</summary><pre>${esc(Object.entries(e.reqHeaders || {}).map(([k, v]) => `${k}: ${v}`).join('\n'))}</pre>`);
          if (e.reqBody) o.push(`<pre>${esc(e.reqBody)}</pre>`);
          o.push(`<pre>HTTP ${esc(e.status ?? '—')}${e.error ? ' — ' + esc(e.error) : ''}\n${esc(Object.entries(e.resHeaders || {}).map(([k, v]) => `${k}: ${v}`).join('\n'))}</pre>`);
          if (e.resBody) o.push(`<pre>${esc(e.resBody)}</pre>`);
          o.push('</details>');
        }
        o.push('</div>');
      }
      o.push('</details>');
    }
    o.push('</div></details>');
  }

  // Время
  o.push('<h2>Время ответа</h2>');
  const l1 = m.checks.find((c) => c.id === 'L1');
  if (l1?.evidence?.rows?.length) {
    o.push('<table><tr><th>Операция</th><th>Вызовов</th><th>мин</th><th>p50</th><th>p95</th><th>макс</th><th>таймаут</th></tr>');
    for (const r of l1.evidence.rows) o.push(`<tr><td>${esc(r.op)}</td><td>${r.count}</td><td>${r.min}</td><td>${r.p50}</td><td>${r.p95}</td><td>${r.max}</td><td>${r.timeoutMs}</td></tr>`);
    o.push('</table><p class="muted">Время в миллисекундах.</p>');
  }
  const l2 = m.checks.find((c) => c.id === 'L2');
  if (l2) o.push(`<p>Полное чтение сообщения (L2): ${esc(l2.summary)}</p>`);

  // Шаги контрольного примера, которые программа не выполняет
  o.push('<h2>Шаги контрольного примера вручную</h2><p class="muted">Эти шаги 18 §7.2 (Требования §8.3) требуют действий в 1С — их выполняют на тестовой копии вручную и пишут результат в протокол приёмки.</p><table><tr><th>Шаг</th><th>Что сделать</th><th>Ожидаемый результат</th></tr>');
  for (const x of m.manualKp) o.push(`<tr><td>${esc(x.kp)}</td><td>${esc(x.what)}</td><td>${esc(x.expect)}</td></tr>`);
  o.push('</table>');

  o.push('<hr><p class="muted">Протокол не содержит паролей и ключа. Телефоны, ИНН, e-mail, имена клиентов и адреса скрыты. Отправьте этот файл (или все три файла протокола) разработчикам POS.</p>');
  o.push('</body></html>\n');
  return o.join('\n');
}
