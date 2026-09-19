#!/usr/bin/env bash
# Прогоняет все tests/test_*.sh, каждый в отдельном процессе.
# Дополнительно гоняет ShellCheck, если он установлен.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

failed=0
total=0

for t in "$HERE"/test_*.sh; do
    [[ -e "$t" ]] || continue
    total=$((total + 1))
    printf '\n=== %s ===\n' "$(basename "$t")"
    if bash "$t"; then :; else failed=$((failed + 1)); fi
done

printf '\n=== shellcheck ===\n'

# Пути относительно корня репозитория: shellcheck -x резолвит source-директивы
# от текущего каталога, а в docker-варианте корень примонтирован в /mnt.
mapfile -t scripts < <(
    cd "$ROOT" && {
        find deploy tests -name '*.sh' -type f
        printf '%s\n' bootstrap.sh update-infra.sh client/sandbox-deploy
    }
)

run_shellcheck() {
    if command -v shellcheck >/dev/null 2>&1; then
        ( cd "$ROOT" && shellcheck -x -S warning "${scripts[@]}" )
    elif command -v docker >/dev/null 2>&1; then
        echo "  (локального shellcheck нет, использую koalaman/shellcheck в docker)"
        docker run --rm -v "$ROOT:/mnt:ro" -w /mnt koalaman/shellcheck:stable \
            -x -S warning "${scripts[@]}"
    else
        return 2
    fi
}

if run_shellcheck; then
    echo "  ok   shellcheck чист"
elif [[ $? -eq 2 ]]; then
    echo "  SKIP shellcheck недоступен (установи shellcheck или docker)"
else
    echo "  FAIL shellcheck нашёл замечания" >&2
    failed=$((failed + 1))
fi

printf '\n===============================\n'
if [[ $failed -eq 0 ]]; then
    printf 'ВСЕ ТЕСТЫ ПРОЙДЕНЫ (%d файлов)\n' "$total"
else
    printf 'ПРОВАЛЕНО: %d из %d\n' "$failed" "$total" >&2
fi
exit $(( failed > 0 ? 1 : 0 ))
