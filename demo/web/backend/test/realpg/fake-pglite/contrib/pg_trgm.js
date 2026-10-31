// Эталон на PostgreSQL: расширение pg_trgm есть на сервере (CREATE EXTENSION в миграциях) — здесь только имя.
export const pg_trgm = { name: 'pg_trgm', realPostgres: true };
