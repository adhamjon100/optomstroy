// Эталон на PostgreSQL: расширение pgcrypto есть на сервере (CREATE EXTENSION в миграциях) — здесь только имя.
export const pgcrypto = { name: 'pgcrypto', realPostgres: true };
