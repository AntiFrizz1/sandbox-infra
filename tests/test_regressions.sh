#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"
SB=$(make_sandbox)
trap 'rm -rf "$SB"' EXIT
export SANDBOX_GIT_ROOT="$SB/git" SANDBOX_APPS_ROOT="$SB/apps"
export SANDBOX_SITES_ROOT="$SB/sites" SANDBOX_STATE_ROOT="$SB/state"
export SANDBOX_CADDY_DIR="$SB/caddy" SANDBOX_CADDY_SPA_DIR="$SB/caddy/spa.d"
# shellcheck source=deploy/lib/common.sh
source "$ROOT/deploy/lib/common.sh"
# shellcheck source=deploy/lib/project.sh
source "$ROOT/deploy/lib/project.sh"
# shellcheck source=deploy/lib/release.sh
source "$ROOT/deploy/lib/release.sh"

mkdir -p "$SANDBOX_GIT_ROOT/demo.git" "$SB/source" "$SANDBOX_STATE_ROOT/.locks"
echo first > "$SB/source/index.html"
publish_release demo aaaa111 "$SB/source"
exec 9>"$(app_lock_file demo)"
flock 9
assert_fail "stop ждёт блокировку" env SANDBOX_LOCK_TIMEOUT=0 "$ROOT/deploy/stop-app.sh" demo
assert_fail "remove ждёт блокировку" env SANDBOX_LOCK_TIMEOUT=0 "$ROOT/deploy/remove-app.sh" demo --force
assert_exists "заблокированное удаление сохранило repo" "$SANDBOX_GIT_ROOT/demo.git"
assert_exists "заблокированный stop сохранил current" "$SANDBOX_SITES_ROOT/demo/current/index.html"
LOCK_INODE=$(stat -c %i "$(app_lock_file demo)")
flock -u 9
assert_ok "remove после освобождения lock" "$ROOT/deploy/remove-app.sh" demo --force
assert_eq "inode блокировки пережил remove" "$LOCK_INODE" "$(stat -c %i "$(app_lock_file demo)")"

publish_release demo aaaa111 "$SB/source"
rsync() { return 23; }
assert_fail "ошибка копирования повторного SHA" publish_release demo aaaa111 "$SB/source"
assert_eq "активное содержимое сохранилось" first "$(cat "$SANDBOX_SITES_ROOT/demo/current/index.html")"
unset -f rsync
echo second > "$SB/source/index.html"
assert_ok "повторный SHA публикуется" publish_release demo aaaa111 "$SB/source"
assert_eq "новая сборка активна" second "$(cat "$SANDBOX_SITES_ROOT/demo/current/index.html")"
assert_eq "SHA не зависит от ID сборки" aaaa111 "$(current_release_sha demo)"
assert_eq "первая сборка не изменена" first "$(cat "$SANDBOX_SITES_ROOT/demo/releases/aaaa111/index.html")"
assert_ok "список показывает отдельные сборки" "$ROOT/deploy/rollback-app.sh" demo --list
assert_fail "rollback отвергает путь вместо ID" "$ROOT/deploy/rollback-app.sh" demo ..
rollback_release demo >/dev/null
assert_eq "rollback возвращает первую сборку того же SHA" first "$(cat "$SANDBOX_SITES_ROOT/demo/current/index.html")"

# В отличие от клиентского mock-теста здесь исполняется настоящий хук.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init --bare -q "$SANDBOX_GIT_ROOT/rebuild.git"
git init -q -b main "$SB/work"
mkdir -p "$SB/work/public"
echo server > "$SB/work/public/index.html"
git -C "$SB/work" add .
git -C "$SB/work" commit -qm first
git -C "$SB/work" push -q "$SANDBOX_GIT_ROOT/rebuild.git" main
assert_ok "серверный redeploy запускает сборку" "$ROOT/deploy/redeploy-app.sh" rebuild
assert_ok "stop перед redeploy" "$ROOT/deploy/stop-app.sh" rebuild
assert_ok "redeploy восстанавливает сайт без нового коммита" "$ROOT/deploy/redeploy-app.sh" rebuild
assert_eq "содержимое восстановлено" server "$(cat "$SANDBOX_SITES_ROOT/rebuild/current/index.html")"

finish
