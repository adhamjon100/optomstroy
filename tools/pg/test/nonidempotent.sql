CREATE TABLE IF NOT EXISTS log_t (id serial PRIMARY KEY, msg text);
INSERT INTO log_t (msg) VALUES ('run');
