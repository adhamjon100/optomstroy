/*
 * Оптомстрой POS · веб-демо · переключение «планшет магазина ↔ обычный вход» (P-002 TAB-3-02, ADR-115; 10 AC-KIOSK-027;
 * 12 T-KIOSK-051, вне релизных ворот — §3.22, §3.23).
 *
 * Логика приложения не меняется (ADR-113 DM-01): страница работает со своим хранилищем, как сброс демо (demo-reset.js).
 * Приложение на web держит данные входа и признак планшета в localStorage (flutter_secure_storage_web 2.1.1, параметры
 * по умолчанию pos-app/lib/core/storage/secure_storage.dart): ключ AES-GCM `FlutterSecureStorage` и зашифрованные
 * значения `FlutterSecureStorage.<SecureKey>`. Страница значения не расшифровывает — только переносит строки.
 *
 *  - Переносимый набор — все ключи `FlutterSecureStorage.*`, КРОМЕ `FlutterSecureStorage.device.id` (X-Device-Id: на
 *    сервере это device_key планшета, другой ключ дал бы DEVICE_MISMATCH) и самого ключа AES (общий для обоих мест).
 *  - Два места хранения: `optomstroy.demo.kioskSlot.kiosk` и `.normal` — JSON {v, at, epochKey, aes, dev, count, items,
 *    page?} (page — только у места «обычный вход», см. ниже); aes и dev — отпечатки (SHA-256, 16 знаков) ключа AES
 *    и значения device.id на момент переноса.
 *  - Признак режима — наличие ключа `FlutterSecureStorage.kiosk.tablet_id` (SecureKey.kioskTabletId). Имена ключей
 *    сверяет tools/check-site.mjs с main.dart.js сборки.
 *  - Переключение запрашивает панель (P.boot.kioskSwitch): флаг `optomstroy.demo.kioskSwitch` {to} → остановка воркера →
 *    перезагрузка. Применяется при загрузке страницы (atBoot, demo-boot.js) после замка, сброса и проверки эпохи, ДО
 *    запуска воркера и Flutter: пока приложение работает, его хранилище не трогается (оно меняет refresh-токен).
 *      to = 'normal'  — данные планшета → место «планшет»; данные обычного входа (если отложены) → обратно;
 *      to = 'kiosk'   — данные обычного входа → место «обычный вход»; данные планшета → обратно (тот же планшет, тот же
 *                       store_tablets.id, подключать заново не нужно). Отложенных данных нет или они негодны — ничего
 *                       не меняется, панель предлагает подключить заново;
 *      to = 'reconnect' — «Подключить этот браузер заново»: данные планшета удаляются (device.id и ключ AES остаются),
 *                       данные обычного входа откладываются; дальше — вход администратором → SCR-54 «Подключить заново
 *                       этот планшет» (сервер находит запись: та же строка store_tablets, новый аварийный код).
 *  - Место хранения негодно (удаляется при загрузке): эпоха данных демо сменилась, сменился ключ AES (значения не
 *    расшифровать) или device.id, запись испорчена. «Сбросить демо» очищает localStorage целиком вместе с базой
 *    PGlite: прежнего планшета нет ни в браузере, ни на сервере — только первое подключение (новый store_tablets.id).
 *  - Перед уходом из режима планшета страница имитирует гашение экрана (visibilitychange → hidden): приложение само
 *    сбрасывает корзину планшета (FLOW-045.S6, POST /kiosk/reset), поэтому после возврата корзина пуста.
 *  - Вход по лицу через passkey (15 ADR-116 п. 1, п. 5; BIO-037; 12 T-DEMO-022): блоб привязки
 *    `optomstroy.demo.passkeyBound` (biometric_refresh пользователя под ключом из PRF, demo-passkey.js) — данные
 *    обычного входа. Он переносится только вместе с местом «обычный вход» (поле `page` места, рядом с `items`) и
 *    возвращается вместе с ним; в место «планшет» не попадает. Блоб, найденный в режиме планшета при переключении,
 *    удаляется: планшет биометрию не использует, подключение планшета снимает биометрию администратора. Записи браузера
 *    — passkey гейта (`passkeyGate`), user.id passkey (`passkeyUser`), ключи входа браузера на Windows по owner
 *    (`passkeyHelloKey`), признак «PRF нет» (`passkeyNoPrf`) — не переносятся: они принадлежат браузеру, а не входу,
 *    и без refresh-токена своего пользователя сессию не открывают.
 * Значения ключей нигде не показываются и не журналируются: в результатах — только числа и причины.
 */
(function (global) {
  'use strict';

  var P = global.PosDemoPage = global.PosDemoPage || {};
  var K = P.KEYS;
  var doc = global.document;

  // Имена хранилища приложения (проверяются по main.dart.js в tools/check-site.mjs).
  var AES_KEY = 'FlutterSecureStorage';
  var PREFIX = AES_KEY + '.';
  var DEVICE_KEY = PREFIX + 'device.id';
  var FLAG_KEY = PREFIX + 'kiosk.tablet_id';
  var SLOT = { kiosk: K.kioskSlotKiosk, normal: K.kioskSlotNormal };
  // Ключи страницы, которые принадлежат обычному входу и переезжают с местом «обычный вход» (ADR-116 п. 1).
  var PAGE_KEYS = [K.passkeyBound].filter(Boolean);
  var MODES = ['normal', 'kiosk', 'reconnect'];
  // Простой планшета, после которого сервер попросит подключить заново (09 §8.9; 08 §4.18.15).
  var IDLE_MS = 7 * 24 * 3600 * 1000;

  var REASON = {
    missing: 'данных планшета в этом браузере нет',
    broken: 'отложенная запись повреждена',
    epoch: 'данные демо начались заново',
    aes: 'сменился ключ хранилища браузера — данные не расшифровать',
    device: 'сменился идентификатор этого браузера',
    quota: 'браузеру не хватило места в хранилище страницы',
    storage: 'хранилище страницы недоступно',
    not_tablet: 'этот браузер уже на обычном входе',
    already: 'этот браузер уже планшет магазина',
  };

  var state = { result: null };

  function area() {
    try {
      return global.localStorage || null;
    } catch (e) {
      return null;
    }
  }

  function available() {
    return !!(P.store && P.store.available && area());
  }

  function get(key) {
    var s = area();
    try {
      return s ? s.getItem(key) : null;
    } catch (e) {
      return null;
    }
  }

  function isTablet() {
    return get(FLAG_KEY) !== null;
  }

  // Ключи переносимого набора: всё под префиксом приложения, кроме device.id (ключ AES под префикс не попадает).
  function liveKeys() {
    var s = area();
    var out = [];
    if (!s) return out;
    try {
      for (var i = 0; i < s.length; i++) {
        var k = s.key(i);
        if (k && k.indexOf(PREFIX) === 0 && k !== DEVICE_KEY) out.push(k);
      }
    } catch (e) { /* ignore */ }
    return out.sort();
  }

  // Ключи страницы обычного входа, которые сейчас есть в хранилище (блоб passkey).
  function livePageKeys() {
    return PAGE_KEYS.filter(function (k) { return P.store.get(k) !== null; });
  }

  function removePageKeys() {
    PAGE_KEYS.forEach(function (k) { P.store.remove(k); });
  }

  function readSlot(name) {
    var raw = P.store.get(SLOT[name]);
    if (!raw) return null;
    try {
      var j = JSON.parse(raw);
      if (j && j.v === 1 && j.items && typeof j.items === 'object') return j;
    } catch (e) { /* ниже */ }
    return { broken: true };
  }

  // Сведения для панели — без значений ключей.
  function slotInfo(name) {
    var slot = readSlot(name);
    if (!slot) return null;
    if (slot.broken) return { broken: true };
    var keys = Object.keys(slot.items);
    var page = slot.page && typeof slot.page === 'object' ? slot.page : {};
    return {
      at: slot.at || null,
      count: keys.length,
      tablet: keys.indexOf(FLAG_KEY) >= 0,
      session: keys.indexOf(PREFIX + 'auth.refresh_token') >= 0,
      bound: !!K.passkeyBound && typeof page[K.passkeyBound] === 'string', // отложен блоб passkey (без значения)
      stale: !!slot.at && Date.now() - slot.at > IDLE_MS,
    };
  }

  // ---------------------------------------------------------------- отпечатки
  function hex(buf) {
    var b = new Uint8Array(buf);
    var s = '';
    for (var i = 0; i < b.length; i++) s += (b[i] < 16 ? '0' : '') + b[i].toString(16);
    return s;
  }

  function fnv(value) {
    var h = 0x811c9dc5;
    for (var i = 0; i < value.length; i++) {
      h ^= value.charCodeAt(i);
      h = Math.imul(h, 0x01000193) >>> 0;
    }
    return 'f' + ('0000000' + h.toString(16)).slice(-8);
  }

  // Отпечаток строки (SHA-256, первые 16 знаков; без WebCrypto — FNV-1a): только для сравнения «то же значение».
  function fingerprint(value) {
    if (value === null || value === undefined) return Promise.resolve('none');
    var subtle = global.crypto && global.crypto.subtle;
    if (!subtle || typeof global.TextEncoder !== 'function') return Promise.resolve(fnv(String(value)));
    return subtle.digest('SHA-256', new global.TextEncoder().encode(String(value))).then(function (d) {
      return hex(d).slice(0, 16);
    }, function () {
      return fnv(String(value));
    });
  }

  function currentEnv(build) {
    return Promise.all([fingerprint(get(AES_KEY)), fingerprint(get(DEVICE_KEY))]).then(function (fp) {
      return { epochKey: (build && build.epochKey) || null, aes: fp[0], dev: fp[1] };
    });
  }

  function invalid(slot, env) {
    if (slot.broken) return 'broken';
    if (env.epochKey && slot.epochKey !== env.epochKey) return 'epoch';
    if (slot.aes !== env.aes) return 'aes';
    if (slot.dev !== env.dev) return 'device';
    return null;
  }

  // ---------------------------------------------------------------- перенос
  // Набор ключей → место хранения name. Сначала запись места, потом удаление из хранилища приложения: при сбое записи
  // (квота) ничего не теряется.
  // Месту «обычный вход» достаются и ключи страницы обычного входа (блоб passkey, поле page; ADR-116 п. 1).
  function stash(name, keys, env) {
    var items = {};
    keys.forEach(function (k) {
      var v = get(k);
      if (v !== null) items[k] = v;
    });
    var pageKeys = name === 'normal' ? livePageKeys() : [];
    var slot = { v: 1, at: Date.now(), epochKey: env.epochKey, aes: env.aes, dev: env.dev, count: Object.keys(items).length, items: items };
    if (pageKeys.length) {
      slot.page = {};
      pageKeys.forEach(function (k) { slot.page[k] = P.store.get(k); });
    }
    if (!P.store.set(SLOT[name], JSON.stringify(slot))) return false;
    removeKeys(keys);
    pageKeys.forEach(function (k) { P.store.remove(k); });
    return true;
  }

  // Уход с обычного входа (to = 'kiosk' или 'reconnect'): живые данные обычного входа → место «обычный вход». Данных
  // приложения нет — прежнее место не затирается (как раньше); одинокий блоб passkey без сессии при этом удаляется,
  // если место уже занято, иначе откладывается — в режиме планшета блоба быть не должно (BIO-037).
  // Результат: -1 — запись места не удалась (квота); иначе число удалённых ключей страницы (0 или больше).
  function stashNormal(keys, env) {
    if (keys.length) return stash('normal', keys, env) ? 0 : -1;
    var n = livePageKeys().length;
    if (!n) return 0;
    if (readSlot('normal')) {
      removePageKeys();
      return n;
    }
    return stash('normal', keys, env) ? 0 : -1;
  }

  // Режим планшета: ключи страницы обычного входа здесь лишние (планшет биометрию не использует, ADR-116 п. 5) —
  // удаляются. Возвращает их число.
  function dropTabletPageKeys() {
    var n = livePageKeys().length;
    if (n) removePageKeys();
    return n;
  }

  function removeKeys(keys) {
    var s = area();
    keys.forEach(function (k) {
      try {
        s.removeItem(k);
      } catch (e) { /* ignore */ }
    });
  }

  // Место хранения name → хранилище приложения; место удаляется. Возвращает число восстановленных ключей приложения
  // (ключи страницы — блоб passkey места «обычный вход» — возвращаются, но не считаются: «вернулся прежний вход»
  // говорит только о данных приложения).
  function restore(name) {
    var slot = readSlot(name);
    if (!slot || slot.broken) return 0;
    var s = area();
    var n = 0;
    Object.keys(slot.items).forEach(function (k) {
      if (k.indexOf(PREFIX) !== 0 || k === DEVICE_KEY) return; // только переносимый набор
      try {
        s.setItem(k, String(slot.items[k]));
        n++;
      } catch (e) { /* ignore */ }
    });
    var page = name === 'normal' && slot.page && typeof slot.page === 'object' ? slot.page : {};
    Object.keys(page).forEach(function (k) {
      if (PAGE_KEYS.indexOf(k) >= 0 && typeof page[k] === 'string') P.store.set(k, page[k]);
    });
    P.store.remove(SLOT[name]);
    return n;
  }

  function apply(to, env) {
    var keys = liveKeys();
    var dropped;
    if (to === 'normal') {
      if (!isTablet()) return { ok: false, reason: 'not_tablet' };
      if (!stash('kiosk', keys, env)) return { ok: false, reason: 'quota' };
      dropped = dropTabletPageKeys();
      return { ok: true, moved: keys.length, restored: restore('normal'), boundDropped: dropped };
    }
    if (to === 'kiosk') {
      if (isTablet()) return { ok: false, reason: 'already' };
      if (!readSlot('kiosk')) return { ok: false, reason: 'missing' };
      dropped = stashNormal(keys, env);
      if (dropped < 0) return { ok: false, reason: 'quota' };
      return { ok: true, moved: keys.length, restored: restore('kiosk'), boundDropped: dropped };
    }
    // reconnect
    if (isTablet()) {
      removeKeys(keys);
      P.store.remove(SLOT.kiosk);
      dropped = dropTabletPageKeys();
      return { ok: true, discarded: keys.length, moved: 0, restored: 0, boundDropped: dropped };
    }
    dropped = stashNormal(keys, env);
    if (dropped < 0) return { ok: false, reason: 'quota' };
    P.store.remove(SLOT.kiosk);
    return { ok: true, discarded: 0, moved: keys.length, restored: 0, boundDropped: dropped };
  }

  // ---------------------------------------------------------------- запрос и применение
  function request(to) {
    if (MODES.indexOf(to) < 0 || !available()) return false;
    return P.store.set(K.kioskSwitch, JSON.stringify({ to: to, at: Date.now() }));
  }

  function pending() {
    var raw = P.store.get(K.kioskSwitch);
    if (!raw) return null;
    try {
      var j = JSON.parse(raw);
      return j && MODES.indexOf(j.to) >= 0 ? j : null;
    } catch (e) {
      return null;
    }
  }

  // При загрузке страницы, до воркера и Flutter: проверка мест хранения и отложенное переключение.
  // Результат (без значений): null — ничего не было; иначе {to, ok, reason?, moved, restored, discarded, dropped[], mode}.
  function atBoot(build) {
    var req = pending();
    if (P.store) P.store.remove(K.kioskSwitch);
    if (!available()) {
      state.result = req ? { to: req.to, ok: false, reason: 'storage', dropped: [], mode: 'normal' } : null;
      return Promise.resolve(state.result);
    }
    return currentEnv(build).then(function (env) {
      var dropped = [];
      ['kiosk', 'normal'].forEach(function (name) {
        var slot = readSlot(name);
        if (!slot) return;
        var why = invalid(slot, env);
        if (why) {
          P.store.remove(SLOT[name]);
          dropped.push({ slot: name, reason: why });
        }
      });
      var r = null;
      if (req) {
        r = apply(req.to, env);
        if (!r.ok && r.reason === 'missing') {
          var d = dropped.filter(function (x) { return x.slot === 'kiosk'; })[0];
          if (d) r.reason = d.reason;
        }
        r.to = req.to;
      } else if (dropped.length) {
        r = { to: null, ok: true };
      }
      if (r) {
        r.dropped = dropped;
        r.mode = isTablet() ? 'kiosk' : 'normal';
      }
      state.result = r;
      return r;
    });
  }

  // ---------------------------------------------------------------- перед перезагрузкой
  function sleep(ms) {
    return new Promise(function (r) { setTimeout(r, ms); });
  }

  // Ждём, пока у моста не останется запросов приложения (не меньше minMs, не дольше maxMs): ответ ротации refresh-токена
  // успевает записаться в хранилище до перезагрузки.
  function waitIdle(bridge, minMs, maxMs) {
    var t0 = Date.now();
    var quiet = 0;
    var tick = function () {
      var busy = bridge && typeof bridge._pendingCount === 'function' ? bridge._pendingCount() : 0;
      quiet = busy ? 0 : quiet + 1;
      var dt = Date.now() - t0;
      if (dt >= maxMs || (dt >= minMs && quiet >= 2)) return Promise.resolve({ ms: dt, busy: busy });
      return sleep(150).then(tick);
    };
    return tick();
  }

  // Имитация гашения экрана планшета: приложение получает AppLifecycleState.hidden и само сбрасывает корзину планшета
  // (FLOW-045.S6). Свойства документа переопределяются только на эту вкладку до перезагрузки.
  function screenOff(bridge) {
    try {
      Object.defineProperty(doc, 'visibilityState', { configurable: true, get: function () { return 'hidden'; } });
      Object.defineProperty(doc, 'hidden', { configurable: true, get: function () { return true; } });
      doc.dispatchEvent(new global.Event('visibilitychange'));
    } catch (e) {
      return Promise.resolve({ ok: false });
    }
    return waitIdle(bridge, 900, 4000).then(function (r) {
      r.ok = true;
      return r;
    });
  }

  function reasonText(code) {
    return REASON[code] || code || 'неизвестная причина';
  }

  // Короткий итог переключения для всплывающей подсказки после загрузки.
  function resultText(r) {
    if (!r || !r.to) return null;
    if (!r.ok) {
      if (r.to === 'kiosk') return 'Планшет магазина вернуть не удалось: ' + reasonText(r.reason) + '. «ДЕМО» → «Планшет магазина» → «Подключить этот браузер заново».';
      return 'Переключить не удалось: ' + reasonText(r.reason) + '.';
    }
    if (r.to === 'normal') return r.restored ? 'Обычный вход: вернулся прежний вход. Планшет магазина отложен.' : 'Обычный вход: войдите своим номером. Планшет магазина отложен.';
    if (r.to === 'kiosk') return 'Этот браузер снова планшет магазина — тот же планшет, подключать заново не нужно.';
    return (r.discarded ? 'Данные планшета в этом браузере удалены.' : 'Текущий вход отложен.') + ' Войдите администратором → «Планшеты магазина» → «Подключить заново этот планшет».';
  }

  P.kiosk = {
    FLAG_KEY: FLAG_KEY,
    DEVICE_KEY: DEVICE_KEY,
    AES_KEY: AES_KEY,
    available: available,
    isTablet: isTablet,
    slotInfo: slotInfo,
    request: request,
    pending: pending,
    atBoot: atBoot,
    waitIdle: waitIdle,
    screenOff: screenOff,
    reasonText: reasonText,
    resultText: resultText,
    get result() { return state.result; },
  };
})(window);
