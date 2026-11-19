#!/usr/bin/env bash
# Пошаговый показ демо pgcrypto: для выступления и записи видео.
# Каждый шаг очищает экран, печатает заголовок и запрос, выполняет его.
#
#   ./scripts/walkthrough.sh          переход к следующему шагу по Enter (живой показ)
#   AUTO=6 ./scripts/walkthrough.sh   шаги идут сами с паузой 6 секунд (запись видео)
#
# Вариант с Docker:
#   PSQL="docker compose exec -T db psql" SQLFILE=/sql/demo.sql ./scripts/walkthrough.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PSQL=${PSQL:-psql}
SQLFILE=${SQLFILE:-sql/demo.sql}
LOG=${LOG:-$HOME/pgcrypto-demo/server.log}
export PGUSER=${PGUSER:-demo} PGDATABASE=${PGDATABASE:-demo}

ENC_KEY='demo-encryption-key-change-me'
HMAC_KEY='demo-search-key-change-me'

pause() {
    if [ -n "${AUTO:-}" ]; then
        sleep "$AUTO"
    else
        read -r -p $'\n\033[2m[Enter — дальше]\033[0m ' _
    fi
}

step() {
    clear 2>/dev/null || true
    printf '\033[1;36m%s\033[0m\n\n' "$1"
}

run_sql() {
    printf '\033[33mdemo=# %s\033[0m\n' "$1"
    $PSQL -X -q -P pager=off -U "$PGUSER" -d "$PGDATABASE" -c "$1" 2>&1 || true
}

# Подготовка: создать таблицы и данные (вывод скрыт)
$PSQL -X -q -U "$PGUSER" -d "$PGDATABASE" -f "$SQLFILE" >/dev/null 2>&1 || true

step "pgcrypto: шифрование данных в PostgreSQL"
printf 'Солдатов Сергей Юрьевич, ПИ4-1\nДисциплина «Администрирование баз данных», тема №12\n'
pause

step "1. Расширение входит в стандартную поставку PostgreSQL"
run_sql "SELECT extname, extversion FROM pg_extension WHERE extname = 'pgcrypto';"
pause

step "2. Пароли: одинаковый пароль 'qwerty123' — разные хеши (bcrypt + соль)"
run_sql "SELECT login, password_hash FROM users;"
pause

step "3. Проверка пароля при входе: сам пароль нигде не хранится"
run_sql "SELECT login, password_hash = crypt('qwerty123', password_hash) AS correct, password_hash = crypt('qwerty124', password_hash) AS wrong FROM users;"
pause

step "4. Паспорт в таблице: без ключа — нечитаемые байты"
run_sql "SELECT id, full_name, left(encode(passport, 'hex'), 32) || '…' AS passport_on_disk FROM customers;"
pause

step "5. С правильным ключом данные расшифровываются"
run_sql "SELECT id, full_name, pgp_sym_decrypt(passport, '$ENC_KEY') AS passport FROM customers;"
pause

step "6. Поиск по зашифрованному полю — через HMAC («слепой индекс»)"
run_sql "SELECT id, full_name, pgp_sym_decrypt(passport, '$ENC_KEY') AS passport FROM customers WHERE passport_hmac = hmac('4510 123456', '$HMAC_KEY', 'sha256');"
pause

step "7. Неверный ключ — расшифровать нельзя"
run_sql "SELECT pgp_sym_decrypt(passport, 'wrong-key') FROM customers WHERE id = 1;"
pause

step "8. Главный риск: ключ виден в журнале сервера (log_statement = all)"
if [ -f "$LOG" ]; then
    printf '\033[33m$ grep -A1 "statement: INSERT INTO customers" %s | tail -n 2\033[0m\n' "$LOG"
    grep -A1 'statement: INSERT INTO customers' "$LOG" | tail -n 2 | cut -c1-170
else
    printf '\033[33m$ docker compose logs db | grep -A1 "statement: INSERT INTO customers" | tail -n 2\033[0m\n'
    docker compose logs db | grep -A1 'statement: INSERT INTO customers' | tail -n 2 | cut -c1-170
fi
pause

step "Итог"
printf '%s\n' \
    "• пароли — crypt() + gen_salt('bf'): необратимо, с солью и настраиваемой стоимостью" \
    '• персональные данные — pgp_sym_encrypt(): AES-256, расшифровка только с ключом' \
    '• поиск — по HMAC, только точное совпадение' \
    '• ключ проходит через сервер: нужен TLS, ключ хранить вне БД, следить за журналами'
