#!/usr/bin/env bash
# Тесты серверных скриптов состояния: status-app.sh, list-apps.sh,
# logs-app.sh (раздел 6 плана).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DEPLOY="$ROOT/deploy"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

SB=$(make_sandbox)
trap 'rm -rf "$SB"' EXIT

export SANDBOX_GIT_ROOT="$SB/srv/git"
export SANDBOX_APPS_ROOT="$SB/srv/apps"
export SANDBOX_SITES_ROOT="$SB/srv/sites"
export SANDBOX_STATE_ROOT="$SB/srv/state"
export SANDBOX_DOMAIN="sandbox.test.local"

NAME=demo
mkdir -p "$SANDBOX_GIT_ROOT/$NAME.git" "$SANDBOX_APPS_ROOT/$NAME" \
         "$SANDBOX_STATE_ROOT/$NAME/logs" \
         "$SANDBOX_SITES_ROOT/$NAME/releases/aaaa111" \
         "$SANDBOX_SITES_ROOT/$NAME/releases/bbbb222"
: > "$SANDBOX_APPS_ROOT/$NAME/index.html"
echo ok > "$SANDBOX_SITES_ROOT/$NAME/releases/aaaa111/index.html"
ln -s releases/aaaa111 "$SANDBOX_SITES_ROOT/$NAME/current"

DEPLOYS="$SANDBOX_STATE_ROOT/$NAME/deploys.tsv"
{
    printf '2026-09-20T10:00:00Z\tmain\taaaa111\tok\t12s\n'
    printf '2026-09-20T11:00:00Z\tmain\tbbbb222\tfailed\t4s\n'
} > "$DEPLOYS"
echo "лог сборки aaaa111" > "$SANDBOX_STATE_ROOT/$NAME/logs/aaaa111.log"
echo "СБОРКА СЛОМАНА"     > "$SANDBOX_STATE_ROOT/$NAME/logs/bbbb222.log"

echo "== status-app.sh --check =="
assert_ok   "успешный коммит — код 0" "$DEPLOY/status-app.sh" "$NAME" --check aaaa111
assert_eq   "печатает ok" "ok" "$("$DEPLOY/status-app.sh" "$NAME" --check aaaa111)"
assert_fail "провалившийся коммит — ненулевой код" \
    "$DEPLOY/status-app.sh" "$NAME" --check bbbb222
assert_eq   "печатает failed" "failed" \
    "$("$DEPLOY/status-app.sh" "$NAME" --check bbbb222 || true)"
assert_eq   "неизвестный коммит — no-record" "no-record" \
    "$("$DEPLOY/status-app.sh" "$NAME" --check cccc333 || true)"

echo
echo "== status-app.sh: активный релиз и последняя попытка различаются =="
out=$("$DEPLOY/status-app.sh" "$NAME")
assert_eq "показан активный релиз aaaa111" "да" \
    "$(grep -q 'активный релиз: aaaa111' <<<"$out" && echo да || echo нет)"
assert_eq "показана провалившаяся последняя попытка" "да" \
    "$(grep -q 'последний деплой: bbbb222  failed' <<<"$out" && echo да || echo нет)"
assert_eq "явно сказано, что отдаётся не последний коммит" "да" \
    "$(grep -q 'Отдаётся предыдущий релиз' <<<"$out" && echo да || echo нет)"
assert_eq "указан путь к логу" "да" \
    "$(grep -q 'logs/bbbb222.log' <<<"$out" && echo да || echo нет)"
assert_eq "посчитаны успехи и провалы" "да" \
    "$(grep -q '1 успешных, 1 провалившихся' <<<"$out" && echo да || echo нет)"
assert_eq "показан адрес проекта" "да" \
    "$(grep -q "https://$NAME.sandbox.test.local" <<<"$out" && echo да || echo нет)"

echo
echo "== status-app.sh: снятый с раздачи проект =="
rm "$SANDBOX_SITES_ROOT/$NAME/current"
out=$("$DEPLOY/status-app.sh" "$NAME")
assert_eq "сказано, что сайт не раздаётся" "да" \
    "$(grep -q 'активный релиз: нет' <<<"$out" && echo да || echo нет)"
ln -s releases/aaaa111 "$SANDBOX_SITES_ROOT/$NAME/current"

assert_fail "несуществующий проект" "$DEPLOY/status-app.sh" nosuch
assert_fail "невалидное имя"        "$DEPLOY/status-app.sh" '../../etc'

echo
echo "== list-apps.sh =="
mkdir -p "$SANDBOX_GIT_ROOT/other.git"
out=$("$DEPLOY/list-apps.sh")
assert_eq "проект demo в списке" "да" \
    "$(grep -q "^demo " <<<"$out" && echo да || echo нет)"
assert_eq "проект other в списке" "да" \
    "$(grep -q "^other " <<<"$out" && echo да || echo нет)"
assert_eq "провал последней попытки помечен звёздочкой" "да" \
    "$(grep -q 'failed\*' <<<"$out" && echo да || echo нет)"
assert_eq "показан активный релиз demo" "да" \
    "$(grep -q 'aaaa111' <<<"$out" && echo да || echo нет)"

echo
echo "== logs-app.sh =="
assert_eq "без аргумента — лог последней попытки" "СБОРКА СЛОМАНА" \
    "$("$DEPLOY/logs-app.sh" "$NAME" | tail -1)"
assert_eq "по полному sha" "лог сборки aaaa111" \
    "$("$DEPLOY/logs-app.sh" "$NAME" aaaa111 | tail -1)"
assert_eq "по префиксу sha" "лог сборки aaaa111" \
    "$("$DEPLOY/logs-app.sh" "$NAME" aaa | tail -1)"
assert_fail "неизвестный sha" "$DEPLOY/logs-app.sh" "$NAME" zzzz

out=$("$DEPLOY/logs-app.sh" "$NAME" --list)
assert_eq "--list показывает обе попытки" "да" \
    "$(grep -q 'aaaa111' <<<"$out" && grep -q 'bbbb222' <<<"$out" && echo да || echo нет)"

finish
