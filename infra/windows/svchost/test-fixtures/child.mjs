// Тестовый дочерний процесс для infra/windows/tests/svchost.tests.ps1. Зависимостей нет.
// node child.mjs <режим> <папка-меток> [параметр]
//   graceful         — пишет журнал; на EOF stdin пишет stdin-eof.txt и выходит с кодом 0
//   graceful-orphan  — как graceful, но перед этим запускает «внука» (detached), который сам не завершается
//   eof-nonzero      — на EOF stdin выходит с кодом 3
//   ignore-stdin     — запускает «внука» (detached) и игнорирует stdin и сигналы
//   crash            — через 800 мс выходит с кодом 7
//   spam <N>         — пишет N строк с кириллицей в stdout, затем ждёт EOF stdin
//   alloc            — выделяет память блоками по 32 МБ, пока выделение не откажет (проверка jobMemoryLimitMB)
//   burn             — 2 с занимает процессор, пишет cpu.json (время ЦП в мс), затем ждёт EOF stdin
import { spawn } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';

const [mode, dir, param] = process.argv.slice(2);
const mark = (name, data) => writeFileSync(join(dir, name), typeof data === 'string' ? data : JSON.stringify(data));
const log = (msg) => process.stdout.write(JSON.stringify({ t: new Date().toISOString(), pid: process.pid, msg }) + '\n');

let grandchild = null;
if (mode === 'graceful-orphan' || mode === 'ignore-stdin') {
  const gc = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], { stdio: 'ignore', detached: true });
  gc.unref();
  grandchild = gc.pid;
}

process.on('SIGINT', () => log('SIGINT проигнорирован'));
process.on('SIGBREAK', () => log('SIGBREAK проигнорирован'));

const keepAlive = setInterval(() => log('работаю'), 500);

if (mode === 'graceful' || mode === 'graceful-orphan' || mode === 'eof-nonzero' || mode === 'spam' || mode === 'burn') {
  process.stdin.on('data', () => {});
  process.stdin.on('end', () => {
    log('stdin-eof: штатная остановка');
    mark('stdin-eof.txt', new Date().toISOString());
    clearInterval(keepAlive);
    setTimeout(() => process.exit(mode === 'eof-nonzero' ? 3 : 0), 300);
  });
}

if (mode === 'crash') {
  setTimeout(() => {
    process.stderr.write('сбой: выход с кодом 7\n');
    process.exit(7);
  }, 800);
}

if (mode === 'spam') {
  const n = Number(param ?? 1000);
  const pad = 'Проверка UTF-8 ёЁ — '.repeat(3);
  for (let i = 0; i < n; i++) process.stdout.write(`line ${String(i).padStart(6, '0')} ${pad}\n`);
}

process.stderr.write('stderr: Проверка вывода ошибок\n');
log('старт ' + mode);
mark('ready.json', {
  pid: process.pid,
  grandchild,
  argv: process.argv.slice(2),
  cwd: process.cwd(),
  envSet: process.env.SVC_TEST_VAR ?? null,
  envRemoved: process.env.SVC_TEST_REMOVE ?? null,
  envInherited: process.env.SVC_TEST_INHERIT ?? null,
  systemRoot: process.env.SystemRoot ?? null,
  hasPath: Boolean(process.env.PATH),
});

if (mode === 'alloc') {
  const keep = [];
  setTimeout(() => {
    for (;;) {
      keep.push(Buffer.alloc(32 * 1024 * 1024, 1));
      if (keep.length % 4 === 0) process.stdout.write(`выделено ${keep.length * 32} МБ\n`);
    }
  }, 300);
}

if (mode === 'burn') {
  const before = process.cpuUsage();
  const t0 = Date.now();
  let x = 0;
  while (Date.now() - t0 < 2000) x += Math.sqrt(x + 1);
  const used = process.cpuUsage(before);
  mark('cpu.json', { cpuMs: Math.round((used.user + used.system) / 1000), wallMs: Date.now() - t0, x: x > 0 });
}
