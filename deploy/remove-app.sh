#!/usr/bin/env bash
# Полностью и необратимо удаляет проект: bare-репозиторий, рабочий чекаут,
# статику и (для Docker-проектов) контейнеры/volumes/локально собранные образы.
# Использование: ./remove-app.sh <app-name> [--force|-y]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

FORCE=false
NAME=""
NAME_SEEN=false

for arg in "$@"; do
    case "$arg" in
        --force|-y)
            FORCE=true
            ;;
        *)
            # Раньше здесь побеждал последний аргумент, из-за чего
            # `remove-app.sh myapp лишнее` молча удаляло 'лишнее'.
            if [[ "$NAME_SEEN" == true ]]; then
                die "лишний аргумент: '$arg'. Ожидается ровно одно имя проекта."
            fi
            NAME="$arg"
            NAME_SEEN=true
            ;;
    esac
done

if [[ "$NAME_SEEN" != true ]]; then
    echo "Usage: $0 <app-name> [--force|-y]" >&2
    exit 1
fi

require_valid_app_name "$NAME"

REPO="$(app_repo_dir   "$NAME")"
WORKDIR="$(app_work_dir  "$NAME")"
SITEDIR="$(app_site_dir  "$NAME")"
STATEDIR="$(app_state_dir "$NAME")"

if [[ ! -d "$REPO" && ! -d "$WORKDIR" && ! -d "$SITEDIR" ]]; then
    die "Проект '$NAME' не найден (нет ни $REPO, ни $WORKDIR, ни $SITEDIR)"
fi

if [[ "$FORCE" != true ]]; then
    read -rp "Точно удалить '$NAME'? Это удалит bare-репозиторий, файлы и Docker-данные проекта без возможности восстановления. [y/N] " ans
    [[ "${ans:-n}" =~ ^[Yy]$ ]] || { echo "Отменено."; exit 0; }
fi

if [[ -f "$WORKDIR/docker-compose.yml" || -f "$WORKDIR/Dockerfile" ]]; then
    log "[$NAME] Удаляю Docker-контейнеры, volumes и локальные образы"
    (cd "$WORKDIR" && docker compose down -v --rmi local)
fi

# Каждый путь проверяется относительно своего корня по отдельности:
# traversal в любом из них обрывает удаление целиком.
safe_rm_rf "$SANDBOX_GIT_ROOT"   "$REPO"     || die "[$NAME] удаление прервано"
safe_rm_rf "$SANDBOX_APPS_ROOT"  "$WORKDIR"  || die "[$NAME] удаление прервано"
safe_rm_rf "$SANDBOX_SITES_ROOT" "$SITEDIR"  || die "[$NAME] удаление прервано"
safe_rm_rf "$SANDBOX_STATE_ROOT" "$STATEDIR" || die "[$NAME] удаление прервано"

log "[$NAME] полностью удалён."
