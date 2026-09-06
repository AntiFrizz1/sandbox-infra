#!/usr/bin/env bash
# Общий post-receive хук. Симлинкается в каждый bare-репозиторий проекта
# через new-app.sh. Определяет тип проекта по файлам в репо и деплоит его.
set -euo pipefail

APP_NAME=$(basename "$(pwd)" .git)
WORKDIR="/srv/apps/$APP_NAME"
SITEDIR="/srv/sites/$APP_NAME"

mkdir -p "$WORKDIR"
git --work-tree="$WORKDIR" --git-dir="$(pwd)" checkout -f main
cd "$WORKDIR"

if [[ -f "docker-compose.yml" || -f "Dockerfile" ]]; then
    echo "→ [$APP_NAME] Docker deploy"
    docker compose up -d --build

elif [[ -f "package.json" ]]; then
    echo "→ [$APP_NAME] Node build + static deploy"
    if [[ -f "package-lock.json" ]]; then
        npm ci
    else
        npm install
    fi
    npm run build
    BUILD_DIR=$( [[ -d "dist" ]] && echo dist || echo build )
    mkdir -p "$SITEDIR"
    rsync -a --delete "$BUILD_DIR/" "$SITEDIR/"

else
    echo "→ [$APP_NAME] Plain static deploy"
    mkdir -p "$SITEDIR"
    rsync -a --delete --exclude='.git' ./ "$SITEDIR/"
fi

echo "✓ [$APP_NAME] deployed at $(date)"
