#!/usr/bin/env bash
# Регрессионные тесты на удаление проектов (раздел 1 плана).
# Работают только внутри временного каталога, реальный /srv не затрагивается.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$HERE/../deploy"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"

SB=$(make_sandbox)
trap 'rm -rf "$SB"' EXIT

export SANDBOX_GIT_ROOT="$SB/srv/git"
export SANDBOX_APPS_ROOT="$SB/srv/apps"
export SANDBOX_SITES_ROOT="$SB/srv/sites"
export SANDBOX_STATE_ROOT="$SB/srv/state"

reset_fixture() {
    rm -rf "$SB/srv" "$SB/OUTSIDE"
    mkdir -p "$SANDBOX_GIT_ROOT/demo.git" "$SANDBOX_APPS_ROOT/demo" \
             "$SANDBOX_SITES_ROOT/demo" "$SB/OUTSIDE"
    echo "важные данные" > "$SB/OUTSIDE/important.txt"
    echo "<h1>demo</h1>"  > "$SANDBOX_SITES_ROOT/demo/index.html"
}

echo "== remove-app.sh: обход каталога =="
reset_fixture
assert_fail   "отвергает '../../OUTSIDE'" \
    "$DEPLOY/remove-app.sh" '../../OUTSIDE' --force
assert_exists "каталог за пределами /srv цел" "$SB/OUTSIDE/important.txt"

assert_fail   "отвергает '..'"          "$DEPLOY/remove-app.sh" '..' --force
assert_exists "корень apps цел"         "$SANDBOX_APPS_ROOT"

assert_fail   "отвергает абсолютный путь" "$DEPLOY/remove-app.sh" '/etc' --force
assert_fail   "отвергает имя с ';'"       "$DEPLOY/remove-app.sh" 'demo;id' --force
assert_exists "проект demo не тронут"     "$SANDBOX_GIT_ROOT/demo.git"

echo
echo "== remove-app.sh: лишние аргументы =="
reset_fixture
assert_fail   "отвергает два имени сразу" \
    "$DEPLOY/remove-app.sh" 'demo' 'OUTSIDE' --force
assert_exists "demo цел после отказа"     "$SANDBOX_GIT_ROOT/demo.git"

echo
echo "== remove-app.sh: штатное удаление =="
reset_fixture
assert_ok      "удаляет существующий проект" "$DEPLOY/remove-app.sh" demo --force
assert_missing "bare-репозиторий удалён"     "$SANDBOX_GIT_ROOT/demo.git"
assert_missing "рабочий каталог удалён"      "$SANDBOX_APPS_ROOT/demo"
assert_missing "статика удалена"             "$SANDBOX_SITES_ROOT/demo"
assert_exists  "корни каталогов целы"        "$SANDBOX_SITES_ROOT"
assert_fail    "повторное удаление сообщает об отсутствии" \
    "$DEPLOY/remove-app.sh" demo --force

echo
echo "== stop-app.sh: обход каталога =="
reset_fixture
assert_fail   "отвергает '../../OUTSIDE'"     "$DEPLOY/stop-app.sh" '../../OUTSIDE'
assert_exists "каталог за пределами /srv цел" "$SB/OUTSIDE/important.txt"
assert_fail   "отвергает имя с backtick"      "$DEPLOY/stop-app.sh" 'demo`id`'

echo
echo "== stop-app.sh: штатная остановка =="
reset_fixture
# Релизная раскладка: releases/<sha> + current -> releases/<sha>
mkdir -p "$SANDBOX_SITES_ROOT/demo/releases/abc123"
echo "<h1>demo</h1>" > "$SANDBOX_SITES_ROOT/demo/releases/abc123/index.html"
ln -s releases/abc123 "$SANDBOX_SITES_ROOT/demo/current"

assert_ok      "останавливает статический проект" "$DEPLOY/stop-app.sh" demo
assert_missing "ссылка current снята"             "$SANDBOX_SITES_ROOT/demo/current"
assert_exists  "релизы сохранены для отката"      "$SANDBOX_SITES_ROOT/demo/releases/abc123/index.html"
assert_exists  "bare-репозиторий не тронут"       "$SANDBOX_GIT_ROOT/demo.git"
assert_fail    "повторная остановка сообщает, что нечего останавливать" \
    "$DEPLOY/stop-app.sh" demo

echo
echo "== new-app.sh: валидация имени =="
reset_fixture
assert_fail   "отвергает '../evil'"      "$DEPLOY/new-app.sh" '../evil'
assert_fail   "отвергает верхний регистр" "$DEPLOY/new-app.sh" 'MyApp'
assert_fail   "отвергает пустое имя"      "$DEPLOY/new-app.sh" ''
assert_missing "ничего не создано вне git-корня" "$SB/srv/evil.git"

assert_ok     "создаёт валидный проект"   "$DEPLOY/new-app.sh" 'new-proj'
assert_exists "bare-репозиторий создан"   "$SANDBOX_GIT_ROOT/new-proj.git"
assert_exists "хук подключён"             "$SANDBOX_GIT_ROOT/new-proj.git/hooks/post-receive"
assert_fail   "повторное создание отвергается" "$DEPLOY/new-app.sh" 'new-proj'

finish
