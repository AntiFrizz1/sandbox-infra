#!/usr/bin/env bash
# Тесты деплой-хука: фильтрация refs, детерминированность, блокировка,
# чистое дерево сборки, атомарная публикация и откат (разделы 2 и 4 плана).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

SB=$(make_sandbox)
trap 'rm -rf "$SB"' EXIT

export SANDBOX_GIT_ROOT="$SB/srv/git"
export SANDBOX_APPS_ROOT="$SB/srv/apps"
export SANDBOX_SITES_ROOT="$SB/srv/sites"
export SANDBOX_STATE_ROOT="$SB/srv/state"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

mkdir -p "$SANDBOX_GIT_ROOT" "$SANDBOX_APPS_ROOT" "$SANDBOX_SITES_ROOT" "$SANDBOX_STATE_ROOT"

NAME=demo
REPO="$SANDBOX_GIT_ROOT/$NAME.git"
WORK="$SB/work"
SITE="$SANDBOX_SITES_ROOT/$NAME"
STATE="$SANDBOX_STATE_ROOT/$NAME"

git init --bare -q "$REPO"
ln -s "$ROOT/deploy/hook.sh" "$REPO/hooks/post-receive"

git init -q "$WORK"
git -C "$WORK" checkout -q -b main
mkdir -p "$WORK/public"

commit() {  # commit <текст в public/index.html> [доп-файл] [содержимое]
    echo "$1" > "$WORK/public/index.html"
    [[ $# -ge 3 ]] && { mkdir -p "$(dirname "$WORK/$2")"; echo "$3" > "$WORK/$2"; }
    git -C "$WORK" add -A
    git -C "$WORK" commit -qm "$1"
}

push() { git -C "$WORK" push -q prod "$@" 2>&1; }
served() { cat "$SITE/current/index.html" 2>/dev/null; }
current_sha() { basename "$(readlink "$SITE/current" 2>/dev/null)" 2>/dev/null; }

git -C "$WORK" remote add prod "$REPO"

echo "== первый деплой =="
commit "ВЕРСИЯ-1"
V1=$(git -C "$WORK" rev-parse HEAD)
push prod main >/dev/null 2>&1 || true
push main >/dev/null 2>&1 || true
assert_eq    "сайт отдаёт версию 1" "ВЕРСИЯ-1" "$(served)"
assert_eq    "current указывает на коммит" "$V1" "$(current_sha)"
assert_exists "релиз лежит в releases/<sha>" "$SITE/releases/$V1/index.html"
assert_ok    "current — символическая ссылка" test -L "$SITE/current"
assert_eq    "ссылка относительная" "releases/$V1" "$(readlink "$SITE/current")"

echo
echo "== публикуется только publish_dir =="
commit "ВЕРСИЯ-2" "secret.txt" "НЕ ДОЛЖНО ПОПАСТЬ В РАЗДАЧУ"
push main >/dev/null 2>&1
assert_eq      "сайт отдаёт версию 2" "ВЕРСИЯ-2" "$(served)"
assert_missing "файл из корня репозитория не опубликован" "$SITE/current/secret.txt"

echo
echo "== .env и .git никогда не публикуются =="
mkdir -p "$WORK/public"
echo 'TOKEN=secret' > "$WORK/public/.env"
commit "ВЕРСИЯ-3"
push main >/dev/null 2>&1
assert_eq      "сайт отдаёт версию 3" "ВЕРСИЯ-3" "$(served)"
assert_missing ".env не попал в раздачу" "$SITE/current/.env"
rm "$WORK/public/.env"

echo
echo "== пуш в другую ветку не деплоит =="
BEFORE=$(current_sha)
git -C "$WORK" checkout -q -b feature/x
echo "ВЕРСИЯ-ФИЧИ" > "$WORK/public/index.html"
git -C "$WORK" add -A && git -C "$WORK" commit -qm feature
out=$(push feature/x 2>&1)
assert_eq "хук сообщает, что деплоя не будет" \
    "да" "$(grep -q 'нет обновлений' <<<"$out" && echo да || echo нет)"
assert_eq "current не изменился"       "$BEFORE" "$(current_sha)"
assert_eq "сайт по-прежнему версия 3"  "ВЕРСИЯ-3" "$(served)"
git -C "$WORK" checkout -q main

echo
echo "== деплоится ровно полученный коммит, а не текущее состояние main =="
commit "ВЕРСИЯ-4"
V4=$(git -C "$WORK" rev-parse HEAD)
commit "ВЕРСИЯ-5"
# Пушим только V4, хотя локально main уже на V5.
push "$V4:refs/heads/main" >/dev/null 2>&1
assert_eq "развёрнут именно переданный коммит" "$V4"        "$(current_sha)"
assert_eq "сайт отдаёт версию 4"               "ВЕРСИЯ-4"  "$(served)"
push main >/dev/null 2>&1   # догоняем до V5

echo
echo "== несколько refs в одном пуше =="
commit "ВЕРСИЯ-6"
V6=$(git -C "$WORK" rev-parse HEAD)
git -C "$WORK" branch -f other HEAD
push main other >/dev/null 2>&1
assert_eq "деплой прошёл по main"   "$V6"       "$(current_sha)"
assert_eq "сайт отдаёт версию 6"    "ВЕРСИЯ-6"  "$(served)"

echo
echo "== упавшая сборка не ломает работающий сайт =="
BEFORE=$(current_sha)
cat > "$WORK/.sandbox.conf" <<'EOF'
type=node
build_cmd=echo СБОРКА СЛОМАНА >&2; exit 1
publish_dir=dist
EOF
echo '{"name":"demo","version":"1.0.0","private":true}' > "$WORK/package.json"
commit "ВЕРСИЯ-7-СЛОМАННАЯ"
out=$(push main 2>&1)
assert_eq "хук сообщает о провале" \
    "да" "$(grep -q 'ДЕПЛОЙ ПРОВАЛЕН' <<<"$out" && echo да || echo нет)"
assert_eq "хук предупреждает, что пуш принят, а версия не обновилась" \
    "да" "$(grep -q 'Пуш принят' <<<"$out" && echo да || echo нет)"
assert_eq "current не переключился"  "$BEFORE"  "$(current_sha)"
assert_eq "сайт продолжает работать" "ВЕРСИЯ-6" "$(served)"

echo
echo "== журнал деплоев различает успех и провал =="
assert_exists "deploys.tsv создан" "$STATE/deploys.tsv"
assert_eq "последняя запись — провал" "failed" "$(tail -1 "$STATE/deploys.tsv" | cut -f4)"
assert_eq "успешные записи тоже есть" \
    "да" "$(cut -f4 "$STATE/deploys.tsv" | grep -q '^ok$' && echo да || echo нет)"
assert_exists "лог сборки сохранён" "$STATE/logs"

echo
echo "== каталог сборки чистится между деплоями =="
rm -f "$WORK/.sandbox.conf" "$WORK/package.json"
cat > "$WORK/.sandbox.conf" <<'EOF'
type=static
publish_dir=public
EOF
echo "мусор" > "$WORK/public/stale.txt"
commit "ВЕРСИЯ-8"
push main >/dev/null 2>&1
assert_exists "файл из коммита опубликован" "$SITE/current/stale.txt"

git -C "$WORK" rm -q "$WORK/public/stale.txt"
commit "ВЕРСИЯ-9"
push main >/dev/null 2>&1
assert_eq      "сайт отдаёт версию 9" "ВЕРСИЯ-9" "$(served)"
assert_missing "удалённый файл исчез из раздачи" "$SITE/current/stale.txt"
assert_missing "каталог сборки убран за собой"   "$STATE/build"

echo
echo "== симлинк за пределы сборки отвергается =="
BEFORE=$(current_sha)
echo "СЕКРЕТ" > "$SB/outside-secret"
ln -s ../../../outside-secret "$WORK/public/leak.lnk"
git -C "$WORK" add -A && git -C "$WORK" commit -qm "leak"
out=$(push main 2>&1)
assert_eq "деплой отклонён" \
    "да" "$(grep -q 'ДЕПЛОЙ ПРОВАЛЕН' <<<"$out" && echo да || echo нет)"
assert_eq "current не изменился" "$BEFORE" "$(current_sha)"
git -C "$WORK" rm -q "$WORK/public/leak.lnk"
git -C "$WORK" commit -qm "unleak"

echo
echo "== хранение релизов и защита текущего =="
for i in 10 11 12 13 14 15; do
    commit "ВЕРСИЯ-$i"
    push main >/dev/null 2>&1
done
kept=$(find "$SITE/releases" -mindepth 1 -maxdepth 1 -type d | wc -l)
assert_eq    "оставлено 5 релизов" "5" "$kept"
assert_exists "текущий релиз на месте" "$SITE/current/index.html"
assert_eq    "сайт отдаёт последнюю версию" "ВЕРСИЯ-15" "$(served)"

echo
echo "== откат без пересборки =="
PREV=$(basename "$(find "$SITE/releases" -mindepth 1 -maxdepth 1 -type d \
    -not -name "$(current_sha)" -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)")
out=$("$ROOT/deploy/rollback-app.sh" "$NAME" 2>&1)
assert_eq "откат переключил current" "$PREV" "$(current_sha)"
assert_eq "сайт отдаёт предыдущую версию" "ВЕРСИЯ-14" "$(served)"
assert_eq "релизов по-прежнему 5 — откат ничего не удалил" \
    "5" "$(find "$SITE/releases" -mindepth 1 -maxdepth 1 -type d | wc -l)"

echo
echo "== блокировка сериализует операции =="
# Держим замок проекта из фонового процесса и проверяем, что откат ждёт,
# а не работает параллельно с чужой операцией.
(
    exec 9>"$STATE/lock"
    flock 9
    sleep 5
) &
LOCK_PID=$!
sleep 0.5

start=$(date +%s)
SANDBOX_LOCK_TIMEOUT=1 "$ROOT/deploy/rollback-app.sh" "$NAME" >/dev/null 2>&1
rc=$?
elapsed=$(( $(date +%s) - start ))
assert_eq "откат отклонён, пока замок занят" "1" "$rc"
assert_eq "ожидание уложилось в таймаут"     "да" \
    "$( (( elapsed <= 3 )) && echo да || echo нет )"

wait "$LOCK_PID" 2>/dev/null
assert_ok "после освобождения замка откат проходит" \
    "$ROOT/deploy/rollback-app.sh" "$NAME"

echo
echo "== stop убирает раздачу, но сохраняет релизы =="
KEPT=$(find "$SITE/releases" -mindepth 1 -maxdepth 1 -type d | wc -l)
assert_ok      "stop-app отрабатывает"   "$ROOT/deploy/stop-app.sh" "$NAME"
assert_missing "current снят"            "$SITE/current"
assert_eq      "релизы на месте"         "$KEPT" \
    "$(find "$SITE/releases" -mindepth 1 -maxdepth 1 -type d | wc -l)"
assert_ok      "проект возвращается откатом без пересборки" \
    "$ROOT/deploy/rollback-app.sh" "$NAME"
assert_exists  "сайт снова отдаётся"     "$SITE/current/index.html"

echo
echo "== удаление ветки не удаляет сайт =="
BEFORE=$(current_sha)
out=$(git -C "$WORK" push -q prod --delete main 2>&1 || true)
assert_eq "current не изменился" "$BEFORE" "$(current_sha)"
assert_exists "сайт на месте" "$SITE/current/index.html"

finish
