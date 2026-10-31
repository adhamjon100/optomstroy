// Шаги данных холодного старта эпохи, общие для сборки снимка (snapshot/builder-entry.mjs, Node) и воркера
// (demo-init.mjs, запасной путь без снимка). Модуль без импортов: client — любой объект с query(text, values)
// (pg-shim Client/Pool). Состав данных — demo-config.mjs.

/**
 * Сотрудники стенда и служебные учётки сида (как insertAuthFixtures/insertCashierFixtures local-stack): пользователь,
 * профиль (ФИО) и роль. Уже существующий номер не трогается. Возвращает число созданных.
 */
export async function ensureUsers(client, list, { status = 'active' } = {}) {
  let created = 0;
  for (const u of list) {
    const ex = await client.query(`SELECT id FROM users WHERE phone_e164 = $1 AND deleted_at IS NULL`, [u.phone]);
    if (ex.rows[0]) continue;
    const r = await client.query(`INSERT INTO users (phone_e164, phone_verified_at, kind, status) VALUES ($1, now(), 'staff', $2) RETURNING id`, [u.phone, status]);
    await client.query(`INSERT INTO user_profiles (user_id, full_name) VALUES ($1, $2)`, [r.rows[0].id, u.name]);
    await client.query(`INSERT INTO user_roles (user_id, role_id) SELECT $1, id FROM roles WHERE code = $2`, [r.rows[0].id, u.role]);
    created++;
  }
  return created;
}
