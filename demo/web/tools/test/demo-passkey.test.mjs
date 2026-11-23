// 12 T-DEMO-015 — demo-passkey.js в Node (15 ADR-116 п. 1, п. 4; 09 BIO-035, BIO-041, AC-AUTH-094, AC-AUTH-100;
// 07 §11.1 п. 4). Вне релизных ворот (12 §3.22).
//
//   node --test demo/web/tools/test/demo-passkey.test.mjs
//
// Скрипт страницы выполняется как есть (вместе с demo-env.js — PosDemoPage.store и KEYS) на подменном окне:
// navigator.credentials и PublicKeyCredential — подменный платформенный аутентификатор (PRF = HMAC-SHA-256 от секрета
// ключа, как hmac-secret), WebCrypto — настоящий node:crypto, время и таймеры — управляемые. Шаги — по 12 T-DEMO-015:
// (1) запечатать/открыть; (2) чужой owner и AAD; (3) без PRF; (4) ошибки WebAuthn; (5) replace через 30 и 61 с;
// (6) clear по режиму; (7) ключ входа браузера на Windows; (8) ответы, хранилище и журнал без секретов.
import assert from 'node:assert/strict';
import { createHmac, randomBytes, randomUUID, webcrypto } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { describe, test } from 'node:test';

const SITE = new URL('../../site-src/', import.meta.url);
const ENV_SRC = readFileSync(new URL('demo-env.js', SITE), 'utf8');
const PASSKEY_SRC = readFileSync(new URL('demo-passkey.js', SITE), 'utf8');

const PRF_INPUT = 'optomstroy-demo:biometric_refresh:v1';
const INFO = {
  biometric_refresh: 'optomstroy-demo/biometric_refresh/aes-256-gcm/v1',
  hello_key: 'optomstroy-demo/hello_key/aes-256-gcm/v1',
};
const HOST = 'localhost';
const NAMES = {
  passkeyUser: 'optomstroy.demo.passkeyUser', // check-secrets: allow — имя ключа хранилища страницы, не секрет
  passkeyGate: 'optomstroy.demo.passkeyGate', // check-secrets: allow — имя ключа хранилища страницы, не секрет
  passkeyBound: 'optomstroy.demo.passkeyBound', // check-secrets: allow — имя ключа хранилища страницы, не секрет
  passkeyHelloKey: 'optomstroy.demo.passkeyHelloKey', // check-secrets: allow — имя ключа хранилища страницы, не секрет
  passkeyNoPrf: 'optomstroy.demo.passkeyNoPrf', // check-secrets: allow — имя ключа хранилища страницы, не секрет
};
const CHALLENGE = () => `optomstroy-hello-unlock/v1:${randomBytes(32).toString('base64url')}`;
const RSA = { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' };

const b64u = (b) => Buffer.from(b instanceof ArrayBuffer ? new Uint8Array(b) : b).toString('base64url');
const fromB64u = (s) => new Uint8Array(Buffer.from(s, 'base64url'));
const toAB = (buf) => {
  const u = new Uint8Array(buf.length);
  u.set(buf);
  return u.buffer;
};
const enc = (s) => new TextEncoder().encode(s);
// Синтетический «JWT» собирается при запуске: в исходнике нет строки, похожей на токен.
const jwtLike = () =>
  [{ alg: 'ES256', typ: 'JWT' }, { sub: randomUUID(), kind: 'biometric' }].map((o) => Buffer.from(JSON.stringify(o)).toString('base64url')).join('.') +
  '.' +
  randomBytes(32).toString('base64url');
const JWT_RE = /eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/;
const tagOf = async (userId) => {
  const d = new Uint8Array(await webcrypto.subtle.digest('SHA-256', enc(userId.trim().toLowerCase())));
  return Buffer.from(d.slice(0, 8)).toString('hex');
};
const isPlain = (v) => v !== null && typeof v === 'object' && Object.getPrototypeOf(v) === Object.prototype;

// Подменный платформенный аутентификатор с проверкой пользователя.
class FakeAuthenticator {
  constructor(o = {}) {
    this.uvpaa = o.uvpaa ?? true; // isUserVerifyingPlatformAuthenticatorAvailable
    this.clientPrf = o.clientPrf ?? true; // getClientCapabilities()['extension:prf']
    // PRF при create(): results — включён и дал выход; enabled — включён, выход только при get(); disabled — у ключа
    // PRF нет (enabled:false); absent — браузер расширение не обработал (prf нет в результатах).
    this.prfAtCreate = o.prfAtCreate ?? 'results';
    this.prfAtGet = o.prfAtGet ?? true;
    this.uv = o.uv ?? true; // флаг UV в authenticatorData
    this.creds = new Map(); // credId → {uid, secret, prf}
    this.calls = { create: 0, get: 0 };
    this.errors = []; // очередь имён DOMException для следующих вызовов
    this.signalled = [];
    this.pause = null; // Promise — get() ждёт его
  }

  prfOut(cred, input) {
    const h = createHmac('sha256', cred.secret).update(Buffer.from('WebAuthn PRF\u0000')).update(Buffer.from(input)).digest();
    return toAB(h);
  }

  authData() {
    const d = new Uint8Array(37);
    d.set(randomBytes(32));
    d[32] = 0x01 | (this.uv ? 0x04 : 0);
    return d.buffer;
  }

  raise() {
    const name = this.errors.shift();
    if (name === 'TypeError') throw new TypeError('bad options');
    if (name) throw new DOMException('fake', name);
  }

  async create({ publicKey }) {
    this.calls.create++;
    this.lastCreate = publicKey;
    this.raise();
    const uid = Buffer.from(publicKey.user.id).toString('hex');
    for (const [id, c] of this.creds) if (c.uid === uid) this.creds.delete(id); // тот же user.id — замена
    const rawId = randomBytes(32);
    const cred = { uid, secret: randomBytes(32), prf: this.prfAtCreate !== 'disabled' && this.prfAtCreate !== 'absent' };
    this.creds.set(b64u(rawId), cred);
    const want = publicKey.extensions && publicKey.extensions.prf;
    const ext = {};
    if (want && this.prfAtCreate !== 'absent') {
      ext.prf = { enabled: cred.prf };
      if (this.prfAtCreate === 'results') ext.prf.results = { first: this.prfOut(cred, want.eval.first) };
    }
    const ad = this.authData();
    return { type: 'public-key', rawId: toAB(rawId), response: { getAuthenticatorData: () => ad }, getClientExtensionResults: () => ext };
  }

  async get({ publicKey }) {
    this.calls.get++;
    this.lastGet = publicKey;
    if (this.pause) await this.pause;
    this.raise();
    const id = publicKey.allowCredentials.map((c) => b64u(c.id)).find((i) => this.creds.has(i));
    if (!id) throw new DOMException('no credential', 'NotAllowedError'); // как удалённый в ОС passkey
    const cred = this.creds.get(id);
    const want = publicKey.extensions && publicKey.extensions.prf;
    const ext = {};
    if (want) ext.prf = cred.prf && this.prfAtGet ? { results: { first: this.prfOut(cred, want.eval.first) } } : {};
    return { type: 'public-key', rawId: toAB(Buffer.from(id, 'base64url')), response: { authenticatorData: this.authData() }, getClientExtensionResults: () => ext };
  }
}

function makeStorage() {
  const items = new Map();
  return {
    items,
    getItem: (k) => (items.has(k) ? items.get(k) : null),
    setItem: (k, v) => void items.set(k, String(v)),
    removeItem: (k) => void items.delete(k),
    clear: () => items.clear(),
  };
}

// Окно страницы: demo-env.js + demo-passkey.js на подменных navigator, PublicKeyCredential, хранилище, времени.
function makePage(o = {}) {
  const auth = o.auth ?? new FakeAuthenticator();
  const local = o.storage ?? makeStorage();
  const logs = [];
  const capture = (...a) => logs.push(a.map(String).join(' '));
  const clock = { t: 1_800_000_000_000, seq: 0, timers: new Map() };
  const win = {
    localStorage: local,
    sessionStorage: makeStorage(),
    console: { log: capture, info: capture, warn: capture, error: capture, debug: capture },
    navigator: o.noWebAuthn ? { userAgent: 'test' } : { userAgent: 'test', credentials: { create: (x) => auth.create(x), get: (x) => auth.get(x) } },
    PublicKeyCredential: o.noWebAuthn
      ? undefined
      : {
          isUserVerifyingPlatformAuthenticatorAvailable: async () => auth.uvpaa,
          getClientCapabilities: async () => ({ 'extension:prf': auth.clientPrf }),
          signalUnknownCredential: async (x) => void auth.signalled.push(x),
        },
    location: { hostname: o.hostname ?? HOST, origin: `http://${o.hostname ?? HOST}:8097` },
    isSecureContext: o.secure ?? true,
    crypto: webcrypto,
    TextEncoder,
    TextDecoder,
    Date: { now: () => clock.t },
    setTimeout: (fn, ms) => {
      const id = ++clock.seq;
      clock.timers.set(id, { at: clock.t + ms, fn });
      return id;
    },
    clearTimeout: (id) => void clock.timers.delete(id),
  };
  win.window = win;
  if (o.env !== false) new Function('window', ENV_SRC)(win);
  new Function('window', PASSKEY_SRC)(win);
  const advance = (ms) => {
    clock.t += ms;
    for (const [id, t] of [...clock.timers]) {
      if (t.at <= clock.t) {
        clock.timers.delete(id);
        t.fn();
      }
    }
  };
  const json = (name) => {
    const raw = local.getItem(NAMES[name]);
    return raw === null ? null : JSON.parse(raw);
  };
  return { win, api: win.__posPasskey, page: win.PosDemoPage.passkey, auth, local, logs, clock, advance, json };
}

// Независимо от скрипта: ключ HKDF-SHA-256 из выхода PRF этого passkey и расшифровка AES-256-GCM с AAD (формат 07 §11.1).
async function openIndependently(auth, sealed, ownerTag, purpose, host = HOST) {
  const cred = auth.creds.get(sealed.credId);
  const prf = auth.prfOut(cred, enc(PRF_INPUT));
  const base = await webcrypto.subtle.importKey('raw', prf, 'HKDF', false, ['deriveKey']);
  const key = await webcrypto.subtle.deriveKey(
    { name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(32), info: enc(INFO[purpose]) },
    base,
    { name: 'AES-GCM', length: 256 },
    false,
    ['decrypt'],
  );
  const aad = enc(`optomstroy-demo/v1|${host}|${sealed.credId}|${ownerTag}|${purpose}`);
  return new Uint8Array(await webcrypto.subtle.decrypt({ name: 'AES-GCM', iv: fromB64u(sealed.iv), additionalData: aad }, key, fromB64u(sealed.ct)));
}

async function verifySig(spkiB64u, challenge, sigB64u) {
  const pub = await webcrypto.subtle.importKey('spki', fromB64u(spkiB64u), RSA, false, ['verify']);
  return webcrypto.subtle.verify(RSA.name, pub, fromB64u(sigB64u), enc(challenge));
}

describe('протокол и окружение', () => {
  test('protocol 1, объект заморожен, имена ключей страницы — как в 07 §11.1 п. 4', () => {
    const { api, win } = makePage();
    assert.equal(api.protocol, 1);
    assert.ok(Object.isFrozen(api));
    for (const m of ['capability', 'store', 'read', 'replace', 'has', 'clear', 'confirmPresence', 'createKey', 'sign', 'deleteKey', 'hasKey']) {
      assert.equal(typeof api[m], 'function', m);
    }
    for (const [k, v] of Object.entries(NAMES)) assert.equal(win.PosDemoPage.KEYS[k], v, k);
  });

  test('capability: привязка и гейт; платформенного аутентификатора нет; не защищённый контекст; нет WebAuthn; режим', async () => {
    let p = makePage();
    assert.deepEqual(await p.api.capability({ mode: 'bound' }), { kind: 'android_class3', availability: 'available', cryptoBinding: true, keysSupported: false, prf: 'yes' });
    assert.deepEqual(await p.api.capability({ mode: 'gate' }), {
      kind: 'windows_hello',
      availability: 'available',
      cryptoBinding: false,
      reason: 'no_crypto_binding_on_platform',
      keysSupported: true,
      prf: 'yes',
    });
    p = makePage({ auth: new FakeAuthenticator({ uvpaa: false }) });
    for (const mode of ['bound', 'gate']) {
      const c = await p.api.capability({ mode });
      assert.equal(c.availability, 'unsupported');
      assert.equal(c.reason, 'no_platform_authenticator');
      assert.equal(c.kind, 'none');
    }
    assert.equal((await makePage({ secure: false }).api.capability({ mode: 'bound' })).reason, 'no_webauthn');
    assert.equal((await makePage({ noWebAuthn: true }).api.capability({ mode: 'gate' })).reason, 'no_webauthn');
    assert.equal((await makePage({ env: false }).api.capability({ mode: 'gate' })).reason, 'no_storage');
    assert.equal((await makePage().api.capability({ mode: 'web' })).reason, 'mode');
    assert.equal((await makePage().api.capability()).reason, 'mode');
  });

  test('capability: браузер без PRF — привязка скрыта, у гейта ключа входа нет', async () => {
    const p = makePage({ auth: new FakeAuthenticator({ clientPrf: false }) });
    const bound = await p.api.capability({ mode: 'bound' });
    assert.equal(bound.availability, 'unsupported');
    assert.equal(bound.reason, 'no_prf');
    const gate = await p.api.capability({ mode: 'gate' });
    assert.equal(gate.availability, 'available');
    assert.equal(gate.keysSupported, false);
    assert.equal(gate.prf, 'no');
  });

  test('любые аргументы — Promise простого объекта, исключений нет; без WebAuthn — not_available', async () => {
    for (const page of [makePage(), makePage({ noWebAuthn: true }), makePage({ env: false })]) {
      for (const m of ['store', 'read', 'replace', 'has', 'clear', 'confirmPresence', 'createKey', 'sign', 'deleteKey', 'hasKey', 'capability']) {
        for (const args of [undefined, null, 42, 'x', {}, { owner: 7, secret: {}, challenge: [] }]) {
          const pr = page.api[m](args);
          assert.ok(pr instanceof Promise, m);
          const r = await pr;
          assert.ok(isPlain(r), `${m}(${JSON.stringify(args)})`);
        }
      }
    }
    const nw = makePage({ noWebAuthn: true });
    assert.deepEqual(await nw.api.read({ owner: randomUUID() }), { ok: false, error: 'not_available' });
    assert.deepEqual(await nw.api.confirmPresence(), { ok: false, error: 'not_available' });
    assert.deepEqual(await nw.api.createKey({ owner: randomUUID() }), { ok: false, error: 'not_available' });
  });
});

describe('(1) привязка: store → read', () => {
  test('блоб AES-256-GCM под ключом HKDF-SHA-256 из PRF, AAD с owner; read — один диалог, секрет совпадает', async () => {
    const p = makePage();
    const user = randomUUID();
    const secret = jwtLike();
    assert.deepEqual(await p.api.store({ secret, owner: user }), { ok: true });
    assert.deepEqual(p.auth.calls, { create: 1, get: 0 }); // выход PRF пришёл при создании — один диалог
    const opts = p.auth.lastCreate;
    assert.equal(opts.rp.id, undefined); // rp.id = hostname страницы
    assert.equal(opts.user.name, 'optomstroy-demo');
    assert.equal(opts.authenticatorSelection.authenticatorAttachment, 'platform');
    assert.equal(opts.authenticatorSelection.residentKey, 'required');
    assert.equal(opts.authenticatorSelection.userVerification, 'required');
    assert.equal(opts.attestation, 'none');
    assert.equal(Buffer.from(opts.extensions.prf.eval.first).toString(), PRF_INPUT);

    const blob = p.json('passkeyBound');
    const tag = await tagOf(user);
    assert.deepEqual(Object.keys(blob).sort(), ['credId', 'ct', 'iv', 'owner', 'v']);
    assert.equal(blob.v, 1);
    assert.equal(blob.owner, tag);
    assert.equal(fromB64u(blob.iv).length, 12);
    assert.equal(Buffer.from(await openIndependently(p.auth, blob, tag, 'biometric_refresh')).toString(), secret);
    assert.equal(p.json('passkeyGate'), null); // привязка гейт не заводит

    assert.deepEqual(await p.api.has({ owner: user }), { ok: true, value: true });
    assert.deepEqual(await p.api.has({ owner: user.toUpperCase() }), { ok: true, value: true }); // userId — строчными
    assert.deepEqual(await p.api.read({ owner: user }), { ok: true, value: secret });
    assert.deepEqual(p.auth.calls, { create: 1, get: 1 });
    const get = p.auth.lastGet;
    assert.equal(get.userVerification, 'required');
    assert.deepEqual(get.allowCredentials.map((c) => b64u(c.id)), [blob.credId]);
  });

  test('PRF включён, но выход только при get(): при включении — один дополнительный диалог', async () => {
    const p = makePage({ auth: new FakeAuthenticator({ prfAtCreate: 'enabled' }) });
    const user = randomUUID();
    assert.deepEqual(await p.api.store({ secret: 'refresh-1', owner: user }), { ok: true }); // check-secrets: allow — синтетическое значение теста, не секрет
    assert.deepEqual(p.auth.calls, { create: 1, get: 1 });
    assert.deepEqual(await p.api.read({ owner: user }), { ok: true, value: 'refresh-1' });
    assert.deepEqual(p.auth.calls, { create: 1, get: 2 });
  });

  test('повторное включение заменяет passkey (тот же user.id) и блоб', async () => {
    const p = makePage();
    const user = randomUUID();
    await p.api.store({ secret: 'a', owner: user });
    const first = p.json('passkeyBound').credId;
    const uid = p.local.getItem(NAMES.passkeyUser);
    await p.api.store({ secret: 'b', owner: user });
    assert.notEqual(p.json('passkeyBound').credId, first);
    assert.equal(p.local.getItem(NAMES.passkeyUser), uid);
    assert.equal(p.auth.creds.size, 1);
    assert.deepEqual(await p.api.read({ owner: user }), { ok: true, value: 'b' });
  });
});

describe('(2) чужой owner и AAD', () => {
  test('read с чужим owner — invalidated без диалога, блоб не открыт и не удалён', async () => {
    const p = makePage();
    const a = randomUUID();
    await p.api.store({ secret: 'secret-a', owner: a }); // check-secrets: allow — синтетическое значение теста, не секрет
    const before = p.local.getItem(NAMES.passkeyBound);
    assert.deepEqual(await p.api.read({ owner: randomUUID() }), { ok: false, error: 'invalidated' });
    assert.equal(p.auth.calls.get, 0);
    assert.equal(p.local.getItem(NAMES.passkeyBound), before);
    assert.deepEqual(await p.api.has({ owner: randomUUID() }), { ok: true, value: false });
    assert.deepEqual(await p.api.replace({ secret: 'x', owner: randomUUID() }), { ok: false, error: 'no_credential' });
    assert.deepEqual(await p.api.read({ owner: '' }), { ok: false, error: 'no_credential' });
  });

  test('блоб другого сайта (rpId в AAD) и испорченный шифртекст — invalidated, блоб удалён', async () => {
    const p = makePage();
    const user = randomUUID();
    await p.api.store({ secret: 'secret', owner: user });
    // Тот же блоб и тот же аутентификатор, но другой hostname: AAD не совпадает.
    const other = makePage({ auth: p.auth, storage: p.local, hostname: 'draft--optomstroy.localhost' });
    assert.deepEqual(await other.api.read({ owner: user }), { ok: false, error: 'invalidated' });
    assert.equal(p.local.getItem(NAMES.passkeyBound), null);

    await p.api.store({ secret: 'secret', owner: user });
    const blob = p.json('passkeyBound');
    const ct = fromB64u(blob.ct);
    ct[0] ^= 1;
    p.local.setItem(NAMES.passkeyBound, JSON.stringify({ ...blob, ct: b64u(ct) }));
    assert.deepEqual(await p.api.read({ owner: user }), { ok: false, error: 'invalidated' });
    assert.equal(p.local.getItem(NAMES.passkeyBound), null);

    p.local.setItem(NAMES.passkeyBound, '{"v":1,"credId":"%%"');
    assert.deepEqual(await p.api.read({ owner: user }), { ok: false, error: 'invalidated' });
    assert.equal(p.local.getItem(NAMES.passkeyBound), null);
    assert.deepEqual(await p.api.read({ owner: user }), { ok: false, error: 'no_credential' });
  });
});

describe('(3) без PRF', () => {
  for (const prfAtCreate of ['disabled', 'absent']) {
    test(`create(): prf ${prfAtCreate} — not_available, вариант скрыт, ОС сообщено, блоба нет`, async () => {
      const p = makePage({ auth: new FakeAuthenticator({ prfAtCreate }) });
      const user = randomUUID();
      assert.deepEqual(await p.api.store({ secret: 's', owner: user }), { ok: false, error: 'not_available', reason: 'no_prf' });
      assert.equal(p.local.getItem(NAMES.passkeyBound), null);
      assert.deepEqual(p.json('passkeyNoPrf'), { v: 1 });
      await new Promise((r) => setImmediate(r));
      assert.equal(p.auth.signalled.length, 1);
      assert.deepEqual(Object.keys(p.auth.signalled[0]).sort(), ['credentialId', 'rpId']);
      assert.equal(p.auth.signalled[0].rpId, HOST);
      const cap = await p.api.capability({ mode: 'bound' });
      assert.equal(cap.availability, 'unsupported');
      assert.equal(cap.reason, 'no_prf');
      const calls = { ...p.auth.calls };
      assert.deepEqual(await p.api.store({ secret: 's', owner: user }), { ok: false, error: 'not_available', reason: 'no_prf' });
      assert.deepEqual(p.auth.calls, calls); // без нового диалога
    });
  }

  test('get() без выхода PRF — invalidated, блоб удалён', async () => {
    const p = makePage();
    const user = randomUUID();
    await p.api.store({ secret: 's', owner: user });
    p.auth.prfAtGet = false;
    assert.deepEqual(await p.api.read({ owner: user }), { ok: false, error: 'invalidated' });
    assert.equal(p.local.getItem(NAMES.passkeyBound), null);
    assert.deepEqual(await p.api.has({ owner: user }), { ok: true, value: false });
  });

  test('включение: выход PRF не пришёл и при get() — not_available, блоба нет', async () => {
    const p = makePage({ auth: new FakeAuthenticator({ prfAtCreate: 'enabled', prfAtGet: false }) });
    assert.deepEqual(await p.api.store({ secret: 's', owner: randomUUID() }), { ok: false, error: 'not_available', reason: 'no_prf' });
    assert.equal(p.local.getItem(NAMES.passkeyBound), null);
    assert.deepEqual(p.json('passkeyNoPrf'), { v: 1 });
  });
});

describe('(4) ошибки WebAuthn — простые объекты-исходы', () => {
  const MAP = [
    ['NotAllowedError', 'cancelled'],
    ['AbortError', 'cancelled'],
    ['InvalidStateError', 'failed'],
    ['SecurityError', 'not_available'],
    ['NotSupportedError', 'not_available'],
    ['TypeError', 'failed'],
    ['UnknownError', 'failed'],
  ];
  for (const [name, code] of MAP) {
    test(`${name} → ${code} во всех вызовах с диалогом`, async () => {
      const p = makePage();
      const user = randomUUID();
      p.auth.errors.push(name);
      assert.deepEqual(await p.api.store({ secret: 's', owner: user }), { ok: false, error: code });
      p.auth.errors.push(name);
      assert.deepEqual(await p.api.confirmPresence(), { ok: false, error: code });
      p.auth.errors.push(name);
      assert.deepEqual(await p.api.createKey({ owner: user }), { ok: false, error: code });
      await p.api.store({ secret: 's', owner: user });
      p.auth.errors.push(name);
      assert.deepEqual(await p.api.read({ owner: user }), { ok: false, error: code });
      assert.deepEqual(await p.api.read({ owner: user }), { ok: true, value: 's' }); // ошибка не губит блоб
      p.auth.errors.push(name);
      p.advance(61_000);
      assert.deepEqual(await p.api.replace({ secret: 't', owner: user }), { ok: false, error: code });
      await p.api.confirmPresence();
      p.auth.errors.push(name);
      assert.deepEqual(await p.api.confirmPresence(), { ok: false, error: code });
      await p.api.createKey({ owner: user });
      p.auth.errors.push(name);
      assert.deepEqual(await p.api.sign({ owner: user, challenge: CHALLENGE() }), { ok: false, error: code });
    });
  }

  test('проверка пользователя не пройдена (флаг UV) — failed', async () => {
    const p = makePage({ auth: new FakeAuthenticator({ uv: false }) });
    assert.deepEqual(await p.api.confirmPresence(), { ok: false, error: 'failed' });
    assert.equal(p.json('passkeyGate'), null);
    p.auth.uv = true;
    assert.deepEqual(await p.api.confirmPresence(), { ok: true });
    p.auth.uv = false;
    assert.deepEqual(await p.api.confirmPresence(), { ok: false, error: 'failed' });
  });

  test('passkey удалён в ОС — cancelled (не отличить от отмены)', async () => {
    const p = makePage();
    const user = randomUUID();
    await p.api.store({ secret: 's', owner: user });
    p.auth.creds.clear();
    assert.deepEqual(await p.api.read({ owner: user }), { ok: false, error: 'cancelled' });
  });

  test('второй вызов во время диалога — cancelled без второго диалога', async () => {
    const p = makePage();
    const user = randomUUID();
    await p.api.store({ secret: 's', owner: user });
    let release;
    p.auth.pause = new Promise((r) => (release = r));
    const first = p.api.read({ owner: user });
    while (p.auth.calls.get === 0) await new Promise((r) => setImmediate(r));
    assert.deepEqual(await p.api.read({ owner: user }), { ok: false, error: 'cancelled' });
    release();
    assert.deepEqual(await first, { ok: true, value: 's' });
    assert.equal(p.auth.calls.get, 1);
  });
});

describe('(5) replace: ключ в памяти не дольше 60 с', () => {
  test('через 30 с после read — без get(); через 61 с — с get(); таймер забывает ключ', async () => {
    const p = makePage();
    const user = randomUUID();
    await p.api.store({ secret: 'r1', owner: user });
    assert.deepEqual(await p.api.read({ owner: user }), { ok: true, value: 'r1' });
    assert.equal(p.auth.calls.get, 1);
    assert.equal(p.page.state().keyInMemory, true);

    p.advance(30_000);
    assert.deepEqual(await p.api.replace({ secret: 'r2', owner: user }), { ok: true });
    assert.equal(p.auth.calls.get, 1); // один диалог на разблокировку
    const tag = await tagOf(user);
    assert.equal(Buffer.from(await openIndependently(p.auth, p.json('passkeyBound'), tag, 'biometric_refresh')).toString(), 'r2');

    assert.deepEqual(await p.api.read({ owner: user }), { ok: true, value: 'r2' });
    assert.equal(p.auth.calls.get, 2);
    p.advance(61_000);
    assert.equal(p.page.state().keyInMemory, false);
    assert.equal(p.clock.timers.size, 0);
    assert.deepEqual(await p.api.replace({ secret: 'r3', owner: user }), { ok: true });
    assert.equal(p.auth.calls.get, 3);
    assert.deepEqual(await p.api.read({ owner: user }), { ok: true, value: 'r3' });
  });

  test('ровно 60 с — уже с get(); ключ только для того же пользователя; clear() забывает ключ', async () => {
    const p = makePage();
    const user = randomUUID();
    await p.api.store({ secret: 'r1', owner: user });
    await p.api.read({ owner: user });
    p.clock.t += 60_000; // таймер ещё не сработал — проверяет и срок
    assert.deepEqual(await p.api.replace({ secret: 'r2', owner: user }), { ok: true });
    assert.equal(p.auth.calls.get, 2);

    await p.api.read({ owner: user });
    assert.deepEqual(await p.api.clear({ mode: 'bound' }), { ok: true });
    assert.equal(p.page.state().keyInMemory, false);
    assert.deepEqual(await p.api.replace({ secret: 'r3', owner: user }), { ok: false, error: 'no_credential' });
  });

  test('replace без read — один get(); без PRF — invalidated', async () => {
    const p = makePage();
    const user = randomUUID();
    await p.api.store({ secret: 'r1', owner: user });
    assert.deepEqual(await p.api.replace({ secret: 'r2', owner: user }), { ok: true });
    assert.equal(p.auth.calls.get, 1);
    p.auth.prfAtGet = false;
    assert.deepEqual(await p.api.replace({ secret: 'r3', owner: user }), { ok: false, error: 'invalidated' });
    assert.equal(p.local.getItem(NAMES.passkeyBound), null);
  });
});

describe('(6) clear по режиму', () => {
  test("clear({mode:'gate'}) — passkey браузера, ключи входа, user.id и признак не тронуты; после выхода — тот же ключ", async () => {
    const p = makePage();
    const user = randomUUID();
    assert.deepEqual(await p.api.confirmPresence(), { ok: true });
    assert.deepEqual(p.auth.calls, { create: 1, get: 0 });
    assert.equal((await p.api.createKey({ owner: user })).ok, true);
    const snapshot = Object.fromEntries([...p.local.items].filter(([k]) => k.startsWith('optomstroy.demo.passkey')));
    assert.deepEqual(Object.keys(snapshot).sort(), [NAMES.passkeyGate, NAMES.passkeyHelloKey, NAMES.passkeyUser].sort());
    assert.deepEqual(await p.api.clear({ mode: 'gate' }), { ok: true });
    for (const [k, v] of Object.entries(snapshot)) assert.equal(p.local.getItem(k), v, k);
    // T-DEMO-017: после выхода и нового входа гейт — тот же ключ: без create() и без signalUnknownCredential.
    assert.deepEqual(await p.api.confirmPresence(), { ok: true });
    assert.equal(p.auth.calls.create, 1);
    assert.equal(p.auth.signalled.length, 0);
    assert.deepEqual(await p.api.hasKey({ owner: user }), { ok: true, value: true });
  });

  test("clear({mode:'bound'}) — удалён только блоб привязки", async () => {
    const p = makePage();
    const user = randomUUID();
    await p.api.store({ secret: 's', owner: user });
    p.local.setItem(NAMES.passkeyNoPrf, JSON.stringify({ v: 1 }));
    p.local.setItem(NAMES.passkeyGate, JSON.stringify({ v: 1, credId: p.json('passkeyBound').credId }));
    const keep = [NAMES.passkeyUser, NAMES.passkeyNoPrf, NAMES.passkeyGate].map((k) => [k, p.local.getItem(k)]);
    assert.deepEqual(await p.api.clear({ mode: 'bound' }), { ok: true });
    assert.equal(p.local.getItem(NAMES.passkeyBound), null);
    for (const [k, v] of keep) assert.equal(p.local.getItem(k), v, k);
    assert.deepEqual(await p.api.has({ owner: user }), { ok: true, value: false });
    assert.equal(p.auth.signalled.length, 0);
  });
});

describe('(7) браузер на Windows: ключ входа под PRF (BIO-041)', () => {
  test('createKey: RSA-2048, PKCS#8 под тем же AES-GCM, подпись challenge проверяется SPKI; в хранилище — только шифртекст', async () => {
    const p = makePage();
    const a = randomUUID();
    const res = await p.api.createKey({ owner: a });
    assert.equal(res.ok, true);
    assert.equal(res.algorithm, 'RS256');
    assert.equal(res.source, 'webauthn_prf');
    assert.deepEqual(Object.keys(res).sort(), ['algorithm', 'ok', 'source', 'value']);
    assert.deepEqual(p.auth.calls, { create: 1, get: 0 });
    const pub = await webcrypto.subtle.importKey('spki', fromB64u(res.value), RSA, true, ['verify']);
    assert.equal(pub.algorithm.modulusLength, 2048);
    assert.deepEqual([...pub.algorithm.publicExponent], [1, 0, 1]);

    const gate = p.json('passkeyGate');
    const stored = p.json('passkeyHelloKey');
    const tag = await tagOf(a);
    assert.deepEqual(Object.keys(stored).sort(), ['items', 'v']);
    assert.deepEqual(Object.keys(stored.items), [tag]);
    assert.equal(stored.items[tag].credId, gate.credId); // один passkey браузера: гейт и ключ входа
    // Шифртекст открывается ключом HKDF из PRF (info hello_key) — внутри PKCS#8 закрытого ключа той же пары.
    const pkcs8 = await openIndependently(p.auth, stored.items[tag], tag, 'hello_key');
    const priv = await webcrypto.subtle.importKey('pkcs8', pkcs8, RSA, true, ['sign']);
    const jwkPriv = await webcrypto.subtle.exportKey('jwk', priv);
    const jwkPub = await webcrypto.subtle.exportKey('jwk', pub);
    assert.equal(jwkPriv.n, jwkPub.n);
    const pkcs8b64u = b64u(pkcs8);
    const pkcs8b64 = Buffer.from(pkcs8).toString('base64');
    for (const v of p.local.items.values()) {
      assert.ok(!v.includes(pkcs8b64u.slice(0, 40)) && !v.includes(pkcs8b64.slice(0, 40)), 'PKCS#8 в открытом виде');
      assert.ok(!v.includes(jwkPriv.d.slice(0, 40)), 'закрытая экспонента');
    }
    // Ключ входа под другим назначением HKDF: ключом привязки не открывается.
    await assert.rejects(openIndependently(p.auth, stored.items[tag], tag, 'biometric_refresh'));

    const challenge = CHALLENGE();
    const sig = await p.api.sign({ owner: a, challenge });
    assert.deepEqual(Object.keys(sig).sort(), ['ok', 'value']);
    assert.equal(sig.ok, true);
    assert.equal(fromB64u(sig.value).length, 256);
    assert.ok(/^[A-Za-z0-9_-]+$/.test(sig.value));
    assert.equal(await verifySig(res.value, challenge, sig.value), true);
    assert.equal(await verifySig(res.value, CHALLENGE(), sig.value), false);
    assert.deepEqual(p.auth.calls, { create: 1, get: 1 }); // один диалог на вход
    assert.ok(p.auth.lastGet.extensions.prf);
  });

  test('два пользователя в одном браузере: один passkey, ключи раздельны; чужой owner и удаление', async () => {
    const p = makePage();
    const a = randomUUID();
    const b = randomUUID();
    const ka = await p.api.createKey({ owner: a });
    const kb = await p.api.createKey({ owner: b });
    assert.equal(kb.ok, true);
    assert.notEqual(ka.value, kb.value);
    assert.deepEqual(p.auth.calls, { create: 1, get: 1 }); // второй — без create(): ключ A не губится
    assert.equal(p.auth.creds.size, 1);
    const ch = CHALLENGE();
    const sa = await p.api.sign({ owner: a, challenge: ch });
    const sb = await p.api.sign({ owner: b, challenge: ch });
    assert.equal(await verifySig(ka.value, ch, sa.value), true);
    assert.equal(await verifySig(kb.value, ch, sb.value), true);
    assert.equal(await verifySig(ka.value, ch, sb.value), false);

    const calls = p.auth.calls.get;
    assert.deepEqual(await p.api.sign({ owner: randomUUID(), challenge: ch }), { ok: false, error: 'no_credential' });
    assert.equal(p.auth.calls.get, calls); // без диалога
    assert.deepEqual(await p.api.deleteKey({ owner: a }), { ok: true, value: true });
    assert.deepEqual(await p.api.deleteKey({ owner: a }), { ok: true, value: false });
    assert.deepEqual(await p.api.hasKey({ owner: a }), { ok: true, value: false });
    assert.deepEqual(await p.api.hasKey({ owner: b }), { ok: true, value: true });
    assert.deepEqual(await p.api.sign({ owner: a, challenge: ch }), { ok: false, error: 'no_credential' });
    assert.notEqual(p.json('passkeyGate'), null); // passkey браузера остаётся гейтом
    await p.api.deleteKey({ owner: b });
    assert.equal(p.local.getItem(NAMES.passkeyHelloKey), null);
    assert.equal(p.auth.signalled.length, 0);
  });

  test('подписывается только challenge входа: иначе failed без диалога', async () => {
    const p = makePage();
    const a = randomUUID();
    await p.api.createKey({ owner: a });
    const calls = p.auth.calls.get;
    for (const challenge of [
      undefined,
      '',
      'optomstroy-hello-unlock/v1:',
      `optomstroy-hello-unlock/v2:${randomBytes(32).toString('base64url')}`,
      `optomstroy-hello-unlock/v1:${randomBytes(32).toString('base64')}+/=`,
      `optomstroy-hello-unlock/v1:${'A'.repeat(70)}`,
      jwtLike(),
    ]) {
      assert.deepEqual(await p.api.sign({ owner: a, challenge }), { ok: false, error: 'failed' }, String(challenge));
    }
    assert.equal(p.auth.calls.get, calls);
  });

  test('гейт уже есть: createKey — тем же passkey, без create()', async () => {
    const p = makePage();
    await p.api.confirmPresence();
    const gate = p.local.getItem(NAMES.passkeyGate);
    const res = await p.api.createKey({ owner: randomUUID() });
    assert.equal(res.ok, true);
    assert.deepEqual(p.auth.calls, { create: 1, get: 1 });
    assert.equal(p.local.getItem(NAMES.passkeyGate), gate);
  });

  test('без PRF у Windows Hello — not_available/no_prf, passkey остаётся гейтом: дальше гейт перед PIN', async () => {
    const p = makePage({ auth: new FakeAuthenticator({ prfAtCreate: 'disabled' }) });
    const a = randomUUID();
    assert.deepEqual(await p.api.createKey({ owner: a }), { ok: false, error: 'not_available', reason: 'no_prf', gate: true });
    assert.notEqual(p.json('passkeyGate'), null);
    assert.equal(p.local.getItem(NAMES.passkeyHelloKey), null);
    assert.deepEqual(p.json('passkeyNoPrf'), { v: 1 });
    assert.equal(p.auth.signalled.length, 0); // passkey нужен гейту — ОС не сообщается
    const gate = await p.api.capability({ mode: 'gate' });
    assert.equal(gate.availability, 'available');
    assert.equal(gate.keysSupported, false);
    assert.deepEqual(await p.api.confirmPresence(), { ok: true });
    assert.deepEqual(p.auth.calls, { create: 1, get: 1 }); // тот же passkey
    assert.deepEqual(await p.api.createKey({ owner: a }), { ok: false, error: 'not_available', reason: 'no_prf', gate: true });
    assert.deepEqual(p.auth.calls, { create: 1, get: 1 }); // без диалога
  });

  test('PRF включён, но выхода нет и при get() — no_prf с гейтом', async () => {
    const p = makePage({ auth: new FakeAuthenticator({ prfAtCreate: 'enabled', prfAtGet: false }) });
    assert.deepEqual(await p.api.createKey({ owner: randomUUID() }), { ok: false, error: 'not_available', reason: 'no_prf', gate: true });
    assert.deepEqual(p.auth.calls, { create: 1, get: 1 });
    assert.deepEqual(p.json('passkeyNoPrf'), { v: 1 });
  });

  test('ключ пропал (нет выхода PRF или шифртекст не открывается) — no_credential, запись удалена', async () => {
    const p = makePage();
    const a = randomUUID();
    const b = randomUUID();
    await p.api.createKey({ owner: a });
    await p.api.createKey({ owner: b });
    const tagA = await tagOf(a);
    const stored = p.json('passkeyHelloKey');
    const ct = fromB64u(stored.items[tagA].ct);
    ct[5] ^= 0x80;
    stored.items[tagA].ct = b64u(ct);
    p.local.setItem(NAMES.passkeyHelloKey, JSON.stringify(stored));
    assert.deepEqual(await p.api.sign({ owner: a, challenge: CHALLENGE() }), { ok: false, error: 'no_credential' });
    assert.deepEqual(await p.api.hasKey({ owner: a }), { ok: true, value: false });
    assert.deepEqual(await p.api.hasKey({ owner: b }), { ok: true, value: true });
    p.auth.prfAtGet = false;
    assert.deepEqual(await p.api.sign({ owner: b, challenge: CHALLENGE() }), { ok: false, error: 'no_credential' });
    assert.equal(p.local.getItem(NAMES.passkeyHelloKey), null);
  });
});

describe('(8) ответы, хранилище и журнал — без секрета, выхода PRF и JWT', () => {
  test('сквозной сценарий: привязка, гейт, ключ входа, ошибки', async () => {
    const p = makePage({ auth: new FakeAuthenticator({ prfAtCreate: 'enabled' }) });
    const user = randomUUID();
    const secret = jwtLike();
    const secret2 = jwtLike();
    const responses = [];
    const call = async (m, args) => {
      const r = await p.api[m](args);
      responses.push([m, r]);
      return r;
    };
    responses.push(['capability', await p.api.capability({ mode: 'bound' })]);
    responses.push(['capability', await p.api.capability({ mode: 'gate' })]);
    await call('store', { secret, owner: user });
    await call('has', { owner: user });
    const readRes = await p.api.read({ owner: user }); // value — сам секрет: проверяется отдельно
    assert.equal(readRes.value, secret);
    await call('replace', { secret: secret2, owner: user });
    await call('read', { owner: randomUUID() });
    p.auth.errors.push('NotAllowedError');
    await call('read', { owner: user });
    await call('confirmPresence');
    await call('createKey', { owner: user });
    await call('sign', { owner: user, challenge: 'not-a-challenge' });
    await call('clear', { mode: 'gate' });
    await call('clear', { mode: 'bound' });
    responses.push(['state', p.page.state()]);
    p.auth.prfAtGet = false;
    await call('sign', { owner: user, challenge: CHALLENGE() });
    await call('store', { secret, owner: 7 });

    // Выходы PRF этого passkey (во всех кодировках) и производные.
    const leaks = [secret, secret2, ...secret.split('.'), ...secret2.split('.'), user];
    for (const cred of p.auth.creds.values()) {
      const out = Buffer.from(p.auth.prfOut(cred, enc(PRF_INPUT)));
      leaks.push(out.toString('hex'), out.toString('base64'), out.toString('base64url'), cred.secret.toString('base64url'));
    }
    const texts = [
      ['ответы', JSON.stringify(responses)],
      ['журнал', p.logs.join('\n')],
      ['хранилище', JSON.stringify([...p.local.items])],
    ];
    for (const [where, text] of texts) {
      assert.ok(!JWT_RE.test(text), `${where}: JWT-подобная строка`);
      for (const leak of leaks) assert.ok(!text.includes(leak.slice(0, 24)), `${where}: утечка`);
    }
    for (const [m, r] of responses) {
      if (m === 'createKey') continue; // value — открытый ключ SPKI
      if (r && 'value' in r) assert.equal(typeof r.value, 'boolean', m);
    }
    // Журнал — только коды исходов и имена исключений.
    assert.ok(p.logs.length > 0);
    for (const line of p.logs) assert.match(line, /^\[demo-passkey\] [A-Za-z]+: [a-z_]+( \([A-Za-z_]+\))?$/, line);
  });
});

describe('страница: forgetAll и state', () => {
  test('state — только признаки и числа; forgetAll сообщает ОС о каждом passkey один раз и удаляет записи', async () => {
    const p = makePage();
    assert.deepEqual(p.page.state(), { available: true, user: false, gate: false, bound: false, keys: 0, noPrf: false, keyInMemory: false });
    await p.api.confirmPresence();
    await p.api.createKey({ owner: randomUUID() });
    await p.api.createKey({ owner: randomUUID() });
    const st = p.page.state();
    assert.deepEqual(st, { available: true, user: true, gate: true, bound: false, keys: 2, noPrf: false, keyInMemory: false });
    const gate = p.json('passkeyGate').credId;
    assert.deepEqual(await p.page.forgetAll(), { signalled: 1 });
    assert.deepEqual(p.auth.signalled, [{ rpId: HOST, credentialId: gate }]);
    assert.deepEqual([...p.local.items.keys()].filter((k) => k.startsWith('optomstroy.demo.passkey')), []);
    assert.deepEqual(makePage({ env: false }).page.state(), { available: false });
  });
});
