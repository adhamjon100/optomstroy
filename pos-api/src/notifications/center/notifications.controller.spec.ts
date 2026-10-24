import { describe, expect, it } from 'vitest';
import { ProblemException } from '../../common/problem-details/problem.exception.js';
import { isoDateTime, NotificationsController } from './notifications.controller.js';

/**
 * `since` / `before` центра уведомлений (08 §4.16; OpenAPI `format: date-time`, RFC 3339): смещение обязательно
 * (ревью RC-7). Без смещения `new Date` брал бы пояс процесса — граница «до момента» сдвигалась бы при `TZ` ≠ UTC.
 * **Тестовые данные**: фейк `NotificationsService`, без БД.
 */
function problem(fn: () => unknown): ProblemException {
  try {
    fn();
  } catch (e) {
    if (e instanceof ProblemException) return e;
    throw e;
  }
  throw new Error('ожидалась ProblemException');
}

describe('notifications: since/before — RFC 3339 со смещением (RC-7)', () => {
  it.each([
    ['2026-10-23T10:00:00Z', '2026-10-23T10:00:00.000Z'],
    ['2026-10-23T10:00:00.123Z', '2026-10-23T10:00:00.123Z'],
    ['2026-10-23T10:00:00.123456Z', '2026-10-23T10:00:00.123Z'],
    ['2026-10-23T16:00:00+06:00', '2026-10-23T10:00:00.000Z'],
    ['2026-10-23T05:30:00-04:30', '2026-10-23T10:00:00.000Z'],
    ['2026-10-23t10:00:00z', '2026-10-23T10:00:00.000Z'],
  ])('%s → %s (UTC)', (raw, utc) => {
    expect(isoDateTime({ before: raw }, 'before')).toBe(utc);
  });

  it.each([
    '2026-10-23T10:00:00', // без смещения — пояс процесса (дефект RC-7)
    '2026-10-23T10:00:00.000',
    '2026-10-23T10:00',
    '2026-10-23T10:00Z',
    '2026-10-23',
    '2026-10-23 10:00:00Z',
    '2026-10-23T10:00:00+0600',
    '2026-10-23T10:00:00 06:00', // «+» без URL-кодирования превращается в пробел
    '2026-13-01T00:00:00Z',
    'yesterday',
  ])('%s → 400 VALIDATION_FAILED (format)', (raw) => {
    const e = problem(() => isoDateTime({ since: raw }, 'since'));
    expect(e.code).toBe('VALIDATION_FAILED');
    expect(e.getStatus()).toBe(400);
    expect(e.extensions.errors).toEqual([expect.objectContaining({ field: 'since', rule: 'format' })]);
  });

  it('параметр не задан или пуст — undefined', () => {
    expect(isoDateTime({}, 'before')).toBeUndefined();
    expect(isoDateTime({ before: '' }, 'before')).toBeUndefined();
  });

  it('POST /notifications/read-all: before без смещения → 400, сервис не вызывается; со смещением — граница в UTC', async () => {
    const calls: (string | undefined)[] = [];
    const svc = {
      readAll: (_user: string, before: string | undefined) => {
        calls.push(before);
        return Promise.resolve({ unreadCount: 0 });
      },
    };
    const c = new NotificationsController(svc as never);
    const req = { principal: { userId: 'u-1' } } as never;
    const res = { setHeader: () => undefined } as never;
    await expect(c.readAll(req, { before: '2026-10-23T10:00:00' }, res)).rejects.toMatchObject({
      code: 'VALIDATION_FAILED',
    });
    expect(calls).toEqual([]);
    await expect(c.readAll(req, { before: '2026-10-23T16:00:00+06:00' }, res)).resolves.toEqual({ unreadCount: 0 });
    expect(calls).toEqual(['2026-10-23T10:00:00.000Z']);
  });
});
