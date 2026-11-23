/*
 * Оптомстрой POS · веб-демо · вход по лицу или отпечатку через passkey (WebAuthn) — шлюз страницы для приложения
 * (15 ADR-116 п. 1, п. 4; 09 §9.2 «Веб-демо», BIO-035, BIO-041; 07 §11.1 п. 4; 11 §8.1; 12 T-DEMO-015).
 *
 * Только демо-сборка (ADR-113, DM-01): продукт web биометрии не имеет. Dart-обёртка — WebPasskeyAuthenticator
 * (pos-app/lib/app/demo/demo_passkey*.dart, четвёртое переопределение demoOverrides). Классический скрипт ES2017, как
 * demo-env.js: без модулей, без `?.`/`??`. Подключается после demo-env.js (PosDemoPage.store, PosDemoPage.KEYS) и до
 * demo-boot.js.
 *
 * Режим выбирает приложение по browserDevicePlatform; платформу страница сама не определяет:
 *   'bound' — браузер не на Windows: секрет biometric_refresh шифруется AES-256-GCM ключом HKDF-SHA-256 из выхода PRF
 *             passkey; сервер видит android + class3 и не меняется. Без PRF вариант скрыт.
 *   'gate'  — браузер на Windows. Passkey браузера служит:
 *             (а) при PRF — ключом входа без PIN (BIO-041): пара RSA-2048 WebCrypto (RSASSA-PKCS1-v1_5, SHA-256),
 *                 закрытый ключ (PKCS#8) под AES-256-GCM из PRF, подпись challenge сервера → POST /auth/unlock
 *                 {method: hello_key}; открытый ключ — POST /me/biometrics {helloKey.source: 'webauthn_prf'};
 *             (б) без PRF у браузера или у Windows Hello — гейтом перед PIN приложения (как W1): confirmPresence.
 *                 Ограничение записано в честном списке 09 §9.4; PRF самого Windows Hello — [НЕ ПРОВЕРЕНО: T-DEMO-021].
 *
 * Протокол 1 — globalThis.__posPasskey. Каждый метод возвращает Promise простого объекта и не бросает исключений.
 * Ошибки — коды канала криптопривязки (biometric_crypto_channel.dart): cancelled | invalidated | not_available |
 * no_credential | failed (lockout и not_enrolled браузер не сообщает).
 *   capability({mode})        → {kind, availability, cryptoBinding, reason?, keysSupported, prf}
 *                                kind: android_class3 (bound) | windows_hello (gate) | none; prf: yes | no | unknown
 *   store({secret, owner})    → {ok:true} | {ok:false, error, reason?}  — включение: create() с PRF (иногда + get())
 *   read({owner})             → {ok:true, value} | {ok:false, error}    — один диалог get()
 *   replace({secret, owner})  → {ok:true} | {ok:false, error}           — не позже 60 с после read() без диалога
 *   has({owner})              → {ok:true, value: boolean}               — есть блоб этого пользователя
 *   clear({mode})             → {ok:true}                               — хук очистки сессии
 *   confirmPresence()         → {ok:true} | {ok:false, error}           — гейт: get(), первый раз create()
 *   createKey({owner})        → {ok:true, value: SPKI, algorithm: 'RS256', source: 'webauthn_prf'}
 *                              | {ok:false, error, reason?: 'no_prf', gate?: true}
 *   sign({owner, challenge})  → {ok:true, value: подпись} | {ok:false, error}
 *   deleteKey({owner})        → {ok:true, value: boolean}               — без диалога
 *   hasKey({owner})           → {ok:true, value: boolean}
 * SPKI и подпись — base64url без «=» (как у канала kg.optomstroy/windows_hello и в 08 §4.1.10). owner — userId из
 * кэша профиля (02 §0.4); страница хранит только отпечаток: первые 16 знаков hex SHA-256 от userId строчными.
 *
 * Хранилище страницы (07 §11.1 п. 4; ключи — PosDemoPage.KEYS в demo-env.js). Секретов, выхода PRF и закрытого ключа в
 * открытом виде нет:
 *   passkeyUser     — user.id passkey: 16 случайных байт на браузер (повторный create() заменяет прежний ключ);
 *   passkeyGate     — {v:1, credId}: passkey браузера (гейт и ключ входа); очистка сессии его не трогает;
 *   passkeyBound    — {v:1, credId, owner, iv, ct}: biometric_refresh под ключом из PRF;
 *   passkeyHelloKey — {v:1, items: {<owner>: {credId, iv, ct}}}: закрытые ключи входа браузера на Windows; выход их
 *                     не удаляет (ключ переживает выход, BIO-040), удаляют deleteKey и «Сбросить демо»;
 *   passkeyNoPrf    — {v:1}: этот браузер или его аутентификатор PRF не дают (prf.enabled !== true или нет результата).
 * Ключ AES: HKDF-SHA-256 (соль — 32 нулевых байта, info по назначению) из выхода PRF; IV 12 байт; AAD
 * `optomstroy-demo/v1|<rpId>|<credId>|<owner>|<назначение>`. Ключ неизвлекаемый; после успешного read() он
 * держится в замыкании не дольше 60 с и только для replace() — один диалог на разблокировку (ADR-116 п. 1).
 *
 * Защита демонстрационная: JWT-ключи и база демо — в хранилище того же origin (ADR-113 п. 3). Проверку пользователя
 * может пройти PIN устройства; удалённый в ОС passkey выглядит как отмена (NotAllowedError). В журнал консоли идут
 * только код исхода и имя исключения — без значений.
 */
(function (global) {
  'use strict';

  var P = global.PosDemoPage = global.PosDemoPage || {};

  var PROTOCOL = 1;
  var RP_NAME = 'Оптомстрой POS (демо)';
  var USER_NAME = 'optomstroy-demo';
  // Вход PRF (eval.first) — один на passkey: назначения разделяет info HKDF.
  var PRF_INPUT = 'optomstroy-demo:biometric_refresh:v1';
  var INFO = {
    bound: 'optomstroy-demo/biometric_refresh/aes-256-gcm/v1',
    key: 'optomstroy-demo/hello_key/aes-256-gcm/v1',
  };
  var PURPOSE = { bound: 'biometric_refresh', key: 'hello_key' };
  // Ключ входа подписывает только challenge сервера (08 §4.1.10; так же проверяет натив Windows).
  var CHALLENGE_PREFIX = 'optomstroy-hello-unlock/v1:';
  var CHALLENGE_MAX = 96;
  var KEY_TTL_MS = 60000;
  var TIMEOUT_MS = 60000;
  var MAX_SECRET = 16384;
  var MAX_OWNER = 256;
  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  var RSA = { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' };

  // Неизвлекаемый ключ AES из последнего успешного read(): {key, credId, owner, rpId, until, timer} (C-03 критики).
  var cache = null;
  // Идёт системный диалог WebAuthn: второй вызов не открывает ещё один (автодиалог SCR-08 и кнопка).
  var busy = false;

  // ------------------------------------------------------------------ окружение

  function now() {
    return global.Date.now();
  }

  function keys() {
    var k = P.KEYS;
    return k && k.passkeyUser && k.passkeyGate && k.passkeyBound && k.passkeyHelloKey && k.passkeyNoPrf ? k : null;
  }

  function storeReady() {
    return !!(P.store && P.store.available && keys());
  }

  function webauthn() {
    var nav = global.navigator;
    var pkc = global.PublicKeyCredential;
    if (global.isSecureContext !== true || !pkc || !nav || !nav.credentials) return null;
    if (typeof nav.credentials.create !== 'function' || typeof nav.credentials.get !== 'function') return null;
    if (!global.crypto || !global.crypto.subtle || typeof global.crypto.getRandomValues !== 'function') return null;
    return { nav: nav, pkc: pkc };
  }

  function rpId() {
    try {
      return String(global.location.hostname || '');
    } catch (e) {
      return '';
    }
  }

  function note(op, code, cause) {
    try {
      global.console.info('[demo-passkey] ' + op + ': ' + code + (cause ? ' (' + cause + ')' : ''));
    } catch (e) { /* ignore */ }
  }

  function errName(e) {
    var n = e && e.name;
    return typeof n === 'string' && /^[A-Za-z]{1,40}$/.test(n) ? n : 'Error';
  }

  // ------------------------------------------------------------------ байты

  function toBytes(x) {
    if (!x) return null;
    if (ArrayBuffer.isView(x)) return new Uint8Array(x.buffer, x.byteOffset, x.byteLength);
    if (Object.prototype.toString.call(x) === '[object ArrayBuffer]') return new Uint8Array(x);
    return null;
  }

  function copyBytes(x) {
    var b = toBytes(x);
    return b ? new Uint8Array(b) : null;
  }

  function wipe(b) {
    try {
      if (b) b.fill(0);
    } catch (e) { /* ignore */ }
  }

  function utf8(s) {
    return new global.TextEncoder().encode(String(s));
  }

  function fromUtf8(b) {
    return new global.TextDecoder('utf-8', { fatal: true }).decode(b);
  }

  function random(n) {
    return global.crypto.getRandomValues(new Uint8Array(n));
  }

  function b64u(x) {
    var b = toBytes(x) || new Uint8Array(0);
    var out = '';
    var i = 0;
    var n;
    for (; i + 2 < b.length; i += 3) {
      n = (b[i] << 16) | (b[i + 1] << 8) | b[i + 2];
      out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] + B64[(n >> 6) & 63] + B64[n & 63];
    }
    if (b.length - i === 1) {
      n = b[i] << 16;
      out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63];
    } else if (b.length - i === 2) {
      n = (b[i] << 16) | (b[i + 1] << 8);
      out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] + B64[(n >> 6) & 63];
    }
    return out;
  }

  function unb64u(s) {
    if (typeof s !== 'string' || !/^[A-Za-z0-9_-]*$/.test(s) || s.length % 4 === 1) return null;
    var out = new Uint8Array(Math.floor((s.length * 3) / 4));
    var acc = 0;
    var bits = 0;
    var j = 0;
    for (var i = 0; i < s.length; i++) {
      acc = (acc << 6) | B64.indexOf(s.charAt(i));
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out[j++] = (acc >> bits) & 255;
        acc &= (1 << bits) - 1;
      }
    }
    return out;
  }

  function isB64u(s, min) {
    return typeof s === 'string' && s.length >= (min || 1) && s.length <= 8192 && unb64u(s) !== null;
  }

  async function ownerTag(owner) {
    if (typeof owner !== 'string') return null;
    var o = owner.trim().toLowerCase();
    if (!o || o.length > MAX_OWNER) return null;
    var d = new Uint8Array(await global.crypto.subtle.digest('SHA-256', utf8(o)));
    var hex = '';
    for (var i = 0; i < 8; i++) hex += (d[i] < 16 ? '0' : '') + d[i].toString(16);
    return hex;
  }

  // ------------------------------------------------------------------ хранилище страницы

  function readJson(key) {
    var raw = P.store.get(key);
    if (!raw) return null;
    try {
      var v = JSON.parse(raw);
      return v && typeof v === 'object' ? v : null;
    } catch (e) {
      return null;
    }
  }

  function writeJson(key, value) {
    return P.store.set(key, JSON.stringify(value)) === true;
  }

  function gateRecord() {
    var g = readJson(keys().passkeyGate);
    return g && g.v === 1 && isB64u(g.credId, 16) ? g : null;
  }

  function sealedOk(x) {
    return !!x && isB64u(x.credId, 16) && isB64u(x.iv, 16) && isB64u(x.ct, 22);
  }

  function boundBlob() {
    var b = readJson(keys().passkeyBound);
    return b && b.v === 1 && typeof b.owner === 'string' && /^[0-9a-f]{16}$/.test(b.owner) && sealedOk(b) ? b : null;
  }

  function keyItems() {
    var k = readJson(keys().passkeyHelloKey);
    var items = {};
    if (k && k.v === 1 && k.items && typeof k.items === 'object') {
      Object.keys(k.items).forEach(function (t) {
        if (/^[0-9a-f]{16}$/.test(t) && sealedOk(k.items[t])) items[t] = k.items[t];
      });
    }
    return items;
  }

  function writeKeyItems(items) {
    if (Object.keys(items).length === 0) {
      P.store.remove(keys().passkeyHelloKey);
      return true;
    }
    return writeJson(keys().passkeyHelloKey, { v: 1, items: items });
  }

  function noPrfMarked() {
    var m = readJson(keys().passkeyNoPrf);
    return !!(m && m.v === 1);
  }

  function markNoPrf(on) {
    if (on) writeJson(keys().passkeyNoPrf, { v: 1 });
    else P.store.remove(keys().passkeyNoPrf);
  }

  // user.id passkey — стабильный на браузер: новый create() заменяет прежний passkey, а не копит «сирот» (map-web §3).
  function browserUserId() {
    var id = unb64u(P.store.get(keys().passkeyUser) || '');
    if (id && id.length === 16) return id;
    id = random(16);
    P.store.set(keys().passkeyUser, b64u(id));
    return id;
  }

  function signalUnknown(credId) {
    try {
      var pkc = global.PublicKeyCredential;
      if (!pkc || typeof pkc.signalUnknownCredential !== 'function') return Promise.resolve(false);
      return Promise.resolve(pkc.signalUnknownCredential({ rpId: rpId(), credentialId: credId }))
        .then(function () { return true; }, function () { return false; });
    } catch (e) {
      return Promise.resolve(false);
    }
  }

  // ------------------------------------------------------------------ ключ AES в памяти (≤ 60 с)

  function forget() {
    if (cache && cache.timer !== null) {
      try {
        global.clearTimeout(cache.timer);
      } catch (e) { /* ignore */ }
    }
    cache = null;
  }

  function remember(key, credId, owner) {
    forget();
    var c = { key: key, credId: credId, owner: owner, rpId: rpId(), until: now() + KEY_TTL_MS, timer: null };
    try {
      c.timer = global.setTimeout(function () {
        if (cache === c) cache = null;
      }, KEY_TTL_MS);
    } catch (e) {
      c.timer = null;
    }
    cache = c;
  }

  function cachedKey(credId, owner) {
    if (!cache) return null;
    if (now() >= cache.until || cache.rpId !== rpId()) {
      forget();
      return null;
    }
    return cache.credId === credId && cache.owner === owner ? cache.key : null;
  }

  // ------------------------------------------------------------------ WebAuthn

  function mapError(e) {
    switch (errName(e)) {
      case 'NotAllowedError': // отмена, тайм-аут, проверка не пройдена, окно не в фокусе, passkey удалён в ОС
      case 'AbortError':
        return 'cancelled';
      case 'SecurityError': // недопустимый rpId (например, адрес 127.0.0.1)
      case 'NotSupportedError':
        return 'not_available';
      default: // InvalidStateError и прочее
        return 'failed';
    }
  }

  function uvFlag(authData) {
    var b = toBytes(authData);
    return !!(b && b.length > 32 && (b[32] & 0x04) !== 0);
  }

  function prfOf(cred) {
    var ext = null;
    try {
      ext = typeof cred.getClientExtensionResults === 'function' ? cred.getClientExtensionResults() : null;
    } catch (e) {
      ext = null;
    }
    var prf = ext && ext.prf;
    var first = prf && prf.results ? copyBytes(prf.results.first) : null;
    return { enabled: prf ? prf.enabled : undefined, first: first && first.length >= 16 ? first : null };
  }

  async function ceremony(kind, publicKey) {
    var w = webauthn();
    if (!w) return { error: 'not_available', cause: 'no_webauthn' };
    if (busy) return { error: 'cancelled', cause: 'busy' };
    busy = true;
    try {
      var cred = kind === 'create'
        ? await w.nav.credentials.create({ publicKey: publicKey })
        : await w.nav.credentials.get({ publicKey: publicKey });
      if (!cred || !cred.rawId || !cred.response) return { error: 'cancelled', cause: 'null' };
      return { cred: cred };
    } catch (e) {
      return { error: mapError(e), cause: errName(e) };
    } finally {
      busy = false;
    }
  }

  // Создать passkey браузера. PRF запрашивается всегда: включить его у ключа можно только при создании, а один passkey
  // служит и гейтом, и ключом входа (решение исполнителя LF-3-01).
  async function createCredential() {
    var r = await ceremony('create', {
      rp: { name: RP_NAME }, // rp.id не задаётся — это hostname страницы
      user: { id: browserUserId(), name: USER_NAME, displayName: RP_NAME }, // без телефона и ФИО
      challenge: random(32), // сервер RP нет: опора — PRF и проверка пользователя
      pubKeyCredParams: [{ type: 'public-key', alg: -7 }, { type: 'public-key', alg: -257 }],
      authenticatorSelection: {
        authenticatorAttachment: 'platform',
        residentKey: 'required',
        requireResidentKey: true,
        userVerification: 'required',
      },
      hints: ['client-device'],
      attestation: 'none',
      timeout: TIMEOUT_MS,
      extensions: { prf: { eval: { first: utf8(PRF_INPUT) } } },
    });
    if (r.error) return r;
    var resp = r.cred.response;
    if (typeof resp.getAuthenticatorData === 'function') {
      var ad = null;
      try {
        ad = resp.getAuthenticatorData();
      } catch (e) {
        ad = null;
      }
      if (ad && !uvFlag(ad)) return { error: 'failed', cause: 'no_user_verification' };
    }
    var prf = prfOf(r.cred);
    return { credId: b64u(r.cred.rawId), prfEnabled: prf.enabled === true, prf: prf.first };
  }

  // Утверждение тем passkey, что записан (allowCredentials), с проверкой флага UV; при withPrf — с выходом PRF.
  async function assertCredential(credId, withPrf) {
    var id = unb64u(credId);
    if (!id || id.length < 16) return { error: 'no_credential', cause: 'cred_id' };
    var opts = {
      challenge: random(32),
      allowCredentials: [{ type: 'public-key', id: id, transports: ['internal'] }],
      userVerification: 'required',
      hints: ['client-device'],
      timeout: TIMEOUT_MS,
    };
    if (withPrf) opts.extensions = { prf: { eval: { first: utf8(PRF_INPUT) } } };
    var r = await ceremony('get', opts);
    if (r.error) return r;
    if (b64u(r.cred.rawId) !== credId) return { error: 'failed', cause: 'other_credential' };
    if (!uvFlag(r.cred.response.authenticatorData)) return { error: 'failed', cause: 'no_user_verification' };
    return { prf: withPrf ? prfOf(r.cred).first : null };
  }

  // ------------------------------------------------------------------ AES-256-GCM из PRF

  async function deriveKey(prf, purpose) {
    var subtle = global.crypto.subtle;
    try {
      var base = await subtle.importKey('raw', prf, 'HKDF', false, ['deriveKey']);
      return await subtle.deriveKey(
        { name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(32), info: utf8(INFO[purpose]) },
        base,
        { name: 'AES-GCM', length: 256 },
        false, // неизвлекаемый
        ['encrypt', 'decrypt'],
      );
    } finally {
      wipe(prf);
    }
  }

  function aad(credId, owner, purpose) {
    return utf8('optomstroy-demo/v1|' + rpId() + '|' + credId + '|' + owner + '|' + PURPOSE[purpose]);
  }

  async function seal(key, plain, credId, owner, purpose) {
    var iv = random(12);
    var ct = await global.crypto.subtle.encrypt({ name: 'AES-GCM', iv: iv, additionalData: aad(credId, owner, purpose) }, key, plain);
    return { credId: credId, iv: b64u(iv), ct: b64u(ct) };
  }

  // Открыть запечатанное; null — не открывается (другой ключ, AAD или испорченный шифртекст).
  async function open(key, sealed, owner, purpose) {
    try {
      var pt = await global.crypto.subtle.decrypt(
        { name: 'AES-GCM', iv: unb64u(sealed.iv), additionalData: aad(sealed.credId, owner, purpose) },
        key,
        unb64u(sealed.ct),
      );
      return new Uint8Array(pt);
    } catch (e) {
      return null;
    }
  }

  // ------------------------------------------------------------------ протокол

  function ok(extra) {
    var r = { ok: true };
    if (extra) Object.keys(extra).forEach(function (k) { r[k] = extra[k]; });
    return r;
  }

  function fail(op, code, cause, extra) {
    note(op, code, cause);
    var r = { ok: false, error: code };
    if (extra) Object.keys(extra).forEach(function (k) { r[k] = extra[k]; });
    return r;
  }

  function guard(op, fn) {
    return function (args) {
      var a = args && typeof args === 'object' ? args : {};
      return Promise.resolve()
        .then(function () { return fn(a); })
        .catch(function (e) { return fail(op, 'failed', errName(e)); });
    };
  }

  function ready() {
    return !!webauthn() && storeReady();
  }

  function validSecret(s) {
    return typeof s === 'string' && s.length > 0 && s.length <= MAX_SECRET;
  }

  function validChallenge(c) {
    if (typeof c !== 'string' || c.indexOf(CHALLENGE_PREFIX) !== 0) return false;
    var rest = c.slice(CHALLENGE_PREFIX.length);
    return rest.length > 0 && /^[A-Za-z0-9_-]+$/.test(rest) && utf8(c).length <= CHALLENGE_MAX;
  }

  async function prfSupport() {
    if (noPrfMarked()) return 'no';
    var pkc = global.PublicKeyCredential;
    try {
      if (pkc && typeof pkc.getClientCapabilities === 'function') {
        var caps = await pkc.getClientCapabilities();
        if (caps && caps['extension:prf'] === false) return 'no';
        if (caps && caps['extension:prf'] === true) return 'yes';
      }
    } catch (e) { /* неизвестно — правду скажет create() (prf.enabled) */ }
    return 'unknown';
  }

  function unsupported(reason) {
    return { kind: 'none', availability: 'unsupported', cryptoBinding: false, reason: reason, keysSupported: false, prf: 'no' };
  }

  async function capability(a) {
    try {
      var mode = a.mode;
      if (mode !== 'bound' && mode !== 'gate') return unsupported('mode');
      var w = webauthn();
      if (!w) return unsupported('no_webauthn');
      if (!storeReady()) return unsupported('no_storage');
      var uvpaa = false;
      try {
        uvpaa = typeof w.pkc.isUserVerifyingPlatformAuthenticatorAvailable === 'function' &&
          (await w.pkc.isUserVerifyingPlatformAuthenticatorAvailable()) === true;
      } catch (e) {
        uvpaa = false;
      }
      if (!uvpaa) return unsupported('no_platform_authenticator');
      var prf = await prfSupport();
      if (mode === 'bound') {
        if (prf === 'no') return unsupported('no_prf');
        return { kind: 'android_class3', availability: 'available', cryptoBinding: true, keysSupported: false, prf: prf };
      }
      return {
        kind: 'windows_hello',
        availability: 'available',
        cryptoBinding: false,
        reason: 'no_crypto_binding_on_platform',
        keysSupported: prf !== 'no',
        prf: prf,
      };
    } catch (e) {
      note('capability', 'failed', errName(e));
      return unsupported('failed');
    }
  }

  // Привязка без PRF: passkey бесполезен — маркер, блоб удаляется, ОС сообщается, что ключ не нужен (best effort).
  function boundWithoutPrf(op, credId) {
    markNoPrf(true);
    P.store.remove(keys().passkeyBound);
    forget();
    signalUnknown(credId);
    return fail(op, 'not_available', 'no_prf', { reason: 'no_prf' });
  }

  async function store(a) {
    if (!validSecret(a.secret)) return fail('store', 'failed', 'secret');
    var owner = await ownerTag(a.owner);
    if (!owner) return fail('store', 'failed', 'owner');
    if (!ready()) return fail('store', 'not_available', 'no_webauthn');
    if (noPrfMarked()) return fail('store', 'not_available', 'no_prf', { reason: 'no_prf' });
    var made = await createCredential();
    if (made.error) return fail('store', made.error, made.cause);
    // Новый passkey с тем же user.id заменил прежний: прежний блоб уже не открыть.
    P.store.remove(keys().passkeyBound);
    forget();
    if (!made.prfEnabled) return boundWithoutPrf('store', made.credId);
    var prf = made.prf;
    if (!prf) {
      // Аутентификатор не дал результата PRF при создании — один раз get() с PRF (второй диалог при включении).
      var got = await assertCredential(made.credId, true);
      if (got.error) return fail('store', got.error, got.cause);
      prf = got.prf;
      if (!prf) return boundWithoutPrf('store', made.credId);
    }
    var key = await deriveKey(prf, 'bound');
    var sealed = await seal(key, utf8(a.secret), made.credId, owner, 'bound');
    if (!writeJson(keys().passkeyBound, { v: 1, credId: sealed.credId, owner: owner, iv: sealed.iv, ct: sealed.ct })) {
      return fail('store', 'failed', 'quota');
    }
    return ok();
  }

  async function read(a) {
    var owner = await ownerTag(a.owner);
    if (!owner) return fail('read', 'no_credential', 'owner');
    if (!ready()) return fail('read', 'not_available', 'no_webauthn');
    var raw = P.store.get(keys().passkeyBound);
    var blob = boundBlob();
    if (!blob) {
      if (raw) {
        P.store.remove(keys().passkeyBound);
        return fail('read', 'invalidated', 'broken');
      }
      return fail('read', 'no_credential');
    }
    // Чужой блоб не открывается (без диалога и без удаления): переключение «планшет ↔ обычный вход» не должно
    // предложить этому пользователю чужой ключ (ADR-116 п. 1).
    if (blob.owner !== owner) return fail('read', 'invalidated', 'owner');
    var got = await assertCredential(blob.credId, true);
    if (got.error) return fail('read', got.error, got.cause);
    if (!got.prf) {
      P.store.remove(keys().passkeyBound);
      forget();
      return fail('read', 'invalidated', 'no_prf_result');
    }
    var key = await deriveKey(got.prf, 'bound');
    var pt = await open(key, blob, owner, 'bound');
    if (!pt) {
      P.store.remove(keys().passkeyBound);
      forget();
      return fail('read', 'invalidated', 'decrypt');
    }
    var value;
    try {
      value = fromUtf8(pt);
    } finally {
      wipe(pt);
    }
    remember(key, blob.credId, owner);
    return ok({ value: value });
  }

  async function replace(a) {
    if (!validSecret(a.secret)) return fail('replace', 'failed', 'secret');
    var owner = await ownerTag(a.owner);
    if (!owner) return fail('replace', 'no_credential', 'owner');
    if (!ready()) return fail('replace', 'not_available', 'no_webauthn');
    var blob = boundBlob();
    if (!blob || blob.owner !== owner) return fail('replace', 'no_credential');
    var key = cachedKey(blob.credId, owner);
    if (!key) {
      var got = await assertCredential(blob.credId, true);
      if (got.error) return fail('replace', got.error, got.cause);
      if (!got.prf) {
        P.store.remove(keys().passkeyBound);
        forget();
        return fail('replace', 'invalidated', 'no_prf_result');
      }
      key = await deriveKey(got.prf, 'bound');
    }
    var sealed = await seal(key, utf8(a.secret), blob.credId, owner, 'bound');
    if (!writeJson(keys().passkeyBound, { v: 1, credId: sealed.credId, owner: owner, iv: sealed.iv, ct: sealed.ct })) {
      return fail('replace', 'failed', 'quota');
    }
    return ok();
  }

  async function has(a) {
    var owner = await ownerTag(a.owner);
    if (!owner || !storeReady()) return ok({ value: false });
    var blob = boundBlob();
    return ok({ value: !!(blob && blob.owner === owner) });
  }

  // Хук очистки сессии (выход, «выйти везде», SESSION_REVOKED, подключение планшета): удаляется только блоб привязки.
  // Passkey браузера (гейт) и ключи входа браузера на Windows очистка сессии не трогает (ADR-116 п. 1, п. 3; C-02).
  async function clear() {
    forget();
    if (storeReady()) P.store.remove(keys().passkeyBound);
    return ok();
  }

  async function confirmPresence() {
    if (!ready()) return fail('confirmPresence', 'not_available', 'no_webauthn');
    var gate = gateRecord();
    if (gate) {
      var got = await assertCredential(gate.credId, false);
      if (got.error) return fail('confirmPresence', got.error, got.cause);
      return ok();
    }
    var made = await createCredential();
    if (made.error) return fail('confirmPresence', made.error, made.cause);
    if (!writeJson(keys().passkeyGate, { v: 1, credId: made.credId })) return fail('confirmPresence', 'failed', 'quota');
    markNoPrf(!made.prfEnabled);
    wipe(made.prf);
    return ok();
  }

  function noPrfForKey(gateReady) {
    markNoPrf(true);
    return fail('createKey', 'not_available', 'no_prf', { reason: 'no_prf', gate: gateReady });
  }

  async function createKey(a) {
    var owner = await ownerTag(a.owner);
    if (!owner) return fail('createKey', 'failed', 'owner');
    if (!ready()) return fail('createKey', 'not_available', 'no_webauthn');
    var gate = gateRecord();
    if (noPrfMarked()) return fail('createKey', 'not_available', 'no_prf', { reason: 'no_prf', gate: !!gate });
    var credId;
    var prf;
    var got;
    if (gate) {
      // Passkey браузера уже есть (гейт или ключ другого пользователя): тот же passkey, без create() — иначе новый
      // ключ с тем же user.id заменил бы прежний и погубил ключи входа других пользователей этого браузера.
      credId = gate.credId;
      got = await assertCredential(credId, true);
      if (got.error) return fail('createKey', got.error, got.cause);
      prf = got.prf;
    } else {
      var made = await createCredential();
      if (made.error) return fail('createKey', made.error, made.cause);
      credId = made.credId;
      // Passkey принадлежит браузеру: без PRF он остаётся ключом гейта (снекбар settings_hello_key_no_prf).
      if (!writeJson(keys().passkeyGate, { v: 1, credId: credId })) return fail('createKey', 'failed', 'quota');
      if (!made.prfEnabled) return noPrfForKey(true);
      prf = made.prf;
      if (!prf) {
        got = await assertCredential(credId, true);
        if (got.error) return fail('createKey', got.error, got.cause);
        prf = got.prf;
      }
    }
    if (!prf) return noPrfForKey(true);
    var key = await deriveKey(prf, 'key');
    var pair = await global.crypto.subtle.generateKey(
      { name: RSA.name, modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: RSA.hash },
      true,
      ['sign', 'verify'],
    );
    var spki = new Uint8Array(await global.crypto.subtle.exportKey('spki', pair.publicKey));
    var pkcs8 = new Uint8Array(await global.crypto.subtle.exportKey('pkcs8', pair.privateKey));
    var sealed;
    try {
      sealed = await seal(key, pkcs8, credId, owner, 'key');
    } finally {
      wipe(pkcs8);
    }
    var items = keyItems();
    items[owner] = sealed;
    if (!writeKeyItems(items)) return fail('createKey', 'failed', 'quota');
    return ok({ value: b64u(spki), algorithm: 'RS256', source: 'webauthn_prf' });
  }

  function dropKey(owner) {
    var items = keyItems();
    if (!items[owner]) return false;
    delete items[owner];
    writeKeyItems(items);
    return true;
  }

  async function sign(a) {
    if (!validChallenge(a.challenge)) return fail('sign', 'failed', 'challenge');
    var owner = await ownerTag(a.owner);
    if (!owner) return fail('sign', 'no_credential', 'owner');
    if (!ready()) return fail('sign', 'not_available', 'no_webauthn');
    var item = keyItems()[owner];
    if (!item) return fail('sign', 'no_credential');
    var got = await assertCredential(item.credId, true);
    if (got.error) return fail('sign', got.error, got.cause);
    // Нет результата PRF или ключ не открывается — ключ входа пропал (как KeyCredentialStatus.NotFound на Windows,
    // 09 §9.2 W2 п. 4): запись удаляется, приложение предложит PIN с helloKeyInvalidated.
    if (!got.prf) {
      dropKey(owner);
      return fail('sign', 'no_credential', 'no_prf_result');
    }
    var key = await deriveKey(got.prf, 'key');
    var pkcs8 = await open(key, item, owner, 'key');
    if (!pkcs8) {
      dropKey(owner);
      return fail('sign', 'no_credential', 'decrypt');
    }
    var priv;
    try {
      priv = await global.crypto.subtle.importKey('pkcs8', pkcs8, RSA, false, ['sign']);
    } catch (e) {
      dropKey(owner);
      return fail('sign', 'no_credential', 'import');
    } finally {
      wipe(pkcs8);
    }
    var sig = await global.crypto.subtle.sign(RSA.name, priv, utf8(a.challenge));
    return ok({ value: b64u(sig) });
  }

  async function deleteKey(a) {
    var owner = await ownerTag(a.owner);
    if (!owner || !storeReady()) return ok({ value: false });
    return ok({ value: dropKey(owner) });
  }

  async function hasKey(a) {
    var owner = await ownerTag(a.owner);
    if (!owner || !storeReady()) return ok({ value: false });
    return ok({ value: !!keyItems()[owner] });
  }

  global.__posPasskey = Object.freeze({
    protocol: PROTOCOL,
    capability: guard('capability', capability),
    store: guard('store', store),
    read: guard('read', read),
    replace: guard('replace', replace),
    has: guard('has', has),
    clear: guard('clear', clear),
    confirmPresence: guard('confirmPresence', confirmPresence),
    createKey: guard('createKey', createKey),
    sign: guard('sign', sign),
    deleteKey: guard('deleteKey', deleteKey),
    hasKey: guard('hasKey', hasKey),
  });

  // Для страницы (не для приложения): «Сбросить демо» (demo-reset.js) и smoke-шаг passkey. Значений не возвращает.
  P.passkey = {
    // Сообщить ОС, что passkey этого сайта больше не нужны (signalUnknownCredential, best effort), и удалить записи.
    forgetAll: function () {
      forget();
      if (!storeReady()) return Promise.resolve({ signalled: 0 });
      var ids = {};
      var g = gateRecord();
      var b = boundBlob();
      var items = keyItems();
      if (g) ids[g.credId] = true;
      if (b) ids[b.credId] = true;
      Object.keys(items).forEach(function (t) { ids[items[t].credId] = true; });
      var k = keys();
      [k.passkeyGate, k.passkeyBound, k.passkeyHelloKey, k.passkeyNoPrf, k.passkeyUser].forEach(function (name) {
        P.store.remove(name);
      });
      return Promise.all(Object.keys(ids).map(signalUnknown)).then(function (r) {
        return { signalled: r.filter(Boolean).length };
      });
    },
    // Состояние записей — только признаки и числа.
    state: function () {
      if (!storeReady()) return { available: false };
      return {
        available: true,
        user: !!P.store.get(keys().passkeyUser),
        gate: !!gateRecord(),
        bound: !!boundBlob(),
        keys: Object.keys(keyItems()).length,
        noPrf: noPrfMarked(),
        keyInMemory: !!cache && now() < cache.until,
      };
    },
  };
})(window);
