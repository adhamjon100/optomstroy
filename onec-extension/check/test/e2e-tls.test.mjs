// TLS: сертификаты через openssl во временной папке (нет openssl — тесты пропускаются).
// Самоподписанный центр без --ca → код 2 и «укажите корневой сертификат»; --ca → проходит; --insecure → проходит,
// баннер и S2 ЗАМЕЧАНИЕ; другое имя → «выдан на другое имя»; http:// без --allow-http → код 2.
import { test, after, before } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import fs from 'node:fs';
import { spawnSync } from 'node:child_process';
import { mockWithSecrets, makeConfig, runMain, readProtocol, check, tmpDir } from './helpers/env.mjs';

const hasOpenssl = spawnSync('openssl', ['version'], { encoding: 'utf8' }).status === 0;
const dirs = [];
const mocks = [];
let certDir;
let ca, leaf, other;
after(async () => { for (const m of mocks) await m.close(); for (const d of dirs) fs.rmSync(d, { recursive: true, force: true }); });

function ossl(args, cwd) {
  const r = spawnSync('openssl', args, { cwd, encoding: 'utf8', env: { ...process.env, MSYS_NO_PATHCONV: '1' } });
  if (r.status !== 0) throw new Error(`openssl ${args.join(' ')}: ${r.stderr}`);
}

before(() => {
  if (!hasOpenssl) return;
  certDir = tmpDir('oc-tls-');
  dirs.push(certDir);
  ossl(['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'ca.key', '-out', 'ca.pem', '-days', '30', '-subj', '/CN=Test CA Vymyshlennyj'], certDir);
  fs.writeFileSync(path.join(certDir, 'ext.cnf'), 'subjectAltName=DNS:localhost,IP:127.0.0.1\n');
  ossl(['req', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'srv.key', '-out', 'srv.csr', '-subj', '/CN=localhost'], certDir);
  ossl(['x509', '-req', '-in', 'srv.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key', '-CAcreateserial', '-out', 'srv.pem', '-days', '20', '-extfile', 'ext.cnf'], certDir);
  fs.writeFileSync(path.join(certDir, 'ext2.cnf'), 'subjectAltName=DNS:drugoe-imya.test\n');
  ossl(['req', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'srv2.key', '-out', 'srv2.csr', '-subj', '/CN=drugoe-imya.test'], certDir);
  ossl(['x509', '-req', '-in', 'srv2.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key', '-CAcreateserial', '-out', 'srv2.pem', '-days', '60', '-extfile', 'ext2.cnf'], certDir);
  ca = path.join(certDir, 'ca.pem');
  leaf = { key: fs.readFileSync(path.join(certDir, 'srv.key')), cert: fs.readFileSync(path.join(certDir, 'srv.pem')) };
  other = { key: fs.readFileSync(path.join(certDir, 'srv2.key')), cert: fs.readFileSync(path.join(certDir, 'srv2.pem')) };
});

async function setup(hostname = 'localhost', pair = leaf) {
  const { mock, password, clientKey } = await mockWithSecrets({ tls: { ...pair, hostname } });
  mocks.push(mock);
  const dir = tmpDir('oc-tlsr-');
  dirs.push(dir);
  return { mock, dir, cfg: makeConfig(dir, { baseUrl: mock.baseUrl, password, clientKey }) };
}

test('самоподписанный центр без --ca → код 2, «укажите корневой сертификат»', { skip: !hasOpenssl }, async () => {
  const { dir, cfg } = await setup();
  const r = await runMain(['--config', cfg, '--no-manual', '--checks', 'S']);
  assert.equal(r.code, 2, r.out.slice(-800));
  assert.match(r.out, /укажите корневой сертификат/);
  assert.equal(check(readProtocol(path.join(dir, 'protokoly')), 'S2').verdict, 'FAIL');
});

test('--ca → сертификат проверен; срок < 30 дней — замечание', { skip: !hasOpenssl }, async () => {
  const { dir, cfg } = await setup();
  const r = await runMain(['--config', cfg, '--no-manual', '--ca', ca, '--checks', 'S,A,H']);
  assert.equal(r.code, 0, r.out.slice(-1500));
  const s2 = check(readProtocol(path.join(dir, 'protokoly')), 'S2');
  assert.equal(s2.verdict, 'WARN');
  assert.match(s2.findings.map((f) => f.text).join(' '), /истекает через/);
});

test('--insecure → проходит, баннер и S2 ЗАМЕЧАНИЕ', { skip: !hasOpenssl }, async () => {
  const { dir, cfg } = await setup();
  const r = await runMain(['--config', cfg, '--no-manual', '--insecure', '--checks', 'S,A,H']);
  assert.equal(r.code, 0, r.out.slice(-1500));
  assert.match(r.out, /СЕРТИФИКАТ НЕ ПРОВЕРЯЛСЯ/);
  const p = readProtocol(path.join(dir, 'protokoly'));
  assert.equal(check(p, 'S2').verdict, 'WARN');
  assert.ok(p.texts[0].includes('СЕРТИФИКАТ НЕ ПРОВЕРЯЛСЯ'));
});

test('сертификат на другое имя → «выдан на другое имя»', { skip: !hasOpenssl }, async () => {
  const { cfg } = await setup('localhost', other);
  const r = await runMain(['--config', cfg, '--no-manual', '--ca', ca, '--checks', 'S']);
  assert.equal(r.code, 2, r.out.slice(-800));
  assert.match(r.out, /выдан на другое имя \(DNS:drugoe-imya\.test\), а адрес — localhost/);
});

test('http:// без --allow-http → код 2', async () => {
  const dir = tmpDir('oc-http-');
  dirs.push(dir);
  const cfg = makeConfig(dir, { baseUrl: 'http://127.0.0.1:9/ut_test/hs', password: 'Vymysel-1', clientKey: 'vymysel-2' });
  const r = await runMain(['--config', cfg, '--no-manual']);
  assert.equal(r.code, 2);
  assert.match(r.out, /--allow-http/);
});
