-- Демонстрация pgcrypto.
-- Запуск: docker compose exec db psql -U demo -d demo -e -f /sql/demo.sql
-- Скрипт можно запускать повторно: таблицы пересоздаются.

\pset pager off

-- Ключи задаются переменными psql, чтобы не повторять их в каждом запросе.
-- В реальной системе ключ приходит из приложения (переменная окружения, Vault), а не хранится в БД.
\set enc_key 'demo-encryption-key-change-me'
\set hmac_key 'demo-search-key-change-me'

\echo
\echo '=== 0. Подключаем расширение'
CREATE EXTENSION IF NOT EXISTS pgcrypto;
SELECT extname, extversion FROM pg_extension WHERE extname = 'pgcrypto';

\echo
\echo '=== 1. Случайные значения: UUID и криптостойкие байты'
SELECT gen_random_uuid()                       AS uuid,
       encode(gen_random_bytes(16), 'hex')     AS random_16_bytes;

\echo
\echo '=== 2. Хеширование: одинаковый вход → одинаковый хеш, расшифровать нельзя'
SELECT encode(digest('Привет', 'sha256'), 'hex') AS sha256_1,
       encode(digest('Привет', 'sha256'), 'hex') AS sha256_2,
       encode(digest('привет', 'sha256'), 'hex') AS sha256_lowercase;

\echo 'HMAC — хеш с секретным ключом: без ключа такой же хеш не получить'
SELECT encode(hmac('Привет', :'hmac_key', 'sha256'), 'hex') AS hmac_sha256;

\echo
\echo '=== 3. Хранение паролей: crypt() + gen_salt(''bf'') (bcrypt)'
DROP TABLE IF EXISTS users;
CREATE TABLE users
(
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    login         text UNIQUE NOT NULL,
    password_hash text NOT NULL
);

-- У двух пользователей одинаковый пароль, но хеши разные: у каждого своя случайная соль
INSERT INTO users (login, password_hash) VALUES
    ('ivanov', crypt('qwerty123', gen_salt('bf', 10))),
    ('petrov', crypt('qwerty123', gen_salt('bf', 10)));

SELECT login, password_hash FROM users;

\echo 'Проверка пароля при входе: соль и стоимость берутся из сохранённого хеша'
SELECT login,
       password_hash = crypt('qwerty123', password_hash) AS correct_password,
       password_hash = crypt('qwerty124', password_hash) AS wrong_password
FROM users;

\echo 'Стоимость bcrypt: каждый +1 к параметру удваивает время перебора'
\timing on
SELECT crypt('qwerty123', gen_salt('bf', 6))  AS cost_6;
SELECT crypt('qwerty123', gen_salt('bf', 12)) AS cost_12;
\timing off

\echo
\echo '=== 4. Шифрование персональных данных: pgp_sym_encrypt / pgp_sym_decrypt'
DROP TABLE IF EXISTS customers;
CREATE TABLE customers
(
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name     text  NOT NULL,
    passport      bytea NOT NULL,   -- зашифрованный номер паспорта
    passport_hmac bytea NOT NULL    -- «слепой индекс» для поиска по точному совпадению
);
CREATE INDEX customers_passport_hmac_idx ON customers (passport_hmac);

INSERT INTO customers (full_name, passport, passport_hmac) VALUES
    ('Иванов Иван',   pgp_sym_encrypt('4510 123456', :'enc_key', 'cipher-algo=aes256'), hmac('4510 123456', :'hmac_key', 'sha256')),
    ('Петрова Мария', pgp_sym_encrypt('4512 654321', :'enc_key', 'cipher-algo=aes256'), hmac('4512 654321', :'hmac_key', 'sha256')),
    ('Сидоров Пётр',  pgp_sym_encrypt('4510 123456', :'enc_key', 'cipher-algo=aes256'), hmac('4510 123456', :'hmac_key', 'sha256'));

\echo 'Так данные лежат в таблице: без ключа это нечитаемые байты'
SELECT id, full_name, left(encode(passport, 'hex'), 40) || '…' AS passport_on_disk, length(passport) AS bytes
FROM customers;

\echo 'Один и тот же паспорт (id 1 и 3) зашифрован по-разному: в шифр подмешивается случайная соль'
SELECT a.passport = b.passport AS ciphertexts_equal
FROM customers a, customers b
WHERE a.id = 1 AND b.id = 3;

\echo 'С правильным ключом данные расшифровываются'
SELECT id, full_name, pgp_sym_decrypt(passport, :'enc_key') AS passport
FROM customers;

\echo 'Поиск по паспорту: по шифротексту искать нельзя, ищем по HMAC'
SELECT id, full_name, pgp_sym_decrypt(passport, :'enc_key') AS passport
FROM customers
WHERE passport_hmac = hmac('4510 123456', :'hmac_key', 'sha256');

\echo 'Неверный ключ → ошибка (ожидаемо)'
SELECT pgp_sym_decrypt(passport, 'wrong-key') FROM customers WHERE id = 1;

\echo
\echo '=== 5. Ключ виден серверу: он передаётся в тексте запроса'
\echo 'Ключ из раздела 4 записан в журнал сервера открытым текстом (нужен log_statement = all). Проверьте:'
\echo '    Docker:          docker compose logs db | grep pgp_sym_encrypt'
\echo '    Без Docker:      grep pgp_sym_encrypt ~/pgcrypto-demo/server.log'
