#!/usr/bin/env bash
# Временно останавливает проект без потери данных.
# Docker-проект — docker compose down (контейнеры уходят, volumes/образы остаются).
# Статика/SPA — убирается из /srv/sites, поэтому Caddy начинает отдавать 404.
# Bare-репозиторий не трогается: следующий git push поднимет проект заново.
# Использование: ./stop-app.sh <app-name>
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <app-name>" >&2
    exit 1
fi

NAME="$1"
REPO="/srv/git/$NAME.git"
WORKDIR="/srv/apps/$NAME"
SITEDIR="/srv/sites/$NAME"

if [[ ! -d "$REPO" ]]; then
    echo "!! $REPO не найден — проект '$NAME' не существует" >&2
    exit 1
fi

if [[ -f "$WORKDIR/docker-compose.yml" || -f "$WORKDIR/Dockerfile" ]]; then
    echo "==> [$NAME] Останавливаю Docker-контейнеры"
    (cd "$WORKDIR" && docker compose down)
elif [[ -d "$SITEDIR" ]]; then
    echo "==> [$NAME] Убираю статику из раздачи"
    rm -rf "$SITEDIR"
else
    echo "!! [$NAME] Нечего останавливать — ни Docker-проекта, ни статики не найдено" >&2
    exit 1
fi

echo "✓ [$NAME] остановлен. git push prod main поднимет проект заново."
