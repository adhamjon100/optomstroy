/** Поток stdin в той мере, в какой он нужен наблюдателю (process.stdin или тестовый поток). */
export interface StdinLike {
  once(event: 'end' | 'close', listener: () => void): unknown;
  on(event: 'error', listener: (err: unknown) => void): unknown;
  resume(): unknown;
}

/**
 * Остановка по концу stdin (`POS_SHUTDOWN_ON_STDIN_EOF`, 16 §4.3). Под Windows у служб нет SIGTERM: хост службы
 * OptomstroySvc.exe просит дочерний node.exe остановиться, закрывая его stdin, и ждёт `stopTimeoutSeconds`.
 *
 * При `enabled=false` stdin не трогается вовсе (не открывается и не держит процесс). При `enabled=true` поток
 * переводится в режим чтения (данные отбрасываются), а первое из событий `end` / `close` / `error` вызывает
 * `trigger` ровно один раз; повторную остановку вместе с сигналом отсекает сам вызывающий (общий флаг остановки).
 * Если stdin не канал, а пустое устройство (`stdio: 'ignore'`), конец наступает сразу — флаг включают только там,
 * где stdin держит родитель (хост службы).
 *
 * @returns true, если наблюдатель установлен.
 */
export function shutdownOnStdinEof(
  enabled: boolean,
  trigger: (reason: 'stdin-eof') => void,
  stdin: () => StdinLike = () => process.stdin,
): boolean {
  if (!enabled) return false;
  const stream = stdin();
  let fired = false;
  const fire = () => {
    if (fired) return;
    fired = true;
    trigger('stdin-eof');
  };
  stream.once('end', fire);
  stream.once('close', fire);
  // Ошибка чтения канала (родитель исчез) — тоже конец: процесс без хоста службы работать не должен. Подписка
  // постоянная: повторная ошибка потока не должна стать необработанным событием 'error'.
  stream.on('error', fire);
  stream.resume();
  return true;
}
