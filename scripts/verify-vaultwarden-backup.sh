#!/usr/bin/env bash

set -Eeuo pipefail

readonly TEST_CONTAINER="vaultwarden-restore-test"
readonly TEST_PORT="${VAULTWARDEN_TEST_PORT:-18080}"
readonly TEST_IMAGE="${VAULTWARDEN_TEST_IMAGE:-vaultwarden/server:1.35.2}"
readonly TEST_ROOT="${VAULTWARDEN_TEST_ROOT:-$HOME/vaultwarden-restore-test}"
readonly TEST_DATA="$TEST_ROOT/vaultwarden"
readonly TLS_DIR="$TEST_ROOT/tls"

log() {
    printf '\n%s\n' "$*"
}

fail() {
    printf '\nОшибка: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Использование:
  ./verify-vaultwarden-backup.sh /путь/к/vaultwarden-backup.tar.gz

Если путь не указан, скрипт ищет самый свежий vaultwarden-*.tar.gz:
  1. в текущем каталоге;
  2. в домашнем каталоге;
  3. в $HOME/backups/vaultwarden.

Переменные:
  VAULTWARDEN_TEST_PORT   локальный HTTPS-порт, по умолчанию 18080
  VAULTWARDEN_TEST_IMAGE  образ, по умолчанию vaultwarden/server:1.35.2
  VAULTWARDEN_TEST_ROOT   тестовый каталог, по умолчанию
                          $HOME/vaultwarden-restore-test
EOF
}

find_archive() {
    local candidate
    candidate="$({
        local search_dir
        for search_dir in "$PWD" "$HOME" "$HOME/backups/vaultwarden"; do
            if [[ -d "$search_dir" ]]; then
                find "$search_dir" -maxdepth 1 -type f -name 'vaultwarden-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null
            fi
        done
        true
    } | sort -nr | head -n 1 | cut -d' ' -f2-)"

    printf '%s' "$candidate"
}

install_dependencies() {
    local packages=()

    command -v sqlite3 >/dev/null 2>&1 || packages+=(sqlite3)
    command -v mkcert >/dev/null 2>&1 || packages+=(mkcert)
    command -v certutil >/dev/null 2>&1 || packages+=(libnss3-tools)

    if ((${#packages[@]} > 0)); then
        command -v apt-get >/dev/null 2>&1 || \
            fail "Не найдены ${packages[*]}, а apt-get недоступен. Установите зависимости вручную."

        log "Устанавливаю зависимости: ${packages[*]}"
        sudo apt-get update
        sudo apt-get install -y "${packages[@]}"
    fi
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if (($# > 1)); then
    usage >&2
    exit 2
fi

ARCHIVE="${1:-}"
if [[ -z "$ARCHIVE" ]]; then
    ARCHIVE="$(find_archive)"
fi

[[ -n "$ARCHIVE" ]] || fail "Архив vaultwarden-*.tar.gz не найден. Передайте путь первым аргументом."
ARCHIVE="$(realpath "$ARCHIVE")"
[[ -f "$ARCHIVE" ]] || fail "Файл не найден: $ARCHIVE"
[[ -r "$ARCHIVE" ]] || fail "Нет доступа на чтение: $ARCHIVE"

command -v docker >/dev/null 2>&1 || \
    fail "Docker не установлен. Сначала установите и запустите Docker."
docker info >/dev/null 2>&1 || \
    fail "Docker недоступен. Запустите Docker или выполните скрипт от пользователя с доступом к нему."
command -v tar >/dev/null 2>&1 || fail "Не найдена команда tar."
command -v curl >/dev/null 2>&1 || fail "Не найдена команда curl."

case "$TEST_ROOT" in
    "" | / | "$HOME")
        fail "Небезопасное значение VAULTWARDEN_TEST_ROOT: $TEST_ROOT"
        ;;
esac

if docker container inspect "$TEST_CONTAINER" >/dev/null 2>&1 || [[ -e "$TEST_ROOT" ]]; then
    printf '\nНайдено старое тестовое окружение:\n'
    docker ps -a --filter "name=^/${TEST_CONTAINER}$" --format '  Контейнер: {{.Names}} ({{.Status}})' || true
    [[ -e "$TEST_ROOT" ]] && printf '  Каталог: %s\n' "$TEST_ROOT"
    printf 'Удалить его и продолжить? [y/N]: '
    read -r replace_answer

    if [[ ! "$replace_answer" =~ ^[yYдД]$ ]]; then
        fail "Запуск отменён. Старое тестовое окружение не изменялось."
    fi

    if docker container inspect "$TEST_CONTAINER" >/dev/null 2>&1; then
        docker rm -f "$TEST_CONTAINER" >/dev/null
    fi
    if [[ -e "$TEST_ROOT" ]]; then
        rm -r -- "$TEST_ROOT"
    fi
fi

if ss -ltn "sport = :$TEST_PORT" 2>/dev/null | grep -q LISTEN; then
    fail "Порт $TEST_PORT уже занят. Запустите с другим портом, например: VAULTWARDEN_TEST_PORT=18081 $0 '$ARCHIVE'"
fi

log "Архив: $ARCHIVE"
sha256sum "$ARCHIVE"

log "Проверяю структуру архива"
tar -tzf "$ARCHIVE" >/dev/null
if tar -tzf "$ARCHIVE" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
    fail "Архив содержит небезопасные пути. Распаковка отменена."
fi

mkdir -p "$TEST_ROOT"
tar --no-same-owner -xzf "$ARCHIVE" -C "$TEST_ROOT"

[[ -f "$TEST_DATA/db.sqlite3" ]] || \
    fail "В архиве не найден vaultwarden/db.sqlite3."
[[ -f "$TEST_DATA/rsa_key.pem" ]] || \
    fail "В архиве не найден vaultwarden/rsa_key.pem."

if [[ -f "$TEST_DATA/config.json" ]]; then
    mv "$TEST_DATA/config.json" "$TEST_DATA/config.json.production"
fi

install_dependencies

log "Проверяю целостность SQLite"
integrity_result="$(sqlite3 "$TEST_DATA/db.sqlite3" 'PRAGMA integrity_check;')"
[[ "$integrity_result" == "ok" ]] || \
    fail "SQLite integrity_check завершился с ошибкой: $integrity_result"
printf 'SQLite: ok\n'

foreign_key_errors="$(sqlite3 "$TEST_DATA/db.sqlite3" 'PRAGMA foreign_key_check;')"
[[ -z "$foreign_key_errors" ]] || \
    fail "SQLite foreign_key_check нашёл ошибки: $foreign_key_errors"
printf 'Внешние ключи: ok\n'

users_count="$(sqlite3 "$TEST_DATA/db.sqlite3" 'SELECT COUNT(*) FROM users;' 2>/dev/null || printf '?')"
ciphers_count="$(sqlite3 "$TEST_DATA/db.sqlite3" 'SELECT COUNT(*) FROM ciphers;' 2>/dev/null || printf '?')"
printf 'Пользователей: %s\nЗаписей: %s\n' "$users_count" "$ciphers_count"

log "Создаю доверенный сертификат для localhost"
mkdir -p "$TLS_DIR"
mkcert -install
mkcert \
    -cert-file "$TLS_DIR/cert.pem" \
    -key-file "$TLS_DIR/key.pem" \
    localhost 127.0.0.1 ::1
chmod 600 "$TLS_DIR/key.pem"

log "Загружаю образ $TEST_IMAGE"
docker pull "$TEST_IMAGE"

log "Запускаю восстановленный Vaultwarden"
docker run -d \
    --name "$TEST_CONTAINER" \
    --restart=no \
    -p "127.0.0.1:$TEST_PORT:80" \
    -v "$TEST_DATA:/data" \
    -v "$TLS_DIR:/ssl:ro" \
    -e "DOMAIN=https://localhost:$TEST_PORT" \
    -e SIGNUPS_ALLOWED=false \
    -e INVITATIONS_ALLOWED=false \
    -e 'ROCKET_TLS={certs="/ssl/cert.pem",key="/ssl/key.pem"}' \
    "$TEST_IMAGE" >/dev/null

log "Ожидаю готовности сервиса"
ready="false"
for _ in $(seq 1 30); do
    running="$(docker inspect -f '{{.State.Running}}' "$TEST_CONTAINER" 2>/dev/null || printf false)"
    if [[ "$running" != "true" ]]; then
        docker logs --tail=100 "$TEST_CONTAINER" >&2 || true
        fail "Контейнер остановился во время запуска."
    fi

    if curl -kfsS "https://localhost:$TEST_PORT/alive" >/dev/null 2>&1; then
        ready="true"
        break
    fi

    sleep 2
done

if [[ "$ready" != "true" ]]; then
    docker logs --tail=100 "$TEST_CONTAINER" >&2 || true
    fail "HTTPS endpoint Vaultwarden не ответил за 60 секунд."
fi

version="$(docker exec "$TEST_CONTAINER" /vaultwarden --version 2>/dev/null || true)"
health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}не настроен{{end}}' "$TEST_CONTAINER")"

cat <<EOF

Vaultwarden успешно восстановлен и запущен.

Открыть в браузере:
  https://localhost:$TEST_PORT

Версия:
  ${version:-$TEST_IMAGE}

Docker healthcheck:
  $health

Тестовые данные:
  $TEST_DATA

Проверить логи:
  docker logs --tail=100 $TEST_CONTAINER

Остановить и удалить тестовый контейнер:
  docker rm -f $TEST_CONTAINER

После проверки тестовый каталог можно удалить отдельно:
  rm -r -- '$TEST_ROOT'

Исходный архив не изменялся:
  $ARCHIVE
EOF
