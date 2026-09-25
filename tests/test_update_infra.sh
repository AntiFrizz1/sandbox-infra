#!/usr/bin/env bash
# Тесты обновления инфраструктуры (раздел 7 плана): домен и email
# переживают обновление, .env не трогается, бэкапы создаются.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

SB=$(make_sandbox)
trap 'rm -rf "$SB"' EXIT

export SANDBOX_STATE_ROOT="$SB/state"
export SANDBOX_DEPLOY_DIR="$SB/srv/deploy"
export SANDBOX_CADDY_DIR="$SB/srv/caddy"
export SANDBOX_CADDY_SPA_DIR="$SB/srv/caddy/spa.d"
export SANDBOX_BACKUP_DIR="$SB/backups"

REAL_DOMAIN="sandbox.antifrizz.example"
REAL_EMAIL="me@antifrizz.example"

setup_installed() {
    rm -rf "$SB/srv" "$SB/backups"
    mkdir -p "$SANDBOX_DEPLOY_DIR/lib" "$SANDBOX_CADDY_DIR"

    # Действующий конфиг: шаблон с уже вписанным доменом и email,
    # но старой структурой (без current и без импорта spa.d).
    cat > "$SANDBOX_CADDY_DIR/Caddyfile" <<EOF
{
    email $REAL_EMAIL
    cert_issuer acme
}

*.$REAL_DOMAIN {
    tls {
        dns timeweb {env.TIMEWEB_API_TOKEN}
    }
    @app header_regexp app Host ^([a-z0-9-]+)\\.$REAL_DOMAIN\$
    root @app /srv/sites/{re.app.1}
    file_server
}

$REAL_DOMAIN {
    respond "Sandbox root — see project subdomains"
}
EOF

    echo 'TIMEWEB_API_TOKEN=очень-секретный-токен' > "$SANDBOX_CADDY_DIR/.env"
    cp "$ROOT/caddy/docker-compose.yml" "$SANDBOX_CADDY_DIR/docker-compose.yml"
    echo 'старая версия' > "$SANDBOX_DEPLOY_DIR/hook.sh"
}

run_update() {
    SANDBOX_SRC_DIR="$ROOT" bash "$ROOT/update-infra.sh" "$@"
}

echo "== --dry-run ничего не меняет =="
setup_installed
BEFORE=$(cat "$SANDBOX_CADDY_DIR/Caddyfile")
assert_ok "dry-run отрабатывает" run_update --dry-run -y
assert_eq "Caddyfile не изменён" "$BEFORE" "$(cat "$SANDBOX_CADDY_DIR/Caddyfile")"
assert_eq "hook.sh не изменён"   "старая версия" "$(cat "$SANDBOX_DEPLOY_DIR/hook.sh")"
assert_missing "бэкапов не создано" "$SANDBOX_BACKUP_DIR"

echo
echo "== обновление скриптов =="
setup_installed
assert_ok     "обновление скриптов отрабатывает" run_update --scripts-only -y
assert_eq     "hook.sh заменён" "да" \
    "$(grep -q 'post-receive' "$SANDBOX_DEPLOY_DIR/hook.sh" && echo да || echo нет)"
assert_exists "библиотека установлена"    "$SANDBOX_DEPLOY_DIR/lib/common.sh"
assert_exists "release.sh установлен"     "$SANDBOX_DEPLOY_DIR/lib/release.sh"
assert_exists "rollback-app.sh установлен" "$SANDBOX_DEPLOY_DIR/rollback-app.sh"
assert_exists "status-app.sh установлен"  "$SANDBOX_DEPLOY_DIR/status-app.sh"
assert_ok     "скрипты исполняемы"        test -x "$SANDBOX_DEPLOY_DIR/hook.sh"
assert_eq     "бэкап прежних скриптов создан" "да" \
    "$(find "$SANDBOX_BACKUP_DIR" -maxdepth 1 -name 'deploy-*' | grep -q . && echo да || echo нет)"
assert_eq     "в бэкапе прежняя версия" "старая версия" \
    "$(cat "$SANDBOX_BACKUP_DIR"/deploy-*/hook.sh)"
assert_eq     "Caddyfile не тронут при --scripts-only" "да" \
    "$(grep -q 'root @app /srv/sites/{re.app.1}$' "$SANDBOX_CADDY_DIR/Caddyfile" && echo да || echo нет)"

echo
echo "== обновление Caddy сохраняет домен и email =="
setup_installed
assert_ok "обновление Caddy отрабатывает" run_update --caddy-only -y

CF="$SANDBOX_CADDY_DIR/Caddyfile"
HOST_PATTERN=$(sed -n 's/.*header_regexp app Host //p' "$CF")
assert_ok "матчер принимает реальный hostname" bash -c '[[ $1 =~ $2 ]]' _ "demo.$REAL_DOMAIN" "$HOST_PATTERN"
assert_fail "матчер отвергает шаблонный hostname" bash -c '[[ $1 =~ $2 ]]' _ demo.sandbox.example.com "$HOST_PATTERN"
assert_eq "домен сохранён"  "да" "$(grep -q "\*\.$REAL_DOMAIN {" "$CF" && echo да || echo нет)"
assert_eq "email сохранён"  "да" "$(grep -q "email $REAL_EMAIL" "$CF" && echo да || echo нет)"
assert_eq "плейсхолдер домена не просочился" "нет" \
    "$(grep -q 'sandbox\.example\.com' "$CF" && echo да || echo нет)"
assert_eq "плейсхолдер email не просочился"  "нет" \
    "$(grep -q 'you@example\.com' "$CF" && echo да || echo нет)"

assert_eq "новая структура применена: current" "да" \
    "$(grep -q 'root \* /srv/sites/{re.app.1}/current' "$CF" && echo да || echo нет)"
assert_eq "новая структура применена: импорт spa.d" "да" \
    "$(grep -q 'import /srv/caddy/spa.d/\*.caddy' "$CF" && echo да || echo нет)"
assert_eq "apex-блок тоже с реальным доменом" "да" \
    "$(grep -q "^$REAL_DOMAIN {" "$CF" && echo да || echo нет)"

assert_exists "каталог spa.d создан" "$SANDBOX_CADDY_SPA_DIR"
assert_eq "бэкап Caddyfile создан" "да" \
    "$(find "$SANDBOX_BACKUP_DIR" -maxdepth 1 -name 'Caddyfile-*' | grep -q . && echo да || echo нет)"
assert_eq "в бэкапе прежняя структура" "да" \
    "$(grep -q 'root @app /srv/sites/{re.app.1}$' "$SANDBOX_BACKUP_DIR"/Caddyfile-* && echo да || echo нет)"

echo
echo "== .env не затрагивается =="
assert_eq "токен на месте" "TIMEWEB_API_TOKEN=очень-секретный-токен" \
    "$(cat "$SANDBOX_CADDY_DIR/.env")"

echo
echo "== повторный запуск идемпотентен =="
BEFORE=$(cat "$CF")
out=$(run_update --caddy-only -y 2>&1)
assert_eq "конфиг не изменился" "$BEFORE" "$(cat "$CF")"
assert_eq "сказано, что всё актуально" "да" \
    "$(grep -q 'уже актуальна' <<<"$out" && echo да || echo нет)"

echo
echo "== нераспознаваемый конфиг не молчит =="
setup_installed
printf 'совершенно посторонний файл\n' > "$SANDBOX_CADDY_DIR/Caddyfile"
out=$(run_update --caddy-only -y 2>&1)
rc=$?
assert_eq "обновление прервано"          "1" "$rc"
assert_eq "объяснено, чего не хватило"   "да" \
    "$(grep -q 'не удалось определить домен' <<<"$out" && echo да || echo нет)"
assert_eq "чужой файл не перезаписан"    "совершенно посторонний файл" \
    "$(cat "$SANDBOX_CADDY_DIR/Caddyfile")"

echo
echo "== без установленной инфраструктуры =="
rm -rf "$SB/srv"
assert_fail "отказывается работать на пустом месте" run_update -y

finish
