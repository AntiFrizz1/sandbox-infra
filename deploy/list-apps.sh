#!/usr/bin/env bash
# Перечисляет все sandbox-проекты с их текущим состоянием.
# Использование: ./list-apps.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=deploy/lib/project.sh
source "$SCRIPT_DIR/lib/project.sh"
# shellcheck source=deploy/lib/release.sh
source "$SCRIPT_DIR/lib/release.sh"

shopt -s nullglob
repos=("$SANDBOX_GIT_ROOT"/*.git)

if [[ ${#repos[@]} -eq 0 ]]; then
    echo "Проектов пока нет. Создать: new-app.sh <имя>"
    exit 0
fi

printf '%-24s %-8s %-14s %-10s %s\n' ПРОЕКТ ТИП РЕЛИЗ ДЕПЛОЙ АДРЕС
printf '%-24s %-8s %-14s %-10s %s\n' ------ --- ----- ------ -----

for repo in "${repos[@]}"; do
    name="$(basename "$repo" .git)"
    is_valid_app_name "$name" || continue

    type="?"
    if load_project_config "$name" "$(app_work_dir "$name")" 2>/dev/null; then
        type="$PROJECT_TYPE"
    fi

    current="$(current_release_sha "$name" 2>/dev/null || true)"
    release="${current:0:12}"
    [[ -n "$release" ]] || release="—"

    deploys="$(app_state_dir "$name")/deploys.tsv"
    outcome="—"
    if [[ -f "$deploys" ]]; then
        outcome=$(tail -1 "$deploys" | cut -f4)
        # Провал последней попытки при живом релизе — состояние, которое
        # важно видеть сразу: сайт работает, но не на том коммите.
        if [[ "$outcome" != ok && -n "$current" ]]; then
            outcome="failed*"
        fi
    fi

    printf '%-24s %-8s %-14s %-10s https://%s.%s\n' \
        "$name" "$type" "$release" "$outcome" "$name" "$SANDBOX_DOMAIN"
done

echo
echo "failed* — последняя попытка деплоя провалилась, отдаётся предыдущий релиз"
