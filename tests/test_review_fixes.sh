#!/usr/bin/env bash
# Регрессии по итогам ревью:
#   1. status — read-only команда и не должна ждать замок проекта;
#   2. неинтерактивный init не должен падать на необязательном вопросе;
#   3. временный каталог сборки не должен оставаться при сбое публикации.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

SB=$(make_sandbox)
trap 'rm -rf "$SB"' EXIT

export SANDBOX_GIT_ROOT="$SB/git" SANDBOX_APPS_ROOT="$SB/apps"
export SANDBOX_SITES_ROOT="$SB/sites" SANDBOX_STATE_ROOT="$SB/state"
export SANDBOX_DOMAIN="sandbox.test.local"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# shellcheck source=deploy/lib/common.sh
source "$ROOT/deploy/lib/common.sh"
# shellcheck source=deploy/lib/project.sh
source "$ROOT/deploy/lib/project.sh"
# shellcheck source=deploy/lib/release.sh
source "$ROOT/deploy/lib/release.sh"

mkdir -p "$SANDBOX_GIT_ROOT/demo.git" "$SANDBOX_STATE_ROOT/.locks" \
         "$SANDBOX_STATE_ROOT/demo/logs" "$SB/source"
echo first > "$SB/source/index.html"
publish_release demo aaaa111 "$SB/source" >/dev/null
printf '2026-09-20T10:00:00Z\tmain\taaaa111\tok\t1s\n' > "$SANDBOX_STATE_ROOT/demo/deploys.tsv"

echo "== status не ждёт замок проекта =="
# Имитируем идущий деплой: замок занят другим процессом.
( exec 9>"$(app_lock_file demo)"; flock 9; sleep 30 ) &
HOLDER=$!
sleep 0.4

start=$(date +%s)
timeout 5 "$ROOT/deploy/status-app.sh" demo >"$SB/status.out" 2>&1
rc=$?
elapsed=$(( $(date +%s) - start ))
assert_eq "status отвечает во время занятого замка" "0" "$rc"
assert_eq "отвечает быстро, а не по таймауту" "да" \
    "$( (( elapsed <= 2 )) && echo да || echo нет )"
assert_eq "показан активный релиз" "да" \
    "$(grep -q 'активный релиз: aaaa111' "$SB/status.out" && echo да || echo нет)"

timeout 5 "$ROOT/deploy/status-app.sh" demo --check aaaa111 >"$SB/check.out" 2>&1
assert_eq "--check тоже не блокируется" "0" "$?"
assert_eq "--check печатает ok" "ok" "$(cat "$SB/check.out")"

# Остальные read-only команды и раньше не блокировались — фиксируем это.
assert_ok "logs не блокируется"  timeout 5 "$ROOT/deploy/logs-app.sh" demo --list
assert_ok "list не блокируется"  timeout 5 "$ROOT/deploy/list-apps.sh"

# А вот изменяющие операции обязаны по-прежнему ждать.
assert_fail "rollback по-прежнему уважает замок" \
    env SANDBOX_LOCK_TIMEOUT=0 "$ROOT/deploy/rollback-app.sh" demo
assert_fail "stop по-прежнему уважает замок" \
    env SANDBOX_LOCK_TIMEOUT=0 "$ROOT/deploy/stop-app.sh" demo

kill "$HOLDER" 2>/dev/null
wait "$HOLDER" 2>/dev/null

echo
echo "== docker-active-sha читается целиком =="
# Файл перезаписывается при каждом docker-деплое; читатель без замка не
# должен ловить его пустым в момент записи.
STATE="$SANDBOX_STATE_ROOT/demo"
printf '2026-09-20T11:00:00Z\tmain\tbbbb222\tok\t2s\n' >> "$STATE/deploys.tsv"
printf '%s\n' bbbb222 > "$STATE/docker-active-sha"

# Для docker-проекта активную версию задаёт этот файл, а не ссылка current.
assert_eq "активным считается коммит из docker-active-sha" "ok" \
    "$("$ROOT/deploy/status-app.sh" demo --check bbbb222)"
assert_eq "успешный, но уже не активный коммит помечается inactive" "inactive" \
    "$("$ROOT/deploy/status-app.sh" demo --check aaaa111 || true)"

rm -f "$STATE/docker-active-sha"
sed -i '/bbbb222/d' "$STATE/deploys.tsv"
assert_eq "без файла активность снова определяется ссылкой current" "ok" \
    "$("$ROOT/deploy/status-app.sh" demo --check aaaa111)"

echo
echo "== временный каталог сборки убирается при сбое публикации =="
count_staging() {
    find "$SANDBOX_SITES_ROOT/demo/releases" -mindepth 1 -maxdepth 1 -name '.*' | wc -l
}
assert_eq "перед сбоем временных каталогов нет" "0" "$(count_staging)"

# mv используется и для переноса сборки, и для переключения ссылки;
# здесь важен именно первый вызов.
mv() { return 1; }
assert_fail "публикация при сбое mv отваливается" \
    publish_release demo cccc333 "$SB/source"
unset -f mv
assert_eq "временный каталог не остался" "0" "$(count_staging)"
assert_eq "активный релиз не тронут" "first" \
    "$(cat "$SANDBOX_SITES_ROOT/demo/current/index.html")"

echo
echo "== неинтерактивный init завершается успешно =="
mkdir -p "$SB/bin"
cat > "$SB/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "SSHLOG"
echo "   репозиторий уже существует, пропускаю создание"
EOF
sed -i "s#SSHLOG#$SB/ssh-calls.log#" "$SB/bin/ssh"
chmod +x "$SB/bin/ssh"

P="$SB/proj"
git init -q -b main "$P"
: > "$P/f"; git -C "$P" add -A; git -C "$P" commit -qm init

: > "$SB/ssh-calls.log"
( cd "$P" && PATH="$SB/bin:$PATH" SANDBOX_HOST="deploy@example.invalid" HOME="$SB" \
    bash "$ROOT/client/sandbox-deploy" init myapp </dev/null >"$SB/init.out" 2>&1 )
rc=$?
assert_eq "init без --yes завершается успешно" "0" "$rc"
assert_eq "remote настроен" "ssh://deploy@example.invalid/srv/git/myapp.git" \
    "$(git -C "$P" remote get-url prod)"
assert_eq "деплой не запускался без явного согласия" "нет" \
    "$(grep -q 'status-app.sh' "$SB/ssh-calls.log" && echo да || echo нет)"
assert_eq "подсказано, как запушить" "да" \
    "$(grep -q 'sandbox-deploy push' "$SB/init.out" && echo да || echo нет)"

echo
echo "== разрушающие подтверждения по-прежнему требуют --yes =="
: > "$SB/ssh-calls.log"
run_client() {
    PATH="$SB/bin:$PATH" SANDBOX_HOST="deploy@example.invalid" HOME="$SB" \
        bash "$ROOT/client/sandbox-deploy" "$@" </dev/null
}
assert_fail "remove без --yes отклонён"   run_client remove my-app
assert_eq   "удаление не ушло на сервер" "нет" \
    "$(grep -q 'remove-app.sh' "$SB/ssh-calls.log" && echo да || echo нет)"
assert_fail "rollback без --yes отклонён" run_client rollback my-app
assert_ok   "remove с --yes проходит"     run_client remove my-app -y

finish
