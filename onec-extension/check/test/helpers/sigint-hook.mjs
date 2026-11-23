// Для тестов: «Ctrl+C» через TEST_SIGINT_MS миллисекунд после старта (process.emit — как обработчик SIGINT программы
// его и получает; на Windows kill('SIGINT') завершает процесс сразу, без обработчика). В сборку не входит.
const ms = Number(process.env.TEST_SIGINT_MS || 0);
if (ms > 0) setTimeout(() => { process.emit('SIGINT', 'SIGINT'); }, ms).unref();
