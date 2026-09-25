#!/usr/bin/env bash
# Проверки владельцев при миграции от root и сохранения Docker-маршрутов.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"
if ! docker info >/dev/null 2>&1; then
    echo "SKIP Docker недоступен: проверки root-миграции и docker-proxy"
    exit 0
fi

SB=$(make_sandbox)
PROJECT="sandbox-runtime-$$"
export SANDBOX_CADDY_DIR="$SB"
# shellcheck source=deploy/lib/common.sh
source "$ROOT/deploy/lib/common.sh"
# shellcheck source=deploy/lib/caddy.sh
source "$ROOT/deploy/lib/caddy.sh"
cleanup() {
    (cd "$SB" && docker compose -p "$PROJECT" down -v >/dev/null 2>&1)
    rm -rf "$SB"
}
trap cleanup EXIT

docker run --rm -i -v "$ROOT:/repo:ro" debian:bookworm-slim bash -s >"$SB/owners.log" 2>&1 <<'SCRIPT'
set -euo pipefail
apt-get update -qq
apt-get install -y -qq rsync python3 git >/dev/null
export SANDBOX_GIT_ROOT=/tmp/test/git SANDBOX_APPS_ROOT=/tmp/test/apps
export SANDBOX_SITES_ROOT=/tmp/test/sites SANDBOX_STATE_ROOT=/tmp/test/state
export SANDBOX_DEPLOY_OWNER=nobody:nogroup
mkdir -p "$SANDBOX_GIT_ROOT/demo.git" "$SANDBOX_SITES_ROOT/demo" "$SANDBOX_APPS_ROOT/demo"
echo old > "$SANDBOX_SITES_ROOT/demo/index.html"
bash /repo/deploy/migrate.sh state
bash /repo/deploy/migrate.sh sites
# Проверяем именно операции, которые затем понадобятся deploy-хуку.
su -s /bin/bash nobody -c '
set -e
touch /tmp/test/state/demo/logs/new.log
echo ok >> /tmp/test/state/demo/releases.tsv
echo ok >> /tmp/test/state/.locks/demo.lock
mkdir /tmp/test/sites/demo/releases/new
echo safe > /tmp/test/sites/demo/releases/new/index.html
ln -s releases/new /tmp/test/sites/demo/next
mv -T /tmp/test/sites/demo/next /tmp/test/sites/demo/current
'
# A separate UID cannot read state created/repaired by the real helpers.
echo SYNTHETIC > "$SANDBOX_STATE_ROOT/demo/env"
chmod 644 "$SANDBOX_STATE_ROOT/demo/env"
mkdir -p /tmp/test/caddy
echo TIMEWEB_API_TOKEN=SYNTHETIC > /tmp/test/caddy/.env
chmod 644 /tmp/test/caddy/.env
SANDBOX_CADDY_DIR=/tmp/test/caddy bash /repo/deploy/repair-permissions.sh
[[ $(stat -c %a "$SANDBOX_STATE_ROOT/demo/env") == 600 ]]
# Compose run by deploy reads the Caddy .env; other UIDs must not.
[[ $(stat -c '%a %U:%G' /tmp/test/caddy/.env) == '640 root:nogroup' ]]
su -s /bin/sh nobody -c 'test -r /tmp/test/caddy/.env'
su -s /bin/sh daemon -c 'test ! -r /tmp/test/caddy/.env'
su -s /bin/sh daemon -c 'test ! -r /tmp/test/state/demo/env && test ! -r /tmp/test/state/demo/logs/new.log'
# Maintenance as root prunes root-owned backups but rewrites project state
# only as the deploy user, so nothing in state becomes root-owned.
su -s /bin/bash nobody -c 'for i in $(seq 1 205); do printf "d\tmain\t%x\tok\t1s\n" "$i"; done > /tmp/test/state/demo/deploys.tsv'
mkdir -p /tmp/test/backups
rm /tmp/test/state/demo/logs/new.log
SANDBOX_MIGRATION_BACKUPS=/tmp/test/backups SANDBOX_PRUNE_DOCKER=false SANDBOX_ALERT_FREE_MB=1 \
    bash /repo/deploy/maintenance.sh
[[ $(wc -l < /tmp/test/state/demo/deploys.tsv) == 200 ]]
[[ -z $(find /tmp/test/state/demo -user root) ]]
# Повторная миграция исправляет владельцев после прежней версии скрипта.
chown root:root "$SANDBOX_STATE_ROOT/demo" "$SANDBOX_SITES_ROOT/demo/releases"
bash /repo/deploy/migrate.sh state
bash /repo/deploy/migrate.sh sites
su -s /bin/bash nobody -c 'touch /tmp/test/state/demo/new; mkdir /tmp/test/sites/demo/releases/again'
# Создание spa.d обновлением также проверяется с правами root.
export SANDBOX_CADDY_DIR=/tmp/test/caddy SANDBOX_CADDY_SPA_DIR=/tmp/test/caddy/spa.d
export SANDBOX_BACKUP_DIR=/tmp/test/backups
mkdir -p "$SANDBOX_CADDY_DIR"
printf '*.sandbox.actual.test {\n}\n' > "$SANDBOX_CADDY_DIR/Caddyfile"
bash /repo/update-infra.sh --caddy-only -y
su -s /bin/bash nobody -c 'touch /tmp/test/caddy/spa.d/demo.caddy'
SCRIPT
rc=$?
assert_eq "после root-миграции deploy может писать состояние и релизы" 0 "$rc"
[[ $rc -eq 0 ]] || cat "$SB/owners.log"

cat > "$SB/Caddyfile" <<'CONFIG'
{
    auto_https off
}
:8080 {
    respond "STATIC-OLD"
}
CONFIG
cat > "$SB/compose.yaml" <<CONFIG
name: $PROJECT
services:
  caddy:
    image: lucaslorentz/caddy-docker-proxy:ci-alpine
    command: docker-proxy --caddyfile-path /etc/caddy/Caddyfile --label-prefix sandbox_test_$$
    labels:
      sandbox_test_$$: http://docker.test:8080
      sandbox_test_$$.respond: DOCKER-OK
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
CONFIG
if ! (cd "$SB" && docker compose up -d) >"$SB/proxy.log" 2>&1; then
    _fail "запуск docker-proxy" "$(cat "$SB/proxy.log")"
    finish
    exit 1
fi
response() {
    (cd "$SB" && docker compose exec -T caddy wget -qO- --header="Host: $1" http://127.0.0.1:8080/ 2>/dev/null)
}
wait_response() {
    local host=$1 expected=$2
    for _ in {1..40}; do
        [[ $(response "$host") == "$expected" ]] && return 0
        sleep 0.25
    done
    return 1
}
assert_ok "Docker label обслуживается до обновления" wait_response docker.test DOCKER-OK
assert_ok "базовый маршрут обслуживается" wait_response static.test STATIC-OLD
# Запись поверх inode: Caddyfile примонтирован отдельным файлом.
sed s/STATIC-OLD/STATIC-NEW/ "$SB/Caddyfile" > "$SB/new"
cat "$SB/new" > "$SB/Caddyfile"
assert_ok "новый базовый конфиг валиден" caddy_validate
assert_ok "применение через docker-proxy" caddy_reload
assert_ok "новый статический маршрут применён" wait_response static.test STATIC-NEW
assert_ok "Docker label сохранился после обновления" wait_response docker.test DOCKER-OK
if (( _tests_failed > 0 )); then
    (cd "$SB" && docker compose logs --tail 60 caddy)
fi
finish
