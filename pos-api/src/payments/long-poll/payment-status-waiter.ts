import { EventEmitter } from 'node:events';
import { Inject, Injectable, Logger, type OnModuleDestroy } from '@nestjs/common';
import type pg from 'pg';
import { CLOCK, type Clock } from '../../common/auth/clock.js';
import { PG_POOL } from '../../common/db/database.module.js';
import { ProblemException } from '../../common/problem-details/problem.exception.js';

/** Канал `pg_notify` триггера `trg_payments_notify_status` (migrations/0011_payments.sql). */
export const PAYMENTS_STATUS_CHANNEL = 'payments_status';
/** Предел `?wait=` (08 §4.9.2, ядро §17.4). */
export const MAX_WAIT_SECONDS = 25;
/** Шаг проверки срока ожидания по `Clock` (подменяемые часы в тестах) и признака отключения клиента. */
const TICK_MS = 200;
/** Страховочное перечитывание статуса из БД (если LISTEN-соединение потеряно). */
const RECHECK_EVERY_TICKS = 10;
/**
 * Пределы одновременных ожиданий (11 §2.2 STRIDE D; ревью F-security-4): на пользователя и на процесс. Сверх
 * предела запрос отвечает сразу текущим статусом (без удержания соединения и опроса БД).
 */
export const MAX_WAITS_PER_USER = 3;
export const MAX_WAITS_PER_PROCESS = 200;

/**
 * Long-polling `GET /payments/{id}?wait=N` (08 API-088; ядро §17.4; Q-167): ответ — сразу после смены статуса
 * (в т. ч. выполненной другим процессом или с другого устройства: `LISTEN payments_status`, уведомление приходит
 * после COMMIT) или по истечении `N` секунд по `Clock`. Не более одного ожидающего запроса на пару «платёж,
 * пользователь» в процессе: второй → `429 RATE_LIMITED` (`Retry-After`); слот освобождается по завершении и при
 * отключении клиента.
 */
@Injectable()
export class PaymentStatusWaiter implements OnModuleDestroy {
  private readonly logger = new Logger('payments.wait');
  private readonly events = new EventEmitter();
  private readonly slots = new Set<string>();
  private readonly perUser = new Map<string, number>();
  private client: pg.PoolClient | undefined;
  private connecting: Promise<void> | undefined;
  private closed = false;

  constructor(
    @Inject(PG_POOL) private readonly pool: pg.Pool,
    @Inject(CLOCK) private readonly clock: Clock,
  ) {
    this.events.setMaxListeners(0);
  }

  /**
   * Занять слот ожидания; тот же платёж уже ожидается этим пользователем → `429 RATE_LIMITED`. Превышен предел
   * одновременных ожиданий пользователя или процесса → `null` (ответить сразу, без ожидания). Иначе — функция
   * освобождения слота.
   */
  acquire(paymentId: string, userId: string, waitSeconds: number): (() => void) | null {
    const key = `${paymentId}:${userId}`;
    if (this.slots.has(key)) {
      throw new ProblemException('RATE_LIMITED', {
        detail: 'Уже есть ожидающий запрос статуса этого платежа.',
        retryAfter: waitSeconds,
        headers: { 'Retry-After': String(waitSeconds) },
        reason: 'wait_in_progress',
      });
    }
    const mine = this.perUser.get(userId) ?? 0;
    if (mine >= MAX_WAITS_PER_USER || this.slots.size >= MAX_WAITS_PER_PROCESS) {
      this.logger.warn({ paymentId, userId, mine, total: this.slots.size }, 'payments.wait.limit_reached');
      return null;
    }
    this.slots.add(key);
    this.perUser.set(userId, mine + 1);
    let released = false;
    return () => {
      if (released) return;
      released = true;
      this.slots.delete(key);
      const n = (this.perUser.get(userId) ?? 1) - 1;
      if (n <= 0) this.perUser.delete(userId);
      else this.perUser.set(userId, n);
    };
  }

  /**
   * Ждать смены статуса платежа относительно `current` до `deadline` (по `Clock`) или до `signal`. `readStatus`
   * перечитывает статус (по уведомлению и страховочно раз в ~2 с).
   */
  async waitForChange(
    paymentId: string,
    current: string,
    deadline: Date,
    signal: AbortSignal,
    readStatus: () => Promise<string | null>,
  ): Promise<void> {
    await this.listen().catch((err: unknown) => this.logger.warn({ err }, 'payments.wait.listen_failed'));
    let notified = false;
    const onNotify = () => {
      notified = true;
    };
    this.events.on(paymentId, onNotify);
    try {
      let ticks = 0;
      for (;;) {
        if (signal.aborted || this.closed) return;
        if (this.clock.now().getTime() >= deadline.getTime()) return;
        ticks += 1;
        if (notified || ticks % RECHECK_EVERY_TICKS === 0) {
          notified = false;
          const st = await readStatus();
          if (st === null || st !== current) return;
        }
        await this.sleep(TICK_MS, paymentId);
      }
    } finally {
      this.events.off(paymentId, onNotify);
    }
  }

  async onModuleDestroy(): Promise<void> {
    this.closed = true;
    this.events.emit('__close__');
    const c = this.client;
    this.client = undefined;
    if (c) {
      await c.query(`UNLISTEN ${PAYMENTS_STATUS_CHANNEL}`).catch(() => undefined);
      c.release();
    }
  }

  private sleep(ms: number, paymentId: string): Promise<void> {
    return new Promise((resolve) => {
      const done = () => {
        clearTimeout(t);
        this.events.off(paymentId, done);
        this.events.off('__close__', done);
        resolve();
      };
      const t = setTimeout(done, ms);
      this.events.once(paymentId, done);
      this.events.once('__close__', done);
    });
  }

  private listen(): Promise<void> {
    if (this.client || this.closed) return Promise.resolve();
    this.connecting ??= (async () => {
      const c = await this.pool.connect();
      c.on('notification', (msg) => {
        if (msg.channel === PAYMENTS_STATUS_CHANNEL && msg.payload) this.events.emit(msg.payload);
      });
      c.on('error', (err) => {
        this.logger.warn({ err }, 'payments.wait.listen_connection_error');
        if (this.client === c) this.client = undefined;
        c.release(err);
      });
      await c.query(`LISTEN ${PAYMENTS_STATUS_CHANNEL}`);
      this.client = c;
    })().finally(() => {
      this.connecting = undefined;
    });
    return this.connecting;
  }
}
