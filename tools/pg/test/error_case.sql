CREATE TABLE err_t (id int PRIMARY KEY);

-- следующая команда содержит ошибку на строке 4
SELECT id, no_such_column
  FROM err_t;
CREATE TABLE never_created (id int);
