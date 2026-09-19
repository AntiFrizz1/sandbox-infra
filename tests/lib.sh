#!/usr/bin/env bash
# Минимальный тест-раннер без внешних зависимостей.
# Подключается в начале каждого tests/test_*.sh, в конце вызывается finish.

_tests_total=0
_tests_failed=0

_ok()   { printf '  ok   %s\n' "$1"; }
_fail() {
    _tests_failed=$((_tests_failed + 1))
    printf '  FAIL %s\n       %s\n' "$1" "$2" >&2
}

# assert_ok <описание> <команда...> — команда должна завершиться успешно
assert_ok() {
    local desc=$1; shift
    _tests_total=$((_tests_total + 1))
    if "$@" >/dev/null 2>&1; then _ok "$desc"; else _fail "$desc" "ожидался успех: $*"; fi
}

# assert_fail <описание> <команда...> — команда должна завершиться ошибкой
assert_fail() {
    local desc=$1; shift
    _tests_total=$((_tests_total + 1))
    if "$@" >/dev/null 2>&1; then _fail "$desc" "ожидался провал, но команда успешна: $*"; else _ok "$desc"; fi
}

# assert_eq <описание> <ожидаемое> <фактическое>
assert_eq() {
    local desc=$1 expected=$2 actual=$3
    _tests_total=$((_tests_total + 1))
    if [[ "$expected" == "$actual" ]]; then
        _ok "$desc"
    else
        _fail "$desc" "ожидалось: '$expected', получено: '$actual'"
    fi
}

# assert_exists / assert_missing <описание> <путь>
assert_exists()  {
    _tests_total=$((_tests_total + 1))
    if [[ -e "$2" ]]; then _ok "$1"; else _fail "$1" "путь должен существовать: $2"; fi
}
assert_missing() {
    _tests_total=$((_tests_total + 1))
    if [[ ! -e "$2" ]]; then _ok "$1"; else _fail "$1" "путь должен отсутствовать: $2"; fi
}

finish() {
    printf '\n  итого: %d проверок, %d провалов\n' "$_tests_total" "$_tests_failed"
    [[ $_tests_failed -eq 0 ]]
}

# Одноразовая песочница для файловых тестов. Никогда не трогаем реальный /srv.
make_sandbox() {
    local dir
    dir=$(mktemp -d "${TMPDIR:-/tmp}/sandbox-test.XXXXXX")
    printf '%s\n' "$dir"
}
