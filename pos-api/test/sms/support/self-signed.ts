import { generateKeyPairSync, sign, X509Certificate } from 'node:crypto';

/**
 * Самоподписанный сертификат для локального HTTPS-стенда SMSPro (тесты не ходят в реальный SMSPro).
 * Сборка X.509 v3 (ECDSA P-256 / SHA-256, SAN: localhost, 127.0.0.1) вручную в DER — без openssl и сторонних
 * пакетов. Адаптер принимает только `https://` (SMS-003), поэтому стенд — HTTPS с этим CA в агенте клиента.
 */
function len(n: number): Buffer {
  if (n < 0x80) return Buffer.from([n]);
  const bytes: number[] = [];
  for (let v = n; v > 0; v = Math.floor(v / 256)) bytes.unshift(v & 0xff);
  return Buffer.from([0x80 | bytes.length, ...bytes]);
}
const tlv = (tag: number, body: Buffer): Buffer => Buffer.concat([Buffer.from([tag]), len(body.length), body]);
const seq = (...items: Buffer[]): Buffer => tlv(0x30, Buffer.concat(items));
const set = (...items: Buffer[]): Buffer => tlv(0x31, Buffer.concat(items));
const int = (v: Buffer): Buffer => tlv(0x02, v[0] & 0x80 ? Buffer.concat([Buffer.from([0]), v]) : v);
const utf8 = (s: string): Buffer => tlv(0x0c, Buffer.from(s, 'utf8'));
const octet = (b: Buffer): Buffer => tlv(0x04, b);
const bitString = (b: Buffer): Buffer => tlv(0x03, Buffer.concat([Buffer.from([0]), b]));
const bool = (v: boolean): Buffer => tlv(0x01, Buffer.from([v ? 0xff : 0]));

function oid(dotted: string): Buffer {
  const parts = dotted.split('.').map(Number);
  const out: number[] = [40 * parts[0] + parts[1]];
  for (const p of parts.slice(2)) {
    const stack: number[] = [];
    let v = p;
    stack.unshift(v & 0x7f);
    v = Math.floor(v / 128);
    while (v > 0) {
      stack.unshift((v & 0x7f) | 0x80);
      v = Math.floor(v / 128);
    }
    out.push(...stack);
  }
  return tlv(0x06, Buffer.from(out));
}

function utcTime(d: Date): Buffer {
  const p = (n: number) => String(n).padStart(2, '0');
  const s = `${p(d.getUTCFullYear() % 100)}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}${p(d.getUTCHours())}${p(
    d.getUTCMinutes(),
  )}${p(d.getUTCSeconds())}Z`;
  return tlv(0x17, Buffer.from(s, 'ascii'));
}

export interface SelfSignedCert {
  readonly cert: string;
  readonly key: string;
}

export function createSelfSignedCert(commonName = 'localhost'): SelfSignedCert {
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const algo = seq(oid('1.2.840.10045.4.3.2')); // ecdsa-with-SHA256
  const name = seq(set(seq(oid('2.5.4.3'), utf8(commonName))));
  const now = Date.now();
  const validity = seq(utcTime(new Date(now - 3600_000)), utcTime(new Date(now + 7 * 24 * 3600_000)));
  const spki = publicKey.export({ type: 'spki', format: 'der' });
  const san = seq(
    tlv(0x82, Buffer.from('localhost', 'ascii')), // dNSName
    tlv(0x87, Buffer.from([127, 0, 0, 1])), // iPAddress
  );
  const extensions = tlv(
    0xa3,
    seq(
      seq(oid('2.5.29.19'), bool(true), octet(seq(bool(true)))), // basicConstraints: cA=TRUE
      seq(oid('2.5.29.17'), octet(san)), // subjectAltName
    ),
  );
  const tbs = seq(
    tlv(0xa0, int(Buffer.from([2]))), // v3
    int(Buffer.from([1, 2, 3, 4, 5, 6, 7, 8])),
    algo,
    name,
    validity,
    name,
    spki,
    extensions,
  );
  const signature = sign('sha256', tbs, privateKey); // DER ECDSA-Sig-Value
  const der = seq(tbs, algo, bitString(signature));
  const b64 = der.toString('base64').replace(/(.{64})/g, '$1\n');
  const cert = `-----BEGIN CERTIFICATE-----\n${b64.trimEnd()}\n-----END CERTIFICATE-----\n`;
  new X509Certificate(cert); // проверка разбора
  return { cert, key: privateKey.export({ type: 'pkcs8', format: 'pem' }).toString() };
}
