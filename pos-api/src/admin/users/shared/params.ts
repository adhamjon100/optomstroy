import { isUuid } from '../../../common/ids/uuid.js';
import { ProblemException } from '../../../common/problem-details/problem.exception.js';

/** Параметр пути `{id}` (схема `IdPath`, UUID): не UUID → `400 VALIDATION_FAILED rule uuid` (08 §2.14). */
export function uuidParam(value: string | undefined, field = 'id'): string {
  if (!isUuid(value)) {
    throw new ProblemException('VALIDATION_FAILED', {
      status: 400,
      detail: 'Идентификатор — UUID.',
      errors: [{ field, rule: 'uuid', message: 'Идентификатор — UUID.' }],
    });
  }
  return value.toLowerCase();
}
