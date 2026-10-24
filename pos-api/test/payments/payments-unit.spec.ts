import { Logger } from '@nestjs/common';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { ProblemException } from '../../src/common/problem-details/problem.exception.js';
import {
  MAX_WAITS_PER_PROCESS,
  MAX_WAITS_PER_USER,
  PaymentStatusWaiter,
} from '../../src/payments/long-poll/payment-status-waiter.js';
import { QrStatusService, qrCancelRetryDelaySeconds } from '../../src/payments/qr/qr-status.service.js';

/**
 * Фоновая отмена QR в 1С после аннулирования (10 PAY-052, 05 SYNC-078; ревью F-orders-1c-8) — без БД:
 * сбой БД/провайдера не превращается в unhandled rejection (процесс pos-api не падает), только журнал; повторы
 * отмены — 1, 2, 5 мин.
 */
describe('QrStatusService.cancelInBackground', () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('ошибка БД при отмене (repo.findById) — журнал, без unhandled rejection', async () => {
    const warn = vi.spyOn(Logger.prototype, 'warn').mockImplementation(() => undefined);
    const unhandled: unknown[] = [];
    const onUnhandled = (e: unknown) => unhandled.push(e);
    process.on('unhandledRejection', onUnhandled);
    try {
      const repo = { findById: () => Promise.reject(new Error('connection terminated (тест)')) };
      const svc = new QrStatusService(
        {} as never,
        {} as never,
        { now: () => new Date() },
        {} as never,
        repo as never,
        {} as never,
        { dynamic: {} } as never,
        {} as never,
      );
      svc.cancelInBackground('0192f3a1-0000-7000-8000-000000000001', 'method_changed');
      await new Promise((r) => setTimeout(r, 20));
      expect(unhandled).toEqual([]);
      expect(warn).toHaveBeenCalledWith(
        expect.objectContaining({ paymentId: '0192f3a1-0000-7000-8000-000000000001', reason: 'method_changed' }),
        'payments.qr.cancel_background_failed',
      );
    } finally {
      process.off('unhandledRejection', onUnhandled);
    }
  });

  it('расписание повторов отмены (SYNC-078): 1 мин, затем 2 мин, далее 5 мин', () => {
    expect(qrCancelRetryDelaySeconds(0)).toBe(60);
    expect(qrCancelRetryDelaySeconds(59_000)).toBe(60);
    expect(qrCancelRetryDelaySeconds(61_000)).toBe(120);
    expect(qrCancelRetryDelaySeconds(179_000)).toBe(120);
    expect(qrCancelRetryDelaySeconds(181_000)).toBe(300);
    expect(qrCancelRetryDelaySeconds(3_600_000)).toBe(300);
  });
});

/** Long-polling `?wait=` (08 §4.9.2; 12 T-PAY-030; 11 §2.2 STRIDE D; ревью F-security-4): пределы одновременных ожиданий. */
describe('PaymentStatusWaiter: пределы ожиданий', () => {
  it('на пользователя ≤ MAX_WAITS_PER_USER (сверх — null, ответ сразу); тот же платёж — 429; освобождение возвращает слот', () => {
    vi.spyOn(Logger.prototype, 'warn').mockImplementation(() => undefined);
    const w = new PaymentStatusWaiter({} as never, { now: () => new Date() });
    const releases = Array.from({ length: MAX_WAITS_PER_USER }, (_, i) => w.acquire(`p${i}`, 'u1', 25));
    expect(releases.every((r) => typeof r === 'function')).toBe(true);
    expect(w.acquire('p-extra', 'u1', 25)).toBeNull();
    expect(() => w.acquire('p0', 'u1', 25)).toThrow(ProblemException);
    expect(typeof w.acquire('p-extra', 'u2', 25)).toBe('function');
    releases[0]!();
    releases[0]!();
    expect(typeof w.acquire('p-extra', 'u1', 25)).toBe('function');
  });

  it('на процесс ≤ MAX_WAITS_PER_PROCESS', () => {
    vi.spyOn(Logger.prototype, 'warn').mockImplementation(() => undefined);
    const w = new PaymentStatusWaiter({} as never, { now: () => new Date() });
    for (let i = 0; i < MAX_WAITS_PER_PROCESS; i++) expect(w.acquire('p', `u${i}`, 25)).not.toBeNull();
    expect(w.acquire('p', 'u-last', 25)).toBeNull();
  });
});
