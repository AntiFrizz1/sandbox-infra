#!/usr/bin/env bash
# Разовая настройка sandbox-инфраструктуры на чистом VPS.
# Запускать от root: sudo ./bootstrap.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Sandbox infrastructure bootstrap"

# --- 0. Deploy-пользователь ---
if ! id deploy &>/dev/null; then
    echo "==> Создаю пользователя deploy"
    useradd -m -s /bin/bash deploy
    mkdir -p /home/deploy/.ssh
    chmod 700 /home/deploy/.ssh
    touch /home/deploy/.ssh/authorized_keys
    chmod 600 /home/deploy/.ssh/authorized_keys
    chown -R deploy:deploy /home/deploy/.ssh
    echo "!! Добавь свой публичный SSH-ключ в /home/deploy/.ssh/authorized_keys"
fi

# --- 1. Docker ---
if ! command -v docker &>/dev/null; then
    echo "==> Устанавливаю Docker"
    curl -fsSL https://get.docker.com | sh
fi

if ! docker compose version &>/dev/null; then
    echo "!! Docker Compose plugin не найден. Установи docker-compose-plugin и перезапусти скрипт." >&2
    exit 1
fi

usermod -aG docker deploy

apt-get update -y
apt-get install -y rsync git

if ! command -v node &>/dev/null; then
    echo "==> Устанавливаю Node.js LTS"
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
fi

# --- 2. Структура каталогов ---
mkdir -p /srv/git /srv/apps /srv/sites /srv/state /srv/deploy /srv/caddy
chown -R deploy:deploy /srv/git /srv/apps /srv/sites /srv/state /srv/deploy

# util-linux: нужен для flock, которым сериализуются операции над проектом
apt-get install -y util-linux

# --- 3. Общая docker-сеть ---
docker network inspect sandbox_net &>/dev/null || docker network create sandbox_net

# --- 4. Deploy-хук и хелперы ---
# Копируется весь каталог deploy/, включая lib/ — скрипты подключают
# lib/common.sh относительно собственного расположения.
mkdir -p /srv/deploy/lib
install -m 755 -o deploy -g deploy "$SCRIPT_DIR"/deploy/*.sh /srv/deploy/
install -m 644 -o deploy -g deploy "$SCRIPT_DIR"/deploy/lib/*.sh /srv/deploy/lib/

# --- 4a. Общий конфиг: домен и SSH-хост ---
# Пишется один раз, чтобы new-app.sh печатал реальный домен, а не плейсхолдер.
if [[ ! -f /srv/sandbox.conf ]]; then
    cat > /srv/sandbox.conf <<'EOF'
# Домен sandbox-инфраструктуры. Проекты доступны на <app>.<SANDBOX_DOMAIN>.
SANDBOX_DOMAIN=sandbox.example.com
# Хост для git remote, обычно совпадает с доменом.
SANDBOX_SSH_HOST=sandbox.example.com
EOF
    chown deploy:deploy /srv/sandbox.conf
    echo "!! Впиши свой домен в /srv/sandbox.conf"
fi

# --- 5. Caddy ---
# Существующая конфигурация не перезаписывается: в ней уже вписан домен.
# Для обновления есть отдельный скрипт, который переносит домен и email
# в новый шаблон и проверяет результат перед применением.
if [[ -f /srv/caddy/Caddyfile ]]; then
    echo "!! /srv/caddy/Caddyfile уже существует — не трогаю его."
    echo "   Обновить конфигурацию: ./update-infra.sh --caddy-only"
else
    cp "$SCRIPT_DIR/caddy/Caddyfile" /srv/caddy/Caddyfile
fi

if [[ -f /srv/caddy/docker-compose.yml ]]; then
    echo "!! /srv/caddy/docker-compose.yml уже существует — не трогаю его."
else
    cp "$SCRIPT_DIR/caddy/docker-compose.yml" /srv/caddy/docker-compose.yml
fi

# Пер-проектные SPA-правила. Каталог должен существовать до старта Caddy:
# import с несовпавшим glob — это предупреждение, а не ошибка, но
# отсутствующий каталог сломал бы bind-mount.
mkdir -p /srv/caddy/spa.d
chown deploy:deploy /srv/caddy/spa.d

if [[ ! -f /srv/caddy/.env ]]; then
    cp "$SCRIPT_DIR/caddy/.env.example" /srv/caddy/.env
    echo "!! Отредактируй /srv/caddy/.env — впиши TIMEWEB_API_TOKEN"
fi

echo "==> Собираю кастомный образ Caddy (timeweb + docker-proxy)"
docker build -t sandbox-caddy:latest "$SCRIPT_DIR/caddy"

echo "==> Запускаю Caddy"
cd /srv/caddy
docker compose up -d

cat <<'EOF'

==> Готово.

Дальше нужно вручную:
  1. В /srv/caddy/Caddyfile и /srv/sandbox.conf заменить sandbox.example.com
     на свой домен.
  2. В /srv/caddy/.env вписать TIMEWEB_API_TOKEN.
  3. Перезапустить Caddy: cd /srv/caddy && docker compose up -d --force-recreate
  4. Добавить DNS A-записи в панели Timeweb:
       *.sandbox.<домен>  -> IP этого VPS  (wildcard)
       sandbox.<домен>    -> IP этого VPS  (apex, отдельной записью)
  5. Добавить свой публичный SSH-ключ в /home/deploy/.ssh/authorized_keys.

Создать первый проект:
  /srv/deploy/new-app.sh myapp
EOF
