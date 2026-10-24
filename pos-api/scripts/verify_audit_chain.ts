/**
 * Проверка хэш-цепочки журнала аудита по всей таблице и сверка якорей `audit_anchors` (07 §9.3; 11 SEC-080,
 * SEC-081; RM-G-006 п. 1–2). Только чтение. Запуск из pos-api/:
 *
 *   DATABASE_URL_FILE=/run/secrets/database_url npx tsx scripts/verify_audit_chain.ts [--json]
 *   DATABASE_URL=postgres://… npx tsx scripts/verify_audit_chain.ts            # dev
 *
 * В образе pos-api — тот же код из `dist/` (`src/admin/audit/audit-chain.verifier.ts`). Код выхода: 0 — цепочка и
 * якоря целы; 1 — разрыв (сообщается относительно последнего целого якоря); 2 — ошибка аргументов/подключения.
 */
import { runVerifyAuditChainCli } from '../src/admin/audit/audit-chain.verifier.js';

process.exitCode = await runVerifyAuditChainCli(process.argv.slice(2), process.env);
