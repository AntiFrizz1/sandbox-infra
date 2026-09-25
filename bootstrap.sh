#!/usr/bin/env bash
# Разовая настройка sandbox-инфраструктуры на чистом VPS.
# Запускать от root: sudo ./bootstrap.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# A release is built/scanned once elsewhere; never rebuilt on the VPS.
[[ ${SANDBOX_CADDY_IMAGE:-} =~ ^[^[:space:]]+@sha256:[a-f0-9]{64}$ ]] || {
    echo 'Set SANDBOX_CADDY_IMAGE to the approved release digest (see docs/SECURITY-RUNBOOK.md)' >&2
    exit 1
}
export SANDBOX_CADDY_IMAGE
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
    apt-get update
    apt-get install -y docker.io docker-compose-v2
fi

if ! docker compose version &>/dev/null; then
    echo "!! Docker Compose plugin не найден. Установи docker-compose-plugin и перезапусти скрипт." >&2
    exit 1
fi

usermod -aG docker deploy

apt-get update -y
apt-get install -y rsync git

# --- 2. Структура каталогов ---
mkdir -p /srv/git /srv/apps /srv/sites /srv/state /srv/deploy /srv/caddy
chown -R deploy:deploy /srv/git /srv/apps /srv/sites /srv/state

# util-linux: нужен для flock, которым сериализуются операции над проектом
apt-get install -y util-linux

install -d -m 755 -o root -g root /etc/sandbox /etc/sandbox/projects

# --- 3. Общая docker-сеть ---
docker network inspect sandbox_net &>/dev/null || docker network create sandbox_net

# --- 4. Deploy-хук и хелперы ---
# Копируется весь каталог deploy/, включая lib/ — скрипты подключают
# lib/common.sh относительно собственного расположения.
mkdir -p /srv/deploy/lib
install -m 755 -o root -g root "$SCRIPT_DIR"/deploy/*.sh /srv/deploy/
install -m 644 -o root -g root "$SCRIPT_DIR"/deploy/lib/*.sh /srv/deploy/lib/

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
mkdir -p /srv/caddy/config
if [[ -f /srv/caddy/config/Caddyfile ]]; then
    echo "!! /srv/caddy/Caddyfile уже существует — не трогаю его."
    echo "   Обновить конфигурацию: ./update-infra.sh --caddy-only"
else
    cp "$SCRIPT_DIR/caddy/Caddyfile" /srv/caddy/config/Caddyfile
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
    [[ ! -L /srv/caddy/.env ]] || { echo "unsafe Caddy env symlink" >&2; exit 1; }
    install -m 640 -o root -g deploy "$SCRIPT_DIR/caddy/.env.example" /srv/caddy/.env
    echo "!! Отредактируй /srv/caddy/.env — впиши TIMEWEB_API_TOKEN"
fi

# deploy drives Compose from hooks, and Compose must read .env. deploy is in
# the docker group and can read the token via docker inspect anyway;
# the mode keeps it from every other UID.
[[ ! -L /srv/caddy/.env ]] || exit 1
chown root:deploy /srv/caddy/.env
chmod 640 /srv/caddy/.env

echo "==> Получаю утверждённый образ Caddy"
docker pull "$SANDBOX_CADDY_IMAGE"
printf 'SANDBOX_CADDY_IMAGE=%s\n' "$SANDBOX_CADDY_IMAGE" >> /srv/caddy/.env

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
