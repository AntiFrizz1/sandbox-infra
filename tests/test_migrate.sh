#!/usr/bin/env bash
# Тесты миграции уже развёрнутой инфраструктуры (docs/MIGRATION.md).
# Работают только во временном каталоге.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MIGRATE="$ROOT/deploy/migrate.sh"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

SB=$(make_sandbox)
trap 'rm -rf "$SB"' EXIT

export SANDBOX_GIT_ROOT="$SB/srv/git"
export SANDBOX_APPS_ROOT="$SB/srv/apps"
export SANDBOX_SITES_ROOT="$SB/srv/sites"
export SANDBOX_STATE_ROOT="$SB/srv/state"

# Слепок «старой» инфраструктуры: плоская статика, node-проект с build/,
# docker-проект, проект только с Dockerfile и проект с невалидным именем.
setup_old() {
    rm -rf "$SB/srv"
    mkdir -p "$SANDBOX_GIT_ROOT"/{plain,vite,api,justdocker,Bad_Name}.git

    mkdir -p "$SANDBOX_SITES_ROOT/plain"
    echo '<h1>плоский сайт</h1>' > "$SANDBOX_SITES_ROOT/plain/index.html"
    echo 'TOKEN=секрет'          > "$SANDBOX_SITES_ROOT/plain/.env"

    mkdir -p "$SANDBOX_APPS_ROOT/vite/build"
    : > "$SANDBOX_APPS_ROOT/vite/package.json"
    mkdir -p "$SANDBOX_SITES_ROOT/vite"
    echo 'сборка' > "$SANDBOX_SITES_ROOT/vite/index.html"

    mkdir -p "$SANDBOX_APPS_ROOT/api"
    : > "$SANDBOX_APPS_ROOT/api/compose.yaml"
    echo 'BOT_TOKEN=секрет' > "$SANDBOX_APPS_ROOT/api/.env"

    mkdir -p "$SANDBOX_APPS_ROOT/justdocker"
    : > "$SANDBOX_APPS_ROOT/justdocker/Dockerfile"
}

echo "== audit ничего не меняет =="
setup_old
BEFORE=$(find "$SB/srv" | sort)
out=$("$MIGRATE" audit 2>&1)
assert_eq "дерево не изменилось" "$BEFORE" "$(find "$SB/srv" | sort)"
assert_eq "найден невалидный Bad_Name" "да" \
    "$(grep -q 'Bad_Name' <<<"$out" && echo да || echo нет)"
assert_eq "найден проект только с Dockerfile" "да" \
    "$(grep -q 'justdocker' <<<"$out" && echo да || echo нет)"
assert_eq "найден опубликованный .env" "да" \
    "$(grep -q 'sites/plain/.env' <<<"$out" && echo да || echo нет)"
assert_eq "docker-проект с compose.yaml распознан" "да" \
    "$(grep -qE '^api +docker' <<<"$out" && echo да || echo нет)"
assert_eq "node-проект распознан" "да" \
    "$(grep -qE '^vite +node' <<<"$out" && echo да || echo нет)"

echo
echo "== state --dry-run ничего не создаёт =="
setup_old
assert_ok      "dry-run отрабатывает" "$MIGRATE" state --dry-run
assert_missing "конфиги не созданы"   "$SANDBOX_STATE_ROOT/plain/config"

echo
echo "== state создаёт конфиги =="
setup_old
assert_ok "state отрабатывает" "$MIGRATE" state

assert_exists "конфиг plain создан" "$SANDBOX_STATE_ROOT/plain/config"
assert_eq "plain: тип static" "да" \
    "$(grep -q '^type=static$' "$SANDBOX_STATE_ROOT/plain/config" && echo да || echo нет)"
assert_eq "plain: publish_dir=. — прежнее поведение сохранено" "да" \
    "$(grep -q '^publish_dir=\.$' "$SANDBOX_STATE_ROOT/plain/config" && echo да || echo нет)"

assert_eq "vite: publish_dir=build по факту существующего каталога" "да" \
    "$(grep -q '^publish_dir=build$' "$SANDBOX_STATE_ROOT/vite/config" && echo да || echo нет)"
assert_eq "vite: build_cmd задан" "да" \
    "$(grep -q '^build_cmd=npm run build$' "$SANDBOX_STATE_ROOT/vite/config" && echo да || echo нет)"

assert_eq "api: тип docker" "да" \
    "$(grep -q '^type=docker$' "$SANDBOX_STATE_ROOT/api/config" && echo да || echo нет)"
assert_eq "api: .env перенесён" "BOT_TOKEN=секрет" \
    "$(cat "$SANDBOX_STATE_ROOT/api/env")"
assert_exists "api: прежний .env остался на месте для отката" \
    "$SANDBOX_APPS_ROOT/api/.env"

assert_missing "проект с невалидным именем пропущен" "$SANDBOX_STATE_ROOT/Bad_Name"
assert_exists  "замок создан" "$SANDBOX_STATE_ROOT/.locks/plain.lock"

echo
echo "== state идемпотентен =="
printf 'type=static\npublish_dir=public\n' > "$SANDBOX_STATE_ROOT/plain/config"
assert_ok "повторный запуск отрабатывает" "$MIGRATE" state
assert_eq "существующий конфиг не перезаписан" "да" \
    "$(grep -q '^publish_dir=public$' "$SANDBOX_STATE_ROOT/plain/config" && echo да || echo нет)"

echo
echo "== sites: перевод на релизную раскладку =="
setup_old
"$MIGRATE" state >/dev/null
assert_ok "sites отрабатывает" "$MIGRATE" sites

SITE="$SANDBOX_SITES_ROOT/plain"
assert_ok     "current — симлинк"     test -L "$SITE/current"
assert_eq     "ссылка относительная"  "да" \
    "$(readlink "$SITE/current" | grep -q '^releases/legacy-' && echo да || echo нет)"
assert_eq     "содержимое сайта сохранено" "<h1>плоский сайт</h1>" \
    "$(cat "$SITE/current/index.html")"
assert_exists "релиз записан в журнал" "$SANDBOX_STATE_ROOT/plain/releases.tsv"
assert_eq "в журнале тот же релиз, на который смотрит current" "да" \
    "$(grep -q "$(basename "$(readlink "$SITE/current")")" \
        "$SANDBOX_STATE_ROOT/plain/releases.tsv" && echo да || echo нет)"

echo
echo "== ротация не удалит мигрированный релиз =="
# shellcheck source=deploy/lib/common.sh
source "$ROOT/deploy/lib/common.sh"
# shellcheck source=deploy/lib/project.sh
source "$ROOT/deploy/lib/project.sh"
# shellcheck source=deploy/lib/release.sh
source "$ROOT/deploy/lib/release.sh"
LEGACY=$(basename "$(readlink "$SITE/current")")
prune_releases plain 5
assert_exists "мигрированный релиз пережил ротацию" "$SITE/releases/$LEGACY"

echo
echo "== sites идемпотентен =="
BEFORE=$(readlink "$SITE/current")
assert_ok "повторный запуск отрабатывает" "$MIGRATE" sites
assert_eq "current не изменился" "$BEFORE" "$(readlink "$SITE/current")"

echo
echo "== sites --revert возвращает плоскую раскладку =="
assert_ok      "revert отрабатывает" "$MIGRATE" sites --revert
assert_missing "current убран"       "$SITE/current"
assert_missing "releases убран"      "$SITE/releases"
assert_eq      "содержимое на месте" "<h1>плоский сайт</h1>" \
    "$(cat "$SITE/index.html")"
assert_eq      "секрет тоже вернулся как был" "TOKEN=секрет" \
    "$(cat "$SITE/.env")"

echo
echo "== миграция не выходит за пределы своих каталогов =="
setup_old
mkdir -p "$SB/OUTSIDE" && echo важное > "$SB/OUTSIDE/file"
"$MIGRATE" state >/dev/null
"$MIGRATE" sites >/dev/null
assert_exists "посторонний каталог цел" "$SB/OUTSIDE/file"

finish
