// Заглушка API для проверки виртуального хоста Apache (infra/windows/tests/apache.tests.ps1).
// Слушает 127.0.0.1:<порт> и отвечает JSON-эхом: метод, путь, заголовки запроса, длина тела.
// Как pos-api, ставит свои заголовки безопасности и X-Powered-By — Apache должен заменить их без дублей.
// Запрос с ?wait=<секунды> отвечает через указанное время (long-poll оплаты, до 25 с).
// Запуск: node stub-upstream.mjs <порт>. Без зависимостей npm.
import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';

const port = Number(process.argv[2] ?? 3320);

const server = createServer((req, res) => {
  let length = 0;
  req.on('data', (chunk) => {
    length += chunk.length;
  });
  req.on('end', () => {
    // Журнал запросов (stdout): тест по нему проверяет, что запрещённое до API не дошло.
    process.stdout.write(`REQ ${req.method} ${req.headers.host ?? '-'} ${req.url} ${length}\n`);
    const url = new URL(req.url ?? '/', 'http://stub.invalid');
    const wait = Math.min(Number(url.searchParams.get('wait') ?? 0) || 0, 60);
    const body = JSON.stringify({
      stub: true,
      method: req.method,
      url: req.url,
      remote: req.socket.remoteAddress,
      headers: req.headers,
      bodyLength: length,
      waited: wait,
    });
    setTimeout(() => {
      res.setHeader('Content-Type', 'application/json; charset=utf-8');
      res.setHeader('X-Powered-By', 'Express');
      res.setHeader('X-Content-Type-Options', 'nosniff');
      res.setHeader('Strict-Transport-Security', 'max-age=63072000; includeSubDomains');
      res.setHeader('Content-Security-Policy', "frame-ancestors 'none'");
      res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
      res.setHeader('Cache-Control', 'no-store');
      res.setHeader('X-Request-Id', req.headers['x-request-id'] ?? randomUUID());
      res.end(body);
    }, wait * 1000);
  });
});

server.listen(port, '127.0.0.1', () => {
  process.stdout.write(`stub-upstream: listening 127.0.0.1:${port}\n`);
});
