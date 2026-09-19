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
# shellcheck source=deploy/lib/project.sh
source "$SCRIPT_DIR/lib/project.sh"
# shellcheck source=deploy/lib/release.sh
source "$SCRIPT_DIR/lib/release.sh"

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

load_project_config "$NAME" "$WORKDIR" || die "[$NAME] конфиг проекта некорректен"

case "$PROJECT_TYPE" in
    docker)
        log "[$NAME] Останавливаю Docker-контейнеры ($PROJECT_COMPOSE_FILE)"
        # Имя compose-проекта фиксируется явно: по умолчанию оно выводится
        # из basename каталога, и любой переезд каталога осиротил бы
        # существующие контейнеры и volumes.
        (cd "$WORKDIR" && COMPOSE_PROJECT_NAME="$NAME" docker compose down)
        ;;
    dockerfile-only)
        die "[$NAME] в проекте есть Dockerfile, но нет compose-файла — останавливать нечего.
   Добавь docker-compose.yml, либо укажи тип явно в .sandbox.conf"
        ;;
    *)
        CURRENT_LINK="$(current_link "$NAME")"
        if [[ -L "$CURRENT_LINK" ]]; then
            # Убирается только ссылка current: Caddy сразу начинает отдавать
            # 404, а сами релизы остаются, поэтому проект можно вернуть
            # откатом, не дожидаясь пересборки.
            STOPPED_SHA="$(current_release_sha "$NAME" || true)"
            rm -f "$CURRENT_LINK"
            log "[$NAME] Снял с раздачи релиз ${STOPPED_SHA:0:12}, сборки сохранены"
        elif [[ -d "$SITEDIR" ]]; then
            die "[$NAME] проект ещё не переведён на релизную раскладку — см. docs/MIGRATION.md"
        else
            die "[$NAME] Нечего останавливать — статика не найдена ($SITEDIR)"
        fi
        ;;
esac

log "[$NAME] остановлен."
echo "   Поднять заново: git push prod main"
echo "   Либо вернуть последний релиз без пересборки: rollback-app.sh $NAME"
