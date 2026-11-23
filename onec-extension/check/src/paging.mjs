// Постраничное чтение с предохранителями: предел страниц, повтор курсора, повтор элементов,
// пустые страницы подряд, hasMore без курсора, разный номер сообщения на страницах; повтор элемента — и на разных
// страницах (курсор пропускает или повторяет), и на одной странице (одна запись выдана дважды); conflictOf — «тот же ключ,
// но другой объект» (один externalId — две ссылки 1С).

/**
 * @param {object} o
 * @param {(cursor:string|null, pageNo:number) => Promise<{ex:object, body:any}>} o.fetchPage
 * @param {number} o.maxPages
 * @param {number} o.limit — запрошенный limit (элементов на странице не больше)
 * @param {number} [o.hardMax] — абсолютный предел элементов на странице (5000 для /changes)
 * @param {(item:any)=>string} [o.keyOf] — ключ элемента для поиска повторов
 * @param {(prev:any, cur:any)=>string|null} [o.conflictOf] — текст, если у повтора ключа другой объект (иначе null)
 * @param {(item:any)=>void} [o.onItem]
 * @param {boolean} [o.sameMessage] — проверять одинаковый messageNumber
 * @param {(f:{severity:string,text:string,code:string,where?:string})=>void} o.report
 */
export async function readPages({ fetchPage, maxPages, limit, hardMax = null, keyOf = null, conflictOf = null, onItem = null, sameMessage = false, report, labels = {} }) {
  const seenCursors = new Set();
  const seenKeys = new Map();
  let cursor = null;
  let pages = 0;
  let items = 0;
  let emptyRun = 0;
  let messageNumber = null;
  let stoppedBy = null;
  let dupReported = 0;
  const startedAt = Date.now();
  const pageMs = [];
  const itemName = labels.item || 'элемент';
  for (;;) {
    if (pages >= maxPages) {
      report({ severity: 'WARN', code: 'max-pages', text: `чтение остановлено по пределу: ${maxPages} страниц (увеличьте limits в настройках, если база большая)` });
      stoppedBy = 'maxPages';
      break;
    }
    const { ex, body } = await fetchPage(cursor, pages + 1);
    pages++;
    if (!ex || ex.error || ex.status !== 200 || !body || typeof body !== 'object') {
      // 200 без JSON-объекта (оборванный JSON, HTML, пустое тело): без находки проверка показала бы «0 записей, ПРОЙДЕНО».
      if (ex && !ex.error && ex.status === 200) {
        report({ severity: 'FAIL', code: 'not-json', text: `страница ${pages}: ответ 200 не JSON-объект — чтение остановлено (подробно — правило E3)` });
      }
      stoppedBy = 'error';
      break;
    }
    pageMs.push(ex.ms);
    const list = Array.isArray(body.items) ? body.items : null;
    if (list === null) {
      report({ severity: 'FAIL', code: 'no-items', text: `страница ${pages}: нет списка items — чтение остановлено` });
      stoppedBy = 'shape';
      break;
    }
    if (sameMessage) {
      if (messageNumber === null) messageNumber = body.messageNumber;
      else if (body.messageNumber !== messageNumber) {
        report({ severity: 'FAIL', code: 'msg-differs', text: `номер сообщения разный на страницах: на первой ${messageNumber}, на странице ${pages} — ${body.messageNumber}` });
      }
    }
    if (list.length > limit) {
      report({ severity: 'FAIL', code: 'over-limit', text: `страница ${pages}: ${list.length} элементов — больше limit=${limit}: 1С не ограничивает страницу` });
    }
    if (hardMax && list.length > hardMax) {
      report({ severity: 'FAIL', code: 'over-hardmax', text: `страница ${pages}: ${list.length} элементов — больше ${hardMax}` });
    }
    for (let i = 0; i < list.length; i++) {
      const it = list[i];
      items++;
      if (keyOf) {
        const k = keyOf(it);
        if (k) {
          const prev = seenKeys.get(k);
          if (prev === undefined) seenKeys.set(k, { page: pages, item: it });
          else {
            const where = `страница ${pages}, items[${i}]`;
            const conflict = conflictOf ? conflictOf(prev.item, it) : null;
            if (dupReported < 5) {
              if (conflict) report({ severity: 'FAIL', code: 'dup-conflict', where, text: `${conflict} (${k}${prev.page !== pages ? `, страницы ${prev.page} и ${pages}` : `, страница ${pages}`})` });
              else if (prev.page !== pages) report({ severity: 'FAIL', code: 'dup-item', where, text: `${itemName} повторяется на страницах ${prev.page} и ${pages} (${k}) — курсор пропускает или повторяет` });
              else report({ severity: 'FAIL', code: 'dup-in-page', where, text: `${itemName} дважды на странице ${pages} (${k}) — одна запись выдана два раза${labels.dupInPage ? `: ${labels.dupInPage}` : ''}` });
            }
            dupReported++;
          }
        }
      }
      if (onItem) onItem(it, pages, i);
    }
    if (list.length === 0 && body.hasMore === true) emptyRun++; else emptyRun = 0;
    if (emptyRun >= 3) {
      report({ severity: 'FAIL', code: 'empty-pages', text: `${emptyRun} пустые страницы подряд с hasMore=true — чтение остановлено` });
      stoppedBy = 'emptyPages';
      break;
    }
    if (body.hasMore === true) {
      if (typeof body.cursor !== 'string' || body.cursor === '') {
        report({ severity: 'FAIL', code: 'no-cursor', text: `страница ${pages}: hasMore=true без cursor — POS не сможет дочитать сообщение` });
        stoppedBy = 'noCursor';
        break;
      }
      if (seenCursors.has(body.cursor)) {
        report({ severity: 'FAIL', code: 'cursor-repeat', text: `страница ${pages}: курсор повторился — чтение остановлено (зацикливание)` });
        stoppedBy = 'cursorRepeat';
        break;
      }
      seenCursors.add(body.cursor);
      cursor = body.cursor;
      continue;
    }
    if (body.hasMore !== false) {
      report({ severity: 'FAIL', code: 'hasmore-type', text: `страница ${pages}: hasMore должно быть true или false` });
    }
    break;
  }
  if (dupReported > 5) report({ severity: 'FAIL', code: 'dup-item-more', text: `ещё ${dupReported - 5} повторов элементов на страницах` });
  return { pages, items, messageNumber, stoppedBy, totalMs: Date.now() - startedAt, pageMs, complete: stoppedBy === null };
}
