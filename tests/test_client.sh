#!/usr/bin/env bash
# Тесты клиента (раздел 6 плана): согласованность валидатора, отсутствие
# инъекции в ssh, вывод имени из remote, поддержка worktree, отказ от
# автокоммита и честная отчётность о результате деплоя.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CLIENT="$ROOT/client/sandbox-deploy"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"
# shellcheck source=deploy/lib/common.sh
source "$ROOT/deploy/lib/common.sh"

client_validator=$(sed -n '/^is_valid_app_name() {/,/^}/p' "$CLIENT")
[[ -n "$client_validator" ]] || { echo "  FAIL валидатор не найден в клиенте" >&2; exit 1; }
eval "$(printf '%s' "$client_validator" | sed '1s/^is_valid_app_name/client_is_valid_app_name/')"

echo "== обе копии валидатора согласованы =="
corpus=(
    a z 0 my-app a-b-c app2 "$(printf 'a%.0s' {1..63})" "$(printf 'a%.0s' {1..64})"
    "" "-app" "app-" "-" "MyApp" "my_app" "my.app" "my app" "my/app"
    "." ".." "../../etc" "/etc/passwd" "app;rm -rf /" 'app`id`' 'app$(id)'
    " app" "приложение" "app
evil"
)
for name in "${corpus[@]}"; do
    is_valid_app_name "$name"; canonical=$?
    client_is_valid_app_name "$name"; client=$?
    assert_eq "'${name//$'\n'/\\n}': server=$canonical client=$client" "$canonical" "$client"
done

SB=$(make_sandbox)
trap 'rm -rf "$SB"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# Подставной ssh: пишет вызовы в лог и отвечает так, как задаёт SSH_REPLY.
mkdir -p "$SB/bin"
cat > "$SB/bin/ssh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SB/ssh-calls.log"
[[ -n "\${SSH_REPLY-}" ]] && printf '%s\n' "\$SSH_REPLY"
exit \${SSH_RC:-0}
EOF
chmod +x "$SB/bin/ssh"

run_client() {
    PATH="$SB/bin:$PATH" SANDBOX_HOST="deploy@example.invalid" HOME="$SB" \
        bash "$CLIENT" "$@"
}

echo
echo "== невалидное имя отклоняется до ssh =="
: > "$SB/ssh-calls.log"
assert_fail    "stop с traversal-именем"   run_client stop '../../etc' -y
assert_eq      "ssh не вызывался" "" "$(cat "$SB/ssh-calls.log")"
assert_fail    "stop с ';'"                run_client stop 'demo;id' -y
assert_eq      "ssh по-прежнему не вызывался" "" "$(cat "$SB/ssh-calls.log")"

echo
echo "== команда собирается без инъекции =="
: > "$SB/ssh-calls.log"
assert_ok "stop с валидным именем" run_client stop 'my-app' -y
assert_eq "аргумент экранирован" \
    "deploy@example.invalid /srv/deploy/stop-app.sh my-app" \
    "$(cat "$SB/ssh-calls.log")"

echo
echo "== имя выводится из remote, а не из имени каталога =="
mkdir -p "$SB/some-unrelated-dirname"
git init -q "$SB/some-unrelated-dirname"
git -C "$SB/some-unrelated-dirname" remote add prod \
    "ssh://deploy@example.invalid/srv/git/real-project.git"
: > "$SB/ssh-calls.log"
( cd "$SB/some-unrelated-dirname" && run_client status >/dev/null )
assert_eq "использовано имя из remote" \
    "deploy@example.invalid /srv/deploy/status-app.sh real-project" \
    "$(cat "$SB/ssh-calls.log")"

echo
echo "== git worktree поддерживается =="
WT="$SB/wt-main"
git init -q "$WT"
git -C "$WT" checkout -q -b main
: > "$WT/f"; git -C "$WT" add -A; git -C "$WT" commit -qm init
git -C "$WT" remote add prod "ssh://deploy@example.invalid/srv/git/wt-project.git"
git -C "$WT" worktree add -q "$SB/wt-linked" -b side
assert_eq "в worktree .git — файл, а не каталог" \
    "обычный файл" "$(stat -c %F "$SB/wt-linked/.git" 2>/dev/null || stat -f %HT "$SB/wt-linked/.git")"

: > "$SB/ssh-calls.log"
( cd "$SB/wt-linked" && run_client status >/dev/null )
assert_eq "worktree распознан как репозиторий, имя взято из remote" \
    "deploy@example.invalid /srv/deploy/status-app.sh wt-project" \
    "$(cat "$SB/ssh-calls.log")"
assert_missing "клиент не создал вложенный репозиторий" "$SB/wt-linked/.git/HEAD"

echo
echo "== push не коммитит сам =="
# Remote — настоящий bare-репозиторий по локальному пути, но путь построен
# так же, как серверный, поэтому имя из него выводится тем же кодом.
# Подставной ssh при этом продолжает обслуживать проверку статуса.
git init --bare -q "$SB/srv/git/proj.git"
P="$SB/proj"
git init -q "$P"; git -C "$P" checkout -q -b main
echo v1 > "$P/tracked"; git -C "$P" add -A; git -C "$P" commit -qm v1
git -C "$P" remote add prod "$SB/srv/git/proj.git"
assert_eq "имя выводится из пути remote" "proj" \
    "$(cd "$P" && git remote get-url prod | sed -n 's|.*/srv/git/\([^/]*\)\.git/\?$|\1|p')"
echo "НЕЗАКОММИЧЕНО" > "$P/dirty"

BEFORE=$(git -C "$P" rev-parse HEAD)
: > "$SB/ssh-calls.log"
( cd "$P" && SSH_REPLY=ok run_client push -y >/dev/null 2>&1 ) || true
assert_eq      "новых коммитов не появилось" "$BEFORE" "$(git -C "$P" rev-parse HEAD)"
assert_eq      "файл остался неотслеживаемым" "да" \
    "$(git -C "$P" status --porcelain | grep -q '^?? dirty' && echo да || echo нет)"

echo
echo "== --commit-all коммитит явно =="
: > "$SB/ssh-calls.log"
( cd "$P" && SSH_REPLY=ok run_client push --commit-all "явный коммит" -y >/dev/null 2>&1 ) || true
assert_eq "коммит создан" "явный коммит" "$(git -C "$P" log -1 --format=%s)"
assert_eq "рабочее дерево чистое" "" "$(git -C "$P" status --porcelain)"

echo
echo "== провал деплоя не выдаётся за успех =="
: > "$SB/ssh-calls.log"
( cd "$P" && SSH_REPLY=failed run_client push -y >"$SB/out" 2>&1 )
rc=$?
assert_eq "клиент завершается с ошибкой" "1" "$rc"
assert_eq "сказано, что пуш принят, а деплой провалился" "да" \
    "$(grep -q 'ДЕПЛОЙ ПРОВАЛИЛСЯ' "$SB/out" && echo да || echo нет)"
assert_eq "подсказан способ посмотреть лог" "да" \
    "$(grep -q 'sandbox-deploy logs' "$SB/out" && echo да || echo нет)"

: > "$SB/ssh-calls.log"
( cd "$P" && SSH_REPLY=no-record run_client push -y >"$SB/out" 2>&1 )
assert_eq "отсутствие записи о деплое — тоже ошибка" "1" "$?"

: > "$SB/ssh-calls.log"
( cd "$P" && SSH_REPLY=ok run_client push -y >"$SB/out" 2>&1 )
assert_eq "успешный деплой — нулевой код" "0" "$?"
assert_eq "результат проверяется через --check" "да" \
    "$(grep -q 'status-app.sh proj --check' "$SB/ssh-calls.log" && echo да || echo нет)"

echo
echo "== неинтерактивный режим =="
: > "$SB/ssh-calls.log"
assert_ok "remove с -y не спрашивает подтверждения" \
    run_client remove 'my-app' -y
assert_eq "вызван remove-app.sh --force" "да" \
    "$(grep -q 'remove-app.sh --force my-app' "$SB/ssh-calls.log" && echo да || echo нет)"

echo
echo "== прочие команды =="
: > "$SB/ssh-calls.log"
assert_ok "list" run_client list
assert_eq "вызван list-apps.sh" "deploy@example.invalid /srv/deploy/list-apps.sh" \
    "$(cat "$SB/ssh-calls.log")"

: > "$SB/ssh-calls.log"
assert_ok "rollback с явным sha" run_client rollback my-app abc1234
assert_eq "вызван rollback-app.sh с sha" \
    "deploy@example.invalid /srv/deploy/rollback-app.sh my-app abc1234" \
    "$(cat "$SB/ssh-calls.log")"

: > "$SB/ssh-calls.log"
assert_ok "logs" run_client logs my-app
assert_eq "вызван logs-app.sh" "deploy@example.invalid /srv/deploy/logs-app.sh my-app" \
    "$(cat "$SB/ssh-calls.log")"

finish
