// WP-B1, приёмка: шим `crypto` (shims/node-crypto.cjs на @noble) и `buffer` (base64url) совпадают с node:crypto на
// векторах — sha256, sha1, sha512/384/224, md5, HMAC, hkdf, aes-256-gcm шифрование и расшифровка в обе стороны,
// base64url; плюс модули pos-api, которые ими пользуются (cursor-seal, sms-text-sealer), в сборке с шимами дают
// те же шифртексты, что и в Node.
//   node --test "demo/web/backend/test/*.test.mjs"
import assert from 'node:assert/strict';
import * as nodeCrypto from 'node:crypto';
import { before, describe, test } from 'node:test';
import { pathToFileURL } from 'node:url';
import { DIST } from '../lib/paths.mjs';
import { bundleForTest } from './support/bundle-for-test.mjs';

let shim; // { crypto, Buffer, seal, SmsTextSealer }
before(async () => {
  shim = await bundleForTest(
    'crypto-shim',
    `import crypto from 'node:crypto';
     import { Buffer } from 'node:buffer';
     import * as seal from '@pos-api-dist/catalog/common/cursor-seal.js';
     import { SmsTextSealer } from '@pos-api-dist/notifications/sms/sms-text-sealer.js';
     export { crypto, Buffer, seal, SmsTextSealer };`,
  );
});

const NB = globalThis.Buffer; // настоящий Buffer Node
const rnd = (n) => nodeCrypto.randomBytes(n);
const hex = (b) => NB.from(b instanceof ArrayBuffer ? new Uint8Array(b) : b).toString('hex');
const SB = (b) => shim.Buffer.from(new Uint8Array(b)); // Buffer шима из байтов
const inputs = () => [
  ['пусто', NB.alloc(0)],
  ['abc', NB.from('abc')],
  ['кириллица utf8', NB.from('Привет, Оптомстрой! ₸ сом', 'utf8')],
  ['64 байта', rnd(64)],
  ['1000 байт', rnd(1000)],
  ['1 МБ', rnd(1 << 20)],
];

describe('хэши', () => {
  for (const alg of ['sha256', 'sha1', 'sha512', 'sha384', 'sha224', 'md5']) {
    test(`${alg}: digest hex/base64/base64url/buffer`, () => {
      for (const [name, data] of inputs()) {
        const want = nodeCrypto.createHash(alg).update(data).digest();
        const h = shim.crypto.createHash(alg).update(SB(data));
        const got = h.digest();
        assert.equal(hex(got), hex(want), `${alg} ${name}`);
        for (const enc of ['hex', 'base64', 'base64url']) {
          assert.equal(shim.crypto.createHash(alg).update(SB(data)).digest(enc), nodeCrypto.createHash(alg).update(data).digest(enc), `${alg} ${name} ${enc}`);
        }
      }
    });
  }
  test('sha256: строки с кодировкой входа, несколько update, copy()', () => {
    const want = nodeCrypto.createHash('sha256').update('часть 1 ').update('deadbeef', 'hex').update('AAEC', 'base64').digest('hex');
    const h = shim.crypto.createHash('sha256').update('часть 1 ').update('deadbeef', 'hex').update('AAEC', 'base64');
    const c = h.copy();
    assert.equal(h.digest('hex'), want);
    assert.equal(c.digest('hex'), want);
    assert.throws(() => h.digest('hex'), /Digest already called/);
  });
  test('crypto.hash (одним вызовом)', () => {
    for (const [, data] of inputs().slice(0, 4)) {
      assert.equal(shim.crypto.hash('sha256', SB(data)), nodeCrypto.hash('sha256', data));
      assert.equal(shim.crypto.hash('sha1', SB(data), 'base64'), nodeCrypto.hash('sha1', data, 'base64'));
    }
  });
  test('неизвестный алгоритм — ошибка', () => {
    assert.throws(() => shim.crypto.createHash('whirlpool'), /Digest method not supported/);
  });
});

describe('HMAC', () => {
  for (const alg of ['sha256', 'sha512', 'sha1']) {
    test(`hmac-${alg}: ключи строкой, коротким, длинным (больше блока)`, () => {
      const keys = ['секрет', rnd(16), rnd(32), rnd(200)];
      for (const key of keys) {
        for (const [name, data] of inputs().slice(0, 5)) {
          const want = nodeCrypto.createHmac(alg, key).update(data).digest('hex');
          const got = shim.crypto.createHmac(alg, typeof key === 'string' ? key : SB(key)).update(SB(data)).digest('hex');
          assert.equal(got, want, `${alg} ${name} key=${typeof key === 'string' ? 'str' : key.length}`);
        }
      }
      const k = rnd(32);
      assert.equal(
        shim.crypto.createHmac(alg, SB(k)).update('a').update('\0').update('b').digest('base64url'),
        nodeCrypto.createHmac(alg, k).update('a').update('\0').update('b').digest('base64url'),
      );
    });
  }
});

describe('hkdf', () => {
  test('hkdfSync sha256/sha512: разные ikm, salt, info и длины; результат — ArrayBuffer', () => {
    const cases = [
      ['sha256', rnd(32), rnd(16), NB.from('optomstroy:sms-outbox-text:v1'), 32],
      ['sha256', NB.from('пароль'), NB.from('optomstroy.sms'), NB.from('info'), 42],
      ['sha256', rnd(64), NB.alloc(0), NB.alloc(0), 64],
      ['sha512', rnd(48), rnd(32), NB.from('x'), 100],
    ];
    for (const [alg, ikm, salt, info, len] of cases) {
      const want = nodeCrypto.hkdfSync(alg, ikm, salt, info, len);
      const got = shim.crypto.hkdfSync(alg, SB(ikm), SB(salt), SB(info), len);
      assert.ok(got instanceof ArrayBuffer, 'hkdfSync возвращает ArrayBuffer, как в Node');
      assert.equal(hex(got), hex(want), `${alg} len=${len}`);
    }
  });
});

describe('aes-256-gcm', () => {
  const sizes = [0, 1, 15, 16, 17, 100, 4096];
  test('шифрование шимом = шифрованию Node (шифртекст и тег)', () => {
    for (const n of sizes) {
      const key = rnd(32);
      const iv = rnd(12);
      const aad = rnd(20);
      const pt = rnd(n);
      const c = nodeCrypto.createCipheriv('aes-256-gcm', key, iv);
      c.setAAD(aad);
      const wantCt = NB.concat([c.update(pt), c.final()]);
      const wantTag = c.getAuthTag();
      const s = shim.crypto.createCipheriv('aes-256-gcm', SB(key), SB(iv));
      s.setAAD(SB(aad));
      const gotCt = shim.Buffer.concat([s.update(SB(pt)), s.final()]);
      assert.equal(hex(gotCt), hex(wantCt), `ct n=${n}`);
      assert.equal(hex(s.getAuthTag()), hex(wantTag), `tag n=${n}`);
    }
  });
  test('Node шифрует → шим расшифровывает', () => {
    for (const n of sizes) {
      const key = rnd(32);
      const iv = rnd(12);
      const aad = NB.from(`sms-outbox-${n}`);
      const pt = NB.from('Код входа: 246810. '.repeat(Math.max(1, n >> 4)).slice(0, n));
      const c = nodeCrypto.createCipheriv('aes-256-gcm', key, iv);
      c.setAAD(aad);
      const ct = NB.concat([c.update(pt), c.final()]);
      const tag = c.getAuthTag();
      const d = shim.crypto.createDecipheriv('aes-256-gcm', SB(key), SB(iv));
      d.setAAD(SB(aad));
      d.setAuthTag(SB(tag));
      const out = shim.Buffer.concat([d.update(SB(ct)), d.final()]);
      assert.equal(hex(out), hex(pt), `n=${n}`);
    }
  });
  test('шим шифрует → Node расшифровывает (строки utf8, как в pos-api)', () => {
    const key = rnd(32);
    const iv = rnd(12);
    const text = 'Ваш код 246810 — не сообщайте его никому';
    const s = shim.crypto.createCipheriv('aes-256-gcm', SB(key), SB(iv));
    s.setAAD(shim.Buffer.from('id-1', 'utf8'));
    const ct = shim.Buffer.concat([s.update(text, 'utf8'), s.final()]);
    const tag = s.getAuthTag();
    const d = nodeCrypto.createDecipheriv('aes-256-gcm', key, iv);
    d.setAAD(NB.from('id-1', 'utf8'));
    d.setAuthTag(NB.from(new Uint8Array(tag)));
    assert.equal(NB.concat([d.update(NB.from(new Uint8Array(ct))), d.final()]).toString('utf8'), text);
  });
  test('подделка тега, шифртекста или AAD — ошибка расшифровки', () => {
    const key = rnd(32);
    const iv = rnd(12);
    const c = nodeCrypto.createCipheriv('aes-256-gcm', key, iv);
    c.setAAD(NB.from('aad'));
    const ct = NB.concat([c.update(NB.from('secret payload')), c.final()]);
    const tag = c.getAuthTag();
    const attempt = (k, i, a, t, x) => {
      const d = shim.crypto.createDecipheriv('aes-256-gcm', SB(k), SB(i));
      d.setAAD(SB(a));
      d.setAuthTag(SB(t));
      return shim.Buffer.concat([d.update(SB(x)), d.final()]);
    };
    const badTag = NB.from(tag);
    badTag[0] ^= 1;
    const badCt = NB.from(ct);
    badCt[3] ^= 0x80;
    assert.throws(() => attempt(key, iv, NB.from('aad'), badTag, ct), /authenticate/);
    assert.throws(() => attempt(key, iv, NB.from('aad'), tag, badCt), /authenticate/);
    assert.throws(() => attempt(key, iv, NB.from('AAD'), tag, ct), /authenticate/);
    assert.equal(attempt(key, iv, NB.from('aad'), tag, ct).toString('utf8'), 'secret payload');
  });
  test('другие шифры — понятная ошибка', () => {
    assert.throws(() => shim.crypto.createCipheriv('aes-128-cbc', SB(rnd(16)), SB(rnd(16))), /Unsupported cipher/);
  });
});

describe('base64url (buffer 5.7.1 + шим)', () => {
  test('Buffer.from / toString / byteLength / write / isEncoding совпадают с Node', () => {
    for (let n = 0; n <= 70; n++) {
      const b = rnd(n);
      const s = b.toString('base64url');
      assert.equal(SB(b).toString('base64url'), s, `toString n=${n}`);
      assert.equal(hex(shim.Buffer.from(s, 'base64url')), hex(b), `from n=${n}`);
      assert.equal(shim.Buffer.byteLength(s, 'base64url'), NB.byteLength(s, 'base64url'), `byteLength n=${n}`);
      const w = shim.Buffer.alloc(n);
      const written = w.write(s, 0, 'base64url');
      assert.equal(written, NB.alloc(n).write(s, 0, 'base64url'), `write n=${n}`);
      assert.equal(hex(w), hex(b), `write bytes n=${n}`);
    }
    assert.equal(shim.Buffer.isEncoding('base64url'), true);
    assert.equal(shim.Buffer.isEncoding('BASE64URL'), true);
    // «-» и «_» — алфавит base64url; паддинг не пишется
    const special = NB.from([0xfb, 0xff, 0xbf, 0xfe]);
    assert.equal(SB(special).toString('base64url'), special.toString('base64url'));
    assert.equal(SB(special).toString('base64url').includes('='), false);
  });
  test('digest("base64url") и токены pos-api', () => {
    const tok = rnd(32);
    assert.equal(
      shim.crypto.createHash('sha256').update(tok.toString('base64url')).digest('base64url'),
      nodeCrypto.createHash('sha256').update(tok.toString('base64url')).digest('base64url'),
    );
  });
});

describe('случайные числа и сравнение', () => {
  test('randomBytes, randomUUID (v4), randomInt (диапазон)', () => {
    assert.equal(shim.crypto.randomBytes(48).length, 48);
    for (let i = 0; i < 50; i++) assert.match(shim.crypto.randomUUID(), /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
    for (let i = 0; i < 500; i++) {
      const x = shim.crypto.randomInt(100000, 1000000);
      assert.ok(Number.isInteger(x) && x >= 100000 && x < 1000000);
      const y = shim.crypto.randomInt(10);
      assert.ok(y >= 0 && y < 10);
    }
  });
  test('timingSafeEqual: равные, разные, разной длины (ошибка с кодом Node)', () => {
    const a = rnd(32);
    assert.equal(shim.crypto.timingSafeEqual(SB(a), SB(a)), true);
    const b = NB.from(a);
    b[31] ^= 1;
    assert.equal(shim.crypto.timingSafeEqual(SB(a), SB(b)), false);
    assert.throws(() => shim.crypto.timingSafeEqual(SB(a), SB(rnd(31))), (e) => e.code === 'ERR_CRYPTO_TIMING_SAFE_EQUAL_LENGTH');
  });
  test('асимметричные функции — явная ошибка (ключ JWT подменён alias/jwt-keys.mjs)', () => {
    assert.throws(() => shim.crypto.generateKeyPairSync('ed25519'), (e) => e.code === 'ERR_DEMO_UNSUPPORTED');
  });
});

describe('модули pos-api с шимами = в Node', () => {
  test('cursor-seal: sealCursor детерминирован — одинаковый курсор; openCursor открывает курсор Node', async () => {
    const native = await import(pathToFileURL(`${DIST}/catalog/common/cursor-seal.js`).href);
    for (let i = 0; i < 20; i++) {
      const key = rnd(32);
      const aad = `catalog.products:v1:${i}`;
      const plain = JSON.stringify({ k: [i, 'Смеситель', 12.5], s: 'available:desc' });
      const want = native.sealCursor(key, aad, plain);
      const got = shim.seal.sealCursor(SB(key), aad, plain);
      assert.equal(got, want);
      assert.equal(shim.seal.openCursor(SB(key), aad, want), plain);
      assert.equal(shim.seal.openCursor(SB(key), aad + 'x', want), undefined);
      assert.equal(shim.seal.openCursor(SB(key), aad, want + 'A'), undefined);
    }
  });
  test('SmsTextSealer: hkdf-ключ и aes-gcm — Node открывает шифртекст шима и наоборот', async () => {
    const native = await import(pathToFileURL(`${DIST}/notifications/sms/sms-text-sealer.js`).href);
    const secret = rnd(32).toString('base64url');
    const ring = { currentVersion: 1, get: (v) => (v === 1 ? secret : undefined) };
    const a = new shim.SmsTextSealer(ring);
    const b = new native.SmsTextSealer(ring);
    const text = 'Оптомстрой: код 246810';
    assert.equal(b.open('sms-1', a.seal('sms-1', text)), text);
    assert.equal(a.open('sms-2', b.seal('sms-2', text)), text);
    assert.throws(() => a.open('sms-3', b.seal('sms-2', text)), /подлинности/);
  });
});
