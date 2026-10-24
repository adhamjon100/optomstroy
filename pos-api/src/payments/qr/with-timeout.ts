/**
 * Вызов внешней системы (1С) с таймаутом вызывающего: `signal` прерывает запрос адаптера (OnecCallOptions.signal), а
 * `Promise.race` гарантирует возврат управления, даже если реализация порта сигнал не учитывает (08 §2.10:
 * `ONEC_SYNC_CHECK_TIMEOUT_MS` для синхронных вызовов при оформлении).
 */
export class CallTimeoutError extends Error {
  override readonly name = 'CallTimeoutError';
  readonly retryable = true;

  constructor(readonly timeoutMs: number) {
    super(`вызов не завершился за ${timeoutMs} мс`);
  }
}

export async function withTimeout<T>(timeoutMs: number, call: (signal: AbortSignal) => Promise<T>): Promise<T> {
  const ac = new AbortController();
  let timer: NodeJS.Timeout | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      ac.abort();
      reject(new CallTimeoutError(timeoutMs));
    }, timeoutMs);
    timer.unref?.();
  });
  try {
    return await Promise.race([call(ac.signal), timeout]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}
