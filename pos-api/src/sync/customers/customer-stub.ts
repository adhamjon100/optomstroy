/**
 * Строка-заглушка реплики клиента 1С (ревью G-customers-1c-2): `source = onec`, ещё не прочитанная синхронизацией
 * (`synced_at IS NULL`, `onec_status = n_a`) и ни на что не ссылающаяся. Такую строку создаёт `CustomerMatching`
 * (поиск дубля по телефону, RM-D-005) для кандидата из ответа 1С. Если Ref заглушки оказался Ref карточки, которую
 * 1С создала по `customer/create` POS-клиента (окно «доставлено, результат не обработан»), заглушка удаляется и
 * Ref переходит к POS-строке (05 SYNC-005: сопоставление только по `externalId`, без дублей клиентов).
 *
 * Условие дописывается к `DELETE FROM customers s WHERE s.id = <id>` (все 10 FK на `customers` — RESTRICT).
 */
export const UNREFERENCED_STUB_GUARD = `
  AND s.source = 'onec' AND s.synced_at IS NULL AND s.onec_status = 'n_a'
  AND NOT EXISTS (SELECT 1 FROM customer_contacts x WHERE x.customer_id = s.id)
  AND NOT EXISTS (SELECT 1 FROM customer_links x WHERE x.customer_id = s.id)
  AND NOT EXISTS (SELECT 1 FROM receivables x WHERE x.customer_id = s.id)
  AND NOT EXISTS (SELECT 1 FROM carts x WHERE x.customer_id = s.id)
  AND NOT EXISTS (SELECT 1 FROM orders x WHERE x.customer_id = s.id)
  AND NOT EXISTS (SELECT 1 FROM payments x WHERE x.customer_id = s.id)
  AND NOT EXISTS (SELECT 1 FROM shipments x WHERE x.customer_id = s.id)
  AND NOT EXISTS (SELECT 1 FROM return_requests x WHERE x.customer_id = s.id)
  AND NOT EXISTS (SELECT 1 FROM transactions x WHERE x.customer_id = s.id)
  AND NOT EXISTS (SELECT 1 FROM favorites_customers x WHERE x.customer_id = s.id)`;
