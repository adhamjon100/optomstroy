import type { PosDatabase } from '../../db/database.js';

/**
 * Исполнитель запросов Drizzle: клиент `DRIZZLE` (common/db) или транзакция `db.transaction(async (tx) => …)`.
 * Сервисы фундамента (аудит, лимиты, репозитории users) принимают его параметром, чтобы запись шла в
 * транзакции бизнес-операции (11 SEC-073: «нет записи аудита — откат операции»).
 */
export type DbTransaction = Parameters<Parameters<PosDatabase['transaction']>[0]>[0];
export type DbExecutor = PosDatabase | DbTransaction;
