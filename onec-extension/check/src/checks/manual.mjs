// Ручные и полуавтоматические шаги: C11, C12, C13, K10, M1, M3, M8–M11.
// Без консоли или с --no-manual — ПРОПУЩЕНО. В демо полуавтоматические шаги (C11, C12, M1) выполняет имитатор.
import { readMessage } from './changes.mjs';
import { netFailed, statusText, rnd } from './common.mjs';

const ACK = 'POST /pos/v1/changes/ack';
const NO_MANUAL = 'ручной шаг не спрашивался (--no-manual или нет консоли)';

/**
 * Ответ на ручной вопрос. «да» — ВРУЧНУЮ: ДА. «нет» — ВРУЧНУЮ: НЕТ (ошибка), а у необязательного шага — ЗАМЕЧАНИЕ
 * (на код выхода не влияет). «п» или Enter — ПРОПУЩЕНО.
 */
function manualVerdict(r, a, yesText, { optional = false, noText = null } = {}) {
  if (a === 'y') r.set('MANUAL_YES', yesText || 'подтверждено');
  else if (a === 'n') {
    if (optional) r.warn(`необязательный шаг: ответ «нет»${noText ? ` — ${noText}` : ''}`, { code: 'manual-no-optional' });
    else r.set('MANUAL_NO', noText ? `ответ «нет»: ${noText}` : 'человек ответил «нет»');
  } else r.skip(a === 's' ? 'пропущено человеком' : NO_MANUAL);
}

async function nextMessage(ctx, r, label) {
  const h = await r.call({ op: 'GET /pos/v1/health', path: '/pos/v1/health', label: 'текущий lastAck' });
  const since = h.json?.lastAckMessageNumber ?? ctx.data.lastAck;
  const msg = await readMessage(ctx, r, since, { label });
  return msg;
}

async function ackIfAllowed(ctx, r, msg) {
  if (!ctx.writeAllowed || !msg.complete || msg.empty) return;
  const ex = await r.call({ op: ACK, path: '/pos/v1/changes/ack', body: { messageNumber: msg.messageNumber }, label: `ack ${msg.messageNumber}` });
  if (ex.status === 200) { ctx.registry.addPlan({ action: 'ack', messageNumber: msg.messageNumber, checkId: r.id }); ctx.data.lastAck = msg.messageNumber; }
}

export async function runManual(ctx) {
  const demo = ctx.demo;
  const items = ctx.data.message?.items || [];

  // C11 — изменённый товар приходит в следующем /changes
  await ctx.run('C11', async (r) => {
    const prod = items.find((i) => i.type === 'Catalog_Номенклатура' && !i.isFolder && !i.deletionMark)
      || (ctx.data.refs?.productRef ? { ref: ctx.data.refs.productRef } : null);
    if (!prod) { r.skip('нет товара: в сообщении нет товаров и не задан refs.productRef'); return; }
    if (demo) { demo.simulate.changeProduct(prod.ref); r.note('ДЕМО: имитатор сам изменил описание товара'); }
    else {
      if (!ctx.manualAllowed) { r.skip(NO_MANUAL); return; }
      const a = await ctx.waitEnter(r, `Измените в 1С описание товара «${prod.description || '?'}» (код ${prod.code || '?'}, ref ${prod.ref}) и запишите его`);
      if (a !== 'done') { r.skip(a === 'skip' ? 'пропущено человеком' : a === 'refused' ? 'товар не изменён (три ответа «нет»)' : NO_MANUAL); return; }
    }
    const msg = await nextMessage(ctx, r, 'после изменения товара');
    const found = msg.items.find((i) => i.type === 'Catalog_Номенклатура' && i.ref === prod.ref);
    if (!found) r.fail(`изменённый товар ${prod.ref} не пришёл в сообщении ${msg.messageNumber} — проверьте авторегистрацию справочника Номенклатура в плане обмена «POS»`, { code: 'not-found' });
    else if (prod.dataVersion && found.dataVersion === prod.dataVersion) r.fail(`товар пришёл с тем же dataVersion (${found.dataVersion}) — изменение не видно`, { code: 'same-version' });
    await ackIfAllowed(ctx, r, msg);
    if (found) r.pass(`товар пришёл в сообщении ${msg.messageNumber}${found.dataVersion !== prod.dataVersion ? ' с новым dataVersion' : ''}`);
  });

  // C12 — удаление приходит как ObjectDeletion (необязательно)
  await ctx.run('C12', async (r) => {
    let expectRef = null;
    if (demo) { expectRef = demo.simulate.deleteObject(); r.note('ДЕМО: имитатор сам удалил тестовую характеристику'); }
    else {
      if (!ctx.manualAllowed) { r.skip(NO_MANUAL); return; }
      const a = await ctx.askYesNo(r, 'Необязательно: удалите на копии объект состава обмена совсем — например, тестовую характеристику: пометьте её на удаление и выполните «Удаление помеченных объектов». Удалили? (д — удалил, н или п — пропустить)', { def: 's', allowSkip: true });
      if (a !== 'y') { r.skip('необязательный шаг пропущен'); return; }
    }
    const msg = await nextMessage(ctx, r, 'после удаления');
    const dels = msg.items.filter((i) => i.type === 'ObjectDeletion');
    // В УТ 11 «Удалить» обычно только ставит пометку: объект приходит снова с deletionMark=true (Требования §5.7
    // «Удаления») — это правильно; ObjectDeletion появится после «Удаления помеченных объектов».
    const marked = msg.items.filter((i) => i.type !== 'ObjectDeletion' && i.deletionMark === true);
    await ackIfAllowed(ctx, r, msg);
    if (dels.length) {
      if (expectRef && !dels.some((d) => d.ref === expectRef)) r.fail(`ObjectDeletion пришёл, но не с ref удалённого объекта ${expectRef}`, { code: 'ref' });
      r.pass(`ObjectDeletion: ${dels.length}`);
    } else if (marked.length) {
      r.infoVerdict(`пометка удаления передана (deletionMark=true: ${marked.length}); ObjectDeletion придёт после «Удаления помеченных объектов»`);
    } else {
      r.fail('в следующем сообщении нет ни ObjectDeletion, ни объекта с deletionMark=true — удаление и пометка удаления не передаются (авторегистрация в плане обмена «POS»)', { code: 'no-deletion' });
    }
  });

  // C13 — счётчики совпадают с 1С
  await ctx.run('C13', async (r) => {
    const human = ctx.get('C3')?.evidence?.human;
    if (!human) { r.skip('нет счётчиков C3'); return; }
    const line = Object.entries(human).filter(([, n]) => n).map(([k, n]) => `${k}: ${n}`).join(', ') || 'элементов нет';
    r.evidence = human;
    r.note(`счётчики: ${line}`);
    // Требования §8.2, этап 3: количество записей сверяется после полной выгрузки (/changes/reregister + /changes). Без
    // неё в сообщении только накопившиеся изменения — честный ответ был бы «нет», а это не ошибка 1С.
    if (!ctx.data.reregistered) {
      r.skip('сверка чисел — только после перерегистрации (C6, режим записи): без неё в сообщении лишь накопившиеся изменения, не вся база');
      return;
    }
    if (demo || !ctx.manualAllowed) { r.skip(demo ? 'ДЕМО: сверка с 1С не спрашивается' : NO_MANUAL); return; }
    ctx.out.say(`Счётчики из /changes после перерегистрации: ${line}`);
    const a = await ctx.askYesNo(r, 'Числа товаров и клиентов совпадают с 1С? (д — совпадают, н — не совпадают, п — пропустить)', { def: 's', allowSkip: true });
    manualVerdict(r, a, 'числа совпадают с 1С', { noText: 'числа не совпадают с 1С' });
  });

  // K10 — сальдо
  await ctx.run('K10', async (r) => {
    const k8 = ctx.data.k8;
    if (!k8) { r.skip('нет данных K8'); return; }
    // В 1С клиента ищут по коду (по GUID не найти); имя клиента не показывается — это ПДн.
    const who = k8.code ? `клиент с кодом ${k8.code} (ref ${k8.ref})` : `клиент ref ${k8.ref} (код неизвестен: клиент указан в refs.customerRef — вы знаете, кто это)`;
    r.note(`${who}: сальдо ${k8.balance}, документов ${k8.documents}`);
    if (demo || !ctx.manualAllowed) { r.skip(demo ? 'ДЕМО: сверка с 1С не спрашивается' : NO_MANUAL); return; }
    ctx.out.say(`Долг: ${who}, сальдо ${k8.balance}, документов долга ${k8.documents}`);
    manualVerdict(r, await ctx.askYesNo(r, 'Сальдо совпадает с отчётом «Задолженность клиентов»? (д — совпадает, н — не совпадает, п — пропустить)', { def: 's', allowSkip: true }), 'сальдо совпадает', { noText: 'сальдо не совпадает с отчётом' });
  });

  // M1 — константа ОбменПриостановлен
  await ctx.run('M1', async (r) => {
    if (!demo && !ctx.manualAllowed) { r.skip(NO_MANUAL); return; }
    if (demo) { demo.simulate.setMaintenance(true); r.note('ДЕМО: имитатор сам включил «обмен приостановлен»'); }
    else {
      const a = await ctx.waitEnter(r, 'Включите в 1С константу ОбменПриостановлен');
      // Пропуск — без второй просьбы «Выключите»: константу не включали.
      if (a !== 'done') { r.skip(a === 'skip' ? 'пропущено человеком' : a === 'refused' ? 'константа не включена (три ответа «нет»)' : NO_MANUAL); return; }
    }
    const calls = [
      { op: 'GET /pos/v1/health', path: '/pos/v1/health' },
      { op: 'GET /pos/v1/changes', path: '/pos/v1/changes', query: { since: ctx.data.lastAck ?? 0, limit: 1 } },
      { op: 'GET /pos/v1/external-ids', path: '/pos/v1/external-ids', query: { limit: 1 } },
    ];
    // Картинки — только если метод есть.
    if (!ctx.data.absent.has('I3')) calls.push({ op: 'GET /pos/v1/images/{ref}', path: `/pos/v1/images/${rnd()}`, image: true });
    if (ctx.writeAllowed) calls.push({ op: 'POST /pos/v1/customers', path: '/pos/v1/customers', rawBody: '{"externalId":' });
    for (const c of calls) {
      const ex = await r.call({ ...c, noRetry: true, label: 'обмен приостановлен' });
      if (netFailed(r, ex, c.op)) continue;
      if (ex.status !== 503 || ex.posCode !== 'POS_E_MAINTENANCE') r.fail(`${c.op}: пока константа включена, нужен 503 POS_E_MAINTENANCE, пришёл ${statusText(ex)}`, { code: 'not-503', where: c.op });
    }
    if (demo) demo.simulate.setMaintenance(false);
    else {
      const off = await ctx.waitEnter(r, 'Выключите константу ОбменПриостановлен', { allowSkip: false });
      if (off === 'refused') r.warn('человек трижды ответил «нет» на «Выключите константу ОбменПриостановлен» — выключите её: пока она включена, POS получает 503 и не работает с 1С', { code: 'still-on' });
    }
    const after = await r.call({ op: 'GET /pos/v1/health', path: '/pos/v1/health', label: 'после выключения' });
    if (after.status !== 200) r.fail(`после выключения константы /health ответил ${statusText(after)} — нужен 200`, { code: 'after' });
    r.pass('503 POS_E_MAINTENANCE во всех методах, после выключения — 200');
  });

  // Вопросы — без отрицания, со смыслом ответов; Enter — «пропустить».
  const ask = async (id, question, { optional = false, need = null, yes, no = null } = {}) => {
    await ctx.run(id, async (r) => {
      if (demo || !ctx.manualAllowed) { if (!need || need(r, true)) r.skip(demo ? 'ДЕМО: ручной вопрос не задаётся' : NO_MANUAL); return; }
      if (need && !need(r)) return;
      const a = await ctx.askYesNo(r, (optional ? 'Необязательно. ' : '') + question, { def: 's', allowSkip: true });
      manualVerdict(r, a, yes, { optional, noText: no });
    });
  };

  await ask('M3', 'Публикация закрыта из интернета — с телефона по мобильному интернету адрес публикации не открылся? (д — закрыта, н — открылась, п — не проверяли)', { yes: 'из интернета не открывается', no: 'адрес публикации открылся из интернета' });
  await ask('M8', 'Найдите в 1С объекты из списка «Созданные объекты»: карточки «ПРОВЕРКА POS…», оплаты — по externalId в регистре POS_ВнешниеИдентификаторыPOS (в комментарии документа — «POS <uuid>», Требования §4.7 п. 4). На 10 одновременных запросов — одна карточка и один ПКО? (д — так и есть, н — не найдены или есть дубли, п — пропустить)', {
    need: (r, quiet) => {
      if (!ctx.registry.created.length) { r.skip('программа ничего не создала (нет --allow-write или записи пропущены)'); return false; }
      if (quiet) return true;
      ctx.out.say('Созданные объекты:');
      for (const c of ctx.registry.created) ctx.out.say(`  ${c.kind}: externalId ${c.externalId}, ref ${c.ref ?? '?'}, номер ${c.number ?? '?'}`);
      return true;
    },
    yes: 'объекты найдены, дублей нет',
    no: 'объекты не найдены или есть дубли',
  });
  await ask('M9', `В журнале POS_ЖурналЗапросовPOS есть запрос с X-Request-Id ${ctx.data.healthRequestId}? (д — есть, н — нет, п — пропустить)`, { optional: true, yes: 'запрос найден в журнале', no: 'запроса в журнале нет' });
  await ask('M10', 'Пользователи 1С работали без замедления во время полного чтения (C2)? (д — без замедления, н — было замедление, п — не знаю)', {
    need: (r) => {
      if (!(ctx.data.fullRead && ctx.data.fullRead.items > 0)) { r.skip('полного чтения с элементами не было'); return false; }
      return true;
    },
    yes: 'замедления не было',
    no: 'пользователи заметили замедление',
  });
  // M11 (КП-20, блокировка → POS_E_LOCKED): программа не умеет сама держать блокировку объекта в 1С — шаг выполняется
  // вручную и перечислен в протоколе среди шагов контрольного примера, которые программа не выполняет.
  await ctx.run('M11', async (r) => {
    if (ctx.data.absent.has('O0')) { r.skip('метода заказов нет (O0 — ОШИБКА): блокировку заказа проверить нельзя'); return; }
    r.skip('шаг КП-20 программа не выполняет: блокировку заказа другим сеансом держат вручную в 1С — см. «Шаги контрольного примера вручную» в конце протокола');
  });
}
