// I — картинки GET /pos/v1/images/{ref} (Требования §6.19; обязательный метод: «метода нет» — ОШИБКА).
import { sha256hex } from '../util.mjs';
import { expectPosError, netFailed, statusText, looksAbsent, rnd, absentRequired } from './common.mjs';

const IMG = 'GET /pos/v1/images/{ref}';
const IMG_ABSENT = { what: 'картинки товаров GET /images/{ref}', section: '§6.19', stage: '3 «Чтение»' };

// Путь к файлу на диске или сетевой папке: «D:\1C\…», «\\srv\share\…», «/var/1c/…», «file:///…».
const FS_PATH = /(?<![A-Za-z0-9])[A-Za-z]:[\\/](?:[^\s"'<>|]+)|\\\\[A-Za-z0-9._$-]+\\[^\s"'<>|]+|file:\/\/\/?\S+|(?<![\w.:/])\/(?:home|var|opt|srv|mnt|usr|tmp|1cv8)\/[^\s"'<>]*/i;

/**
 * Контракт GET /images/{ref}: «Путь к файлу на диске 1С в ответе запрещён» — ни в заголовках (Content-Disposition,
 * X-File-Path…), ни в тексте ошибки. Путь в протокол не пишется: в находке — только имя заголовка или поле.
 */
export function imagePathLeak(r, ex) {
  if (!ex || ex.error) return 0;
  let n = 0;
  for (const [h, v0] of Object.entries(ex.headers || {})) {
    if (h === 'set-cookie') continue; // Path= в cookie — путь публикации на веб-сервере, не путь к файлу
    const v = Array.isArray(v0) ? v0.join(', ') : String(v0 ?? '');
    if (FS_PATH.test(v)) {
      r.fail(`в заголовке ${h} ответа ${ex.status} путь к файлу на диске 1С — путь в ответе запрещён (контракт GET /images/{ref}); имя файла отдавайте без пути или не отдавайте`, { code: 'fs-path-header', where: h });
      n++;
    }
  }
  if (ex.status >= 400 && ex.json && typeof ex.json === 'object') {
    const texts = [['message', ex.json.message], ...((ex.json.details && Array.isArray(ex.json.details.lines)) ? ex.json.details.lines.map((l, i) => [`details.lines[${i}].text`, l?.text]) : [])];
    for (const [k, t] of texts) {
      if (typeof t === 'string' && FS_PATH.test(t)) {
        r.fail(`в тексте ошибки (${k}) путь к файлу на диске 1С — путь в ответе запрещён (контракт GET /images/{ref}); пишите «Файл картинки не найден» без пути`, { code: 'fs-path-message', where: k });
        n++;
      }
    }
  }
  return n;
}

export async function runImages(ctx) {
  let etag = null;
  const ref = ctx.data.refs?.imageRef;
  // I3 — первым: несуществующий GUID показывает, есть ли метод вообще.
  await ctx.run('I3', async (r) => {
    const ex = await r.call({ op: IMG, path: `/pos/v1/images/${rnd()}`, image: true, absentProbe: true, noRetry: true, label: 'несуществующий GUID (есть ли метод)' });
    if (netFailed(r, ex, 'несуществующая картинка')) return;
    if (looksAbsent(ctx, ex)) {
      // Метод мог ответить 404 платформы на неизвестный GUID; известная картинка покажет, есть ли метод.
      let present = false;
      if (ref) {
        const ex2 = await r.call({ op: IMG, path: `/pos/v1/images/${ref}`, image: true, absentProbe: true, label: 'картинка из /changes (есть ли метод)' });
        present = !ex2.error && !looksAbsent(ctx, ex2);
        imagePathLeak(r, ex2);
      }
      if (!present) {
        absentRequired(ctx, r, 'I3', IMG_ABSENT);
        return;
      }
    }
    ctx.data.present.add('I3');
    imagePathLeak(r, ex);
    if (expectPosError(r, ex, 404, 'POS_E_NOT_FOUND', 'несуществующая картинка')) r.pass('404 POS_E_NOT_FOUND');
  });
  const noMethod = 'метода картинок нет (I3 — ОШИБКА)';
  await ctx.run('I1', async (r) => {
    if (ctx.data.absent.has('I3')) { r.skip(noMethod); return; }
    if (!ref) { r.skip('в /changes нет картинки (ImageFileChange) — укажите refs.imageRef в настройках или запустите с перерегистрацией'); return; }
    const ex = await r.call({ op: IMG, path: `/pos/v1/images/${ref}`, image: true, label: 'файл картинки' });
    if (netFailed(r, ex, 'картинка')) return;
    imagePathLeak(r, ex);
    if (ex.status !== 200) { r.fail(`картинка ${ref} из /changes: нужен 200, пришёл ${statusText(ex)}`, { code: 'status' }); return; }
    const size = ex.body.length;
    const hash = sha256hex(ex.body);
    const tag = ex.headers.etag;
    r.evidence = { size, sha256: hash, etag: tag || null, contentType: ex.headers['content-type'] || null };
    if (!tag) r.fail('нет заголовка ETag — POS не сможет спрашивать «изменилась ли картинка»', { code: 'no-etag' });
    else {
      const m = /^(W\/)?"(.*)"$/.exec(String(tag).trim());
      if (!m) r.fail(`ETag ${tag} не в кавычках — нужно "<sha256>"`, { code: 'etag-quotes' });
      else {
        if (m[1]) r.warn('ETag слабый (W/…) — нужен сильный "<sha256>"', { code: 'weak' });
        const v = m[2];
        if (/^[0-9a-fA-F]{64}$/.test(v)) {
          if (v.toLowerCase() !== hash) r.fail(`ETag не совпадает с хешем файла: ETag ${v.slice(0, 12)}…, SHA-256 тела ${hash.slice(0, 12)}… — POS отклонит файл`, { code: 'etag-hash' });
        } else if (/^.+-\d+$/.test(v)) {
          r.info('ETag запасного вида "<дата>-<размер>": хеш считает POS (допустимо)', { code: 'etag-fallback' });
        } else r.warn(`ETag неизвестного вида ${String(tag).slice(0, 40)} — нужно "<sha256>" или "<дата>-<размер>"`, { code: 'etag-kind' });
        etag = String(tag).trim();
      }
    }
    const cl = ex.headers['content-length'];
    if (cl === undefined) r.warn('нет заголовка Content-Length', { code: 'no-cl' });
    else if (Number(cl) !== size) r.fail(`Content-Length не совпадает с размером тела: ${cl} и ${size}`, { code: 'cl' });
    const ct = String(ex.headers['content-type'] || '');
    if (!/^image\//i.test(ct) && !/^application\/octet-stream/i.test(ct)) r.fail(`Content-Type «${ct || 'нет'}» — нужен image/* или application/octet-stream`, { code: 'ct' });
    const expected = ctx.data.refs?.imageSize;
    if (Number.isInteger(expected) && expected !== size) r.fail(`размер файла ${size} байт не равен size элемента /changes (${expected}) — POS отклонит файл`, { code: 'size' });
    if (size > ctx.contract.imageMaxBytes()) r.warn(`файл больше 10 МБ (${size} байт) — POS его не обработает`, { code: 'big' });
    r.pass(`${size} байт, ETag ${etag && /^"[0-9a-f]{64}"$/.test(etag) ? '= SHA-256 тела' : (etag || 'нет')}`);
  });
  await ctx.run('I2', async (r) => {
    if (ctx.data.absent.has('I3')) { r.skip(noMethod); return; }
    if (!ref || !etag) { r.skip(ref ? 'нет ETag из I1' : 'нет картинки'); return; }
    const ex = await r.call({ op: IMG, path: `/pos/v1/images/${ref}`, image: true, headers: { 'If-None-Match': etag }, label: 'If-None-Match' });
    if (netFailed(r, ex, 'повтор с If-None-Match')) return;
    imagePathLeak(r, ex);
    if (ex.status === 200) { r.fail('If-None-Match с тем же ETag → снова 200: нужен 304 без тела', { code: '200' }); return; }
    if (ex.status !== 304) { r.fail(`нужен 304, пришёл ${statusText(ex)}`, { code: 'status' }); return; }
    if (ex.body.length) r.fail(`304 с телом (${ex.body.length} байт) — нужен 304 без тела`, { code: 'body' });
    const tag304 = ex.headers.etag;
    if (!tag304) r.warn('304 без заголовка ETag', { code: 'no-etag' });
    // Контракт: у 304 заголовок ETag — «Текущий ETag»; If-None-Match совпал с текущим, значит, это тот же ETag, что у 200.
    else if (String(tag304).trim() !== etag) r.fail(`304 с другим ETag: ${String(tag304).slice(0, 70)}, а у файла (I1) — ${etag.slice(0, 70)}: 304 значит «файл не изменился», ETag тот же (контракт: ETag ответа 304 — текущий ETag)`, { code: 'etag-304' });
    r.pass('304 без тела');
  });
}
