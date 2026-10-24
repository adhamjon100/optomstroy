/**
 * Источник времени для авторизации, лимитов и аудита (подмена в тестах — RM-D-003 п. 3 «тест с подменой Clock»).
 * Время БД (`now()`) остаётся источником для полей, которые выставляет сама БД (DEFAULT now(), триггеры).
 */
export interface Clock {
  now(): Date;
}

export const CLOCK = Symbol('CLOCK');

export const systemClock: Clock = Object.freeze({ now: () => new Date() });

/** Управляемые часы для тестов. */
export class FixedClock implements Clock {
  constructor(private current: Date = new Date()) {}

  now(): Date {
    return new Date(this.current.getTime());
  }

  set(at: Date): void {
    this.current = new Date(at.getTime());
  }

  advance(ms: number): void {
    this.current = new Date(this.current.getTime() + ms);
  }
}
