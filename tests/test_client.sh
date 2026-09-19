#!/usr/bin/env bash
# Клиент распространяется отдельно и потому содержит собственную копию
# валидатора имён. Тест следит, чтобы копия не разъехалась с канонической,
# и чтобы имя не утекало в удалённый шелл неэкранированным.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

# Канонический валидатор
# shellcheck source=deploy/lib/common.sh
source "$ROOT/deploy/lib/common.sh"

# Копия из клиента: вытаскиваем только определение функции, не запуская скрипт.
client_validator=$(
    sed -n '/^is_valid_app_name() {/,/^}/p' "$ROOT/client/sandbox-deploy"
)

if [[ -z "$client_validator" ]]; then
    echo "  FAIL в client/sandbox-deploy не найдена функция is_valid_app_name" >&2
    exit 1
fi

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
    assert_eq "'${name//$'\n'/\\n}': server=$canonical client=$client" \
        "$canonical" "$client"
done

echo
echo "== отклонение невалидного имени происходит ДО вызова ssh =="
SB=$(make_sandbox)
trap 'rm -rf "$SB"' EXIT

# Подставной ssh: если клиент его вызовет, останется файл-улика.
mkdir -p "$SB/bin"
cat > "$SB/bin/ssh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SB/ssh-calls.log"
EOF
chmod +x "$SB/bin/ssh"

run_client() {
    PATH="$SB/bin:$PATH" SANDBOX_HOST="deploy@example.invalid" HOME="$SB" \
        bash "$ROOT/client/sandbox-deploy" "$@" < /dev/null
}

assert_fail   "stop с traversal-именем завершается ошибкой" run_client stop '../../etc'
assert_missing "ssh не вызывался"                           "$SB/ssh-calls.log"

assert_fail   "stop с ';' завершается ошибкой"              run_client stop 'demo;id'
assert_missing "ssh по-прежнему не вызывался"               "$SB/ssh-calls.log"

echo
echo "== валидное имя доходит до ssh в экранированном виде =="
assert_ok    "stop с валидным именем вызывает ssh" run_client stop 'my-app'
assert_exists "ssh вызван"                          "$SB/ssh-calls.log"
assert_eq    "команда собрана без инъекции" \
    "deploy@example.invalid /srv/deploy/stop-app.sh my-app" \
    "$(cat "$SB/ssh-calls.log")"

finish
