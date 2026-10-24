import { HttpException } from '@nestjs/common';

/**
 * Сигнал «отдать сохранённый ответ как есть» (08 §2.7). Используется исключение, а не возврат значения, чтобы
 * Nest не подменил сохранённый статус статусом маршрута по умолчанию; обрабатывает ProblemDetailsFilter.
 */
export class ReplayedResponseException extends HttpException {
  constructor(
    readonly replayStatus: number,
    readonly replayBody: unknown,
  ) {
    super('replayed', replayStatus);
  }

  /** Сохранённое тело — problem+json (ответ-ошибка 4xx). */
  get isProblem(): boolean {
    return (
      this.replayStatus >= 400 &&
      typeof this.replayBody === 'object' &&
      this.replayBody !== null &&
      'code' in this.replayBody
    );
  }
}
