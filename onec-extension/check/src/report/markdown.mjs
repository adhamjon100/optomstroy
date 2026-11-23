// Протокол Markdown (GFM): та же структура, без сырых тел ответов.
import { GROUPS } from '../checks/index.mjs';
import { totalLine } from './html.mjs';

const cell = (s) => String(s ?? '').replace(/\|/g, '\\|').replace(/\r?\n/g, ' ');

export function renderMarkdown(m) {
  const o = [];
  o.push('# Протокол проверки API 1С (расширение OptomstroyPOS)\n');
  if (m.mode.demo) o.push('> **ДЕМО — имитатор, не ваша 1С.**\n');
  for (const b of m.banners) o.push(`> **${b}**\n`);
  if (m.aborted) o.push(`> **ПРОВЕРКА ПРЕРВАНА: ${m.aborted}**\n`);
  const t = m.target;
  o.push('| | |\n|---|---|');
  o.push(`| Начало — конец | ${m.startedAt} — ${m.finishedAt} |`);
  o.push(`| Программа | ${m.tool.name} ${m.tool.version}, сборка sha256 ${m.tool.programSha256 || '—'}${m.tool.programModified ? ' — ФАЙЛЫ ПРОГРАММЫ ИЗМЕНЕНЫ после сборки' : ''}, Node.js ${m.environment.node} |`);
  o.push(`| Контракт | ${m.contract.version}, sha256 YAML ${m.contract.yamlSha256}, git blob ${m.contract.gitBlob} |`);
  o.push('| Документы | «Требования к API 1С» 1.2.1 (требования — как в 1.2); контрольный пример — 18 §7.2 (= Требования §8.3) |');
  if (t) o.push(`| Сервер | ${t.scheme}://${t.host}:${t.port}${t.tls ? `, TLS ${t.tls.protocol || '?'}${t.tls.insecure ? ', сертификат НЕ ПРОВЕРЯЛСЯ' : ''}` : ''} |`);
  o.push(`| Пользователь | ${cell(m.auth.user || '—')} (${m.auth.scheme === 'bearer' ? 'JWT' : 'Basic'}) |`);
  o.push(`| Режим | ${m.mode.expectNoAccess ? 'проверка «нет доступа»' : m.mode.allowWrite ? (m.mode.writeConfirmed ? 'с записью' : 'запись не подтверждена — только чтение') : 'только чтение'}${m.mode.demo ? ', ДЕМО' : ''} |`);
  if (m.health.extensionVersion) o.push(`| 1С | расширение ${cell(m.health.extensionVersion)}, платформа ${cell(m.health.platform)}, ${cell(m.health.configuration)} ${cell(m.health.configurationVersion)} |`);
  const s = m.summary;
  o.push(`\n## Итог\n\n**${totalLine(m).text}** — ПРОЙДЕНО ${s.PASS}, ОШИБКА ${s.FAIL}, ЗАМЕЧАНИЕ ${s.WARN}, СВЕДЕНИЯ ${s.INFO}, ПРОПУЩЕНО ${s.SKIP}, МЕТОДА НЕТ ${s.ABSENT}, ВРУЧНУЮ: ДА ${s.MANUAL_YES}, ВРУЧНУЮ: НЕТ ${s.MANUAL_NO}. Код выхода ${m.exitCode}.\n`);
  if (m.coverage) o.push(`${m.coverage.text}\n`);
  o.push('## Сводная таблица\n\n| ID | Проверка | Результат | Кратко |\n|---|---|---|---|');
  let g = null;
  for (const c of m.checks) {
    if (c.group !== g) { g = c.group; o.push(`| | **${cell(GROUPS[g] || g)}** | | |`); }
    o.push(`| ${c.id} | ${cell(c.title)} | **${c.verdictRu}** | ${cell(c.summary)} |`);
  }
  o.push('\n## Что исправить\n');
  const fails = m.checks.filter((c) => c.verdict === 'FAIL' || c.verdict === 'MANUAL_NO');
  if (!fails.length) o.push('Ошибок нет.');
  for (const c of fails) {
    o.push(`### ${c.id} ${c.title}\n`);
    if (c.verdict === 'MANUAL_NO') o.push(`- Ручная проверка: ответ «нет» — ${c.manual?.question || ''}${c.advice ? `\n  - Подсказка: ${c.advice}` : ''}`);
    for (const f of c.findings.filter((x) => x.severity === 'FAIL').slice(0, 15)) {
      o.push(`- ${f.text}${f.count > 1 ? ` (×${f.count})` : ''}${f.where ? ` — где: ${f.where}` : ''}${f.hint ? `\n  - Подсказка: ${f.hint}` : ''}`);
    }
    o.push('');
  }
  o.push('\n## Созданные объекты\n');
  if (!m.createdObjects.length) o.push('Программа ничего не создавала.');
  else {
    o.push('| Вид | externalId | ref | номер | проверка | как удалить |\n|---|---|---|---|---|---|');
    for (const c of m.createdObjects) o.push(`| ${cell(c.kind)}${c.unknown ? ' (результат неизвестен)' : ''}${c.note && !c.unknown ? ` (${cell(c.note)})` : ''} | ${c.externalId} | ${c.ref || '—'} | ${cell(c.number || '—')} | ${c.checkId} | ${cell(c.how)} |`);
  }
  if (m.exchangePlanChanges.length) {
    o.push('\n**Изменения плана обмена «POS»:**\n');
    for (const p of m.exchangePlanChanges) o.push(`- ${p.action === 'ack' ? `ack ${p.messageNumber}` : 'перерегистрация'} (${p.checkId})${p.note ? ` — ${p.note}` : ''}`);
  }
  o.push('\n## Ручные шаги\n');
  const man = m.checks.filter((c) => c.manual);
  if (!man.length) o.push('Ручных ответов нет.');
  else {
    o.push('| ID | Вопрос | Ответ | Время |\n|---|---|---|---|');
    for (const c of man) o.push(`| ${c.id} | ${cell(c.manual.question)} | ${c.manual.answer} | ${c.manual.at.slice(11, 19)} |`);
  }
  o.push('\n## Подробно\n');
  for (const c of m.checks) {
    if (c.verdict === 'PASS' && !c.findings.length && !c.notes.length) continue;
    o.push(`### ${c.id} ${c.title} — ${c.verdictRu}\n`);
    if (c.summary) o.push(c.summary + '\n');
    for (const n of c.notes) o.push(`- ${n}`);
    for (const f of c.findings.slice(0, 30)) o.push(`- ${f.severity === 'FAIL' ? 'ошибка' : f.severity === 'WARN' ? 'замечание' : 'сведения'}${f.rule ? ` (${f.rule})` : ''}: ${f.text}${f.count > 1 ? ` (×${f.count})` : ''}${f.where ? ` — ${f.where}` : ''}`);
    if (c.requests.length) o.push(`- запросов: ${c.requests.length}; первый: ${c.requests[0].method} ${c.requests[0].path} → ${c.requests[0].status ?? c.requests[0].error}`);
    o.push('');
  }
  o.push('## Время ответа\n');
  const l1 = m.checks.find((c) => c.id === 'L1');
  if (l1?.evidence?.rows?.length) {
    o.push('| Операция | Вызовов | мин | p50 | p95 | макс | таймаут |\n|---|---|---|---|---|---|---|');
    for (const r of l1.evidence.rows) o.push(`| ${cell(r.op)} | ${r.count} | ${r.min} | ${r.p50} | ${r.p95} | ${r.max} | ${r.timeoutMs} |`);
  }
  const l2 = m.checks.find((c) => c.id === 'L2');
  if (l2) o.push(`\nПолное чтение сообщения: ${l2.summary}`);
  o.push('\n## Шаги контрольного примера вручную\n\nЭти шаги 18 §7.2 (Требования §8.3) требуют действий в 1С — их выполняют на тестовой копии вручную.\n');
  for (const x of m.manualKp) o.push(`- ${x.kp}: ${x.what} — ожидается: ${x.expect}`);
  o.push('\n---\nПротокол не содержит паролей и ключа. Телефоны, ИНН, e-mail, имена клиентов и адреса скрыты.\n');
  return o.join('\n');
}
