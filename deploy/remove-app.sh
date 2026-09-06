#!/usr/bin/env bash
# Полностью и необратимо удаляет проект: bare-репозиторий, рабочий чекаут,
# статику и (для Docker-проектов) контейнеры/volumes/локально собранные образы.
# Использование: ./remove-app.sh <app-name> [--force|-y]
set -euo pipefail

FORCE=false
NAME=""
for arg in "$@"; do
    case "$arg" in
        --force|-y) FORCE=true ;;
        *) NAME="$arg" ;;
    esac
done

if [[ -z "$NAME" ]]; then
    echo "Usage: $0 <app-name> [--force|-y]" >&2
    exit 1
fi

REPO="/srv/git/$NAME.git"
WORKDIR="/srv/apps/$NAME"
SITEDIR="/srv/sites/$NAME"

if [[ ! -d "$REPO" && ! -d "$WORKDIR" && ! -d "$SITEDIR" ]]; then
    echo "!! Проект '$NAME' не найден (нет ни $REPO, ни $WORKDIR, ни $SITEDIR)" >&2
    exit 1
fi

if [[ "$FORCE" != true ]]; then
    read -rp "Точно удалить '$NAME'? Это удалит bare-репозиторий, файлы и Docker-данные проекта без возможности восстановления. [y/N] " ans
    [[ "${ans:-n}" =~ ^[Yy]$ ]] || { echo "Отменено."; exit 1; }
fi

if [[ -f "$WORKDIR/docker-compose.yml" || -f "$WORKDIR/Dockerfile" ]]; then
    echo "==> [$NAME] Удаляю Docker-контейнеры, volumes и локальные образы"
    (cd "$WORKDIR" && docker compose down -v --rmi local)
fi

rm -rf "$REPO" "$WORKDIR" "$SITEDIR"

echo "✓ [$NAME] полностью удалён."
