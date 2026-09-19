#!/usr/bin/env bash
# Временно останавливает проект без потери данных.
# Docker-проект — docker compose down (контейнеры уходят, volumes/образы остаются).
# Статика/SPA — убирается из /srv/sites, поэтому Caddy начинает отдавать 404.
# Bare-репозиторий не трогается: следующий git push поднимет проект заново.
# Использование: ./stop-app.sh <app-name>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <app-name>" >&2
    exit 1
fi

NAME="$1"
require_valid_app_name "$NAME"

REPO="$(app_repo_dir  "$NAME")"
WORKDIR="$(app_work_dir "$NAME")"
SITEDIR="$(app_site_dir "$NAME")"

if [[ ! -d "$REPO" ]]; then
    die "$REPO не найден — проект '$NAME' не существует"
fi

if [[ -f "$WORKDIR/docker-compose.yml" || -f "$WORKDIR/Dockerfile" ]]; then
    log "[$NAME] Останавливаю Docker-контейнеры"
    (cd "$WORKDIR" && docker compose down)
elif [[ -d "$SITEDIR" ]]; then
    log "[$NAME] Убираю статику из раздачи"
    safe_rm_rf "$SANDBOX_SITES_ROOT" "$SITEDIR" || die "[$NAME] остановка прервана"
else
    die "[$NAME] Нечего останавливать — ни Docker-проекта, ни статики не найдено"
fi

log "[$NAME] остановлен. git push prod main поднимет проект заново."
