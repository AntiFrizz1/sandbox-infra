#!/usr/bin/env bash
# Тесты валидации имён проектов и защиты путей (раздел 1 плана).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"
# shellcheck source=deploy/lib/common.sh
source "$HERE/../deploy/lib/common.sh"

echo "== имена проектов: валидные =="
for name in a z 0 9 ab a1 1a my-app a-b-c app2 x-1-y \
            "$(printf 'a%.0s' {1..63})"; do
    assert_ok "принимает '$name'" is_valid_app_name "$name"
done

echo
echo "== имена проектов: невалидные =="
assert_fail "отвергает пустую строку"        is_valid_app_name ""
assert_fail "отвергает 64 символа"           is_valid_app_name "$(printf 'a%.0s' {1..64})"
assert_fail "отвергает дефис в начале"       is_valid_app_name "-app"
assert_fail "отвергает дефис в конце"        is_valid_app_name "app-"
assert_fail "отвергает одиночный дефис"      is_valid_app_name "-"
assert_fail "отвергает верхний регистр"      is_valid_app_name "MyApp"
assert_fail "отвергает подчёркивание"        is_valid_app_name "my_app"
assert_fail "отвергает точку"                is_valid_app_name "my.app"
assert_fail "отвергает пробел"               is_valid_app_name "my app"
assert_fail "отвергает слеш"                 is_valid_app_name "my/app"
assert_fail "отвергает '.'"                  is_valid_app_name "."
assert_fail "отвергает '..'"                 is_valid_app_name ".."
assert_fail "отвергает '../../etc'"          is_valid_app_name "../../etc"
assert_fail "отвергает абсолютный путь"      is_valid_app_name "/etc/passwd"
assert_fail "отвергает точку с запятой"      is_valid_app_name "app;rm -rf /"
assert_fail "отвергает backtick"             is_valid_app_name 'app`id`'
assert_fail "отвергает \$(...)"              is_valid_app_name 'app$(id)'
assert_fail "отвергает перевод строки"       is_valid_app_name "$(printf 'app\nevil')"
assert_fail "отвергает ведущий пробел"       is_valid_app_name " app"
assert_fail "отвергает кириллицу"            is_valid_app_name "приложение"
assert_fail "требует ровно один аргумент"    is_valid_app_name

echo
echo "== resolve_under: границы каталогов =="
SB=$(make_sandbox)
mkdir -p "$SB/root/proj" "$SB/outside"

assert_eq "путь внутри корня разрешается" \
    "$SB/root/proj" "$(resolve_under "$SB/root" "$SB/root/proj")"
assert_fail "сам корень отвергается"        resolve_under "$SB/root" "$SB/root"
assert_fail "корень со слешем отвергается"  resolve_under "$SB/root" "$SB/root/"
assert_fail "traversal наружу отвергается"  resolve_under "$SB/root" "$SB/root/../outside"
assert_fail "'..' отвергается"              resolve_under "$SB/root" "$SB/root/.."
assert_fail "абсолютный путь снаружи"       resolve_under "$SB/root" "/etc"

ln -s "$SB/outside" "$SB/root/escape"
assert_fail "симлинк наружу отвергается"    resolve_under "$SB/root" "$SB/root/escape"

ln -s "$SB/root/proj" "$SB/root/inside-link"
assert_eq "симлинк внутрь разрешается в цель" \
    "$SB/root/proj" "$(resolve_under "$SB/root" "$SB/root/inside-link")"

echo
echo "== safe_rm_rf: удаляет только внутри корня =="
mkdir -p "$SB/root/victim" && : > "$SB/root/victim/file"
assert_ok      "удаляет каталог внутри корня" safe_rm_rf "$SB/root" "$SB/root/victim"
assert_missing "каталог действительно удалён" "$SB/root/victim"

: > "$SB/outside/keepme"
assert_fail   "отказывается удалять через traversal" safe_rm_rf "$SB/root" "$SB/root/../outside"
assert_exists "цель traversal цела"                  "$SB/outside/keepme"

assert_fail   "отказывается удалять сам корень" safe_rm_rf "$SB/root" "$SB/root"
assert_exists "корень цел"                      "$SB/root"

assert_fail   "отказывается удалять симлинк"    safe_rm_rf "$SB/root" "$SB/root/escape"
assert_exists "цель симлинка цела"              "$SB/outside"

assert_ok     "удаление несуществующего пути идемпотентно" \
    safe_rm_rf "$SB/root" "$SB/root/never-existed"

rm -rf "$SB"

echo
echo "== require_valid_app_name: прерывает выполнение =="
assert_ok   "пропускает валидное имя" bash -c \
    "source '$HERE/../deploy/lib/common.sh'; require_valid_app_name 'good-app'"
assert_fail "падает на невалидном имени" bash -c \
    "source '$HERE/../deploy/lib/common.sh'; require_valid_app_name '../evil'"

finish
