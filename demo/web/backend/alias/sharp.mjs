// Подмена нативного пакета sharp (sync/images/image-processor.js): обработка фото в браузерном бэкенде не нужна —
// фото готовятся при сборке снимка (WP-B4). Любой вызов — понятная ошибка, а не «пустой» результат.
function sharp() {
  const e = new Error('sharp недоступен в браузерном бэкенде (фото готовятся при сборке демо)');
  e.code = 'ERR_DEMO_UNSUPPORTED';
  throw e;
}
sharp.cache = () => undefined;
sharp.concurrency = () => 1;
sharp.versions = {};
export default sharp;
