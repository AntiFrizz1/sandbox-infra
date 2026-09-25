#!/usr/bin/env bash
# Общий post-receive хук. Симлинкается в каждый bare-репозиторий проекта
# через new-app.sh.
#
# Отличия от прежней версии:
#   - читает refs со stdin и деплоит только обновления refs/heads/main,
#     вместо безусловного `checkout -f main` при пуше в любую ветку;
#   - собирает ровно полученный newrev, а не текущее состояние main;
#   - сериализует операции проекта через flock;
#   - собирает статику в чистом дереве, без остатков прошлых сборок;
#   - публикует релиз атомарно, поэтому упавшая сборка оставляет
#     предыдущую версию сайта работающей.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=deploy/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=deploy/lib/project.sh
source "$SCRIPT_DIR/lib/project.sh"
# shellcheck source=deploy/lib/release.sh
source "$SCRIPT_DIR/lib/release.sh"
# shellcheck source=deploy/lib/caddy.sh
source "$SCRIPT_DIR/lib/caddy.sh"
# shellcheck source=deploy/lib/runner.sh
source "$SCRIPT_DIR/lib/runner.sh"

DEPLOY_BRANCH="${SANDBOX_DEPLOY_BRANCH:-main}"
TARGET_REF="refs/heads/$DEPLOY_BRANCH"
ZERO_SHA="0000000000000000000000000000000000000000"

REPO_DIR="$(pwd)"
APP_NAME="$(basename "$REPO_DIR" .git)"
require_valid_app_name "$APP_NAME"

STATEDIR="$(app_state_dir "$APP_NAME")"
BUILDDIR="$STATEDIR/build"

# --- 1. Какие refs пришли ---------------------------------------------------
# stdin вычитывается целиком, даже если ни один ref нас не интересует:
# иначе git получит EPIPE при записи остатка.
NEWREV=""
SAW_TARGET=false
while read -r _oldrev newrev refname; do
    [[ "$refname" == "$TARGET_REF" ]] || continue
    SAW_TARGET=true
    NEWREV="$newrev"
done

if [[ "$SAW_TARGET" != true ]]; then
    echo "→ [$APP_NAME] в пуше нет обновлений $TARGET_REF — деплой не запускается"
    exit 0
fi

if [[ "$NEWREV" == "$ZERO_SHA" ]]; then
    echo "→ [$APP_NAME] ветка $DEPLOY_BRANCH удалена — деплой не запускается"
    echo "   Проект продолжает работать на текущем релизе."
    exit 0
fi

is_log_sha "$NEWREV" || die "invalid revision"
umask 077
SHORT_SHA="${NEWREV:0:12}"

# --- 2. Блокировка ----------------------------------------------------------
# Один замок на проект: деплой, остановка, откат и удаление не должны
# пересекаться.
lock_app "$APP_NAME"
[[ -d "$REPO_DIR" ]] || die "[$APP_NAME] репозиторий удалён"
prepare_state "$APP_NAME" || die "unsafe state"

# --- 3. Журнал и исход ------------------------------------------------------
LOG_FILE="$STATEDIR/logs/$NEWREV.log"
DEPLOYS_LOG="$STATEDIR/deploys.tsv"
private_file "$LOG_FILE" || die "unsafe log file"
private_file "$DEPLOYS_LOG" || die "unsafe history"
STARTED_AT=$(date +%s)
DEPLOY_OK=false

record_outcome() {
    local line
    printf -v line '%s\t%s\t%s\t%s\t%ss' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$DEPLOY_BRANCH" "$NEWREV" \
        "$1" "$(( $(date +%s) - STARTED_AT ))"
    append_private_line "$DEPLOYS_LOG" "$line"

}

on_exit() {
    if [[ "$DEPLOY_OK" == true ]]; then
        record_outcome ok
        echo "✓ [$APP_NAME] развёрнут $SHORT_SHA"
        return
    fi
    record_outcome failed
    echo ""
    echo "✗ [$APP_NAME] ДЕПЛОЙ ПРОВАЛЕН на коммите $SHORT_SHA"
    # post-receive не может отменить уже принятый пуш, поэтому единственное,
    # что тут можно сделать — сказать об этом громко и однозначно.
    echo "  Пуш принят, но развёрнутая версия НЕ обновилась."
    local cur
    if cur=$(current_release_sha "$APP_NAME" 2>/dev/null); then
        echo "  Сайт продолжает отдавать предыдущий релиз: ${cur:0:12}"
    fi
    echo "  Полный лог: $LOG_FILE"
}
trap on_exit EXIT

# Вывод идёт и разработчику в терминал, и в файл лога.
exec > >(tee -a "$LOG_FILE") 2>&1

echo "→ [$APP_NAME] деплой $DEPLOY_BRANCH @ $SHORT_SHA"

# --- 4. Чистое дерево нужного коммита ---------------------------------------
# git archive переносит ровно содержимое коммита. Именно это убирает
# остатки прошлых сборок, которые раньше навсегда оседали в раздаче.
rm -rf "$BUILDDIR"
mkdir -p "$BUILDDIR"
git --git-dir="$REPO_DIR" archive "$NEWREV" | tar -x -C "$BUILDDIR"

load_project_config "$APP_NAME" "$BUILDDIR" || die "[$APP_NAME] конфиг проекта некорректен"
echo "   тип: $PROJECT_TYPE (конфиг: $PROJECT_CONFIG_SOURCE)"

# --- 5. Деплой по типу ------------------------------------------------------
case "$PROJECT_TYPE" in

    dockerfile-only)
        die "[$APP_NAME] в репозитории есть Dockerfile, но нет compose-файла.
   Раньше это приводило к ошибке 'no configuration file provided'.
   Добавь docker-compose.yml (или compose.yaml) с лейблами Caddy,
   либо укажи в .sandbox.conf другой тип проекта."
        ;;

    docker)
        die "[$APP_NAME] host Compose execution disabled. Migrate this project to a dedicated rootless daemon/VM before enabling deployment."
        ;;

    static|node)
        if [[ "$PROJECT_TYPE" == node ]]; then
            OUTPUT="$STATEDIR/worker-output"
            safe_rm_rf "$STATEDIR" "$OUTPUT" || die "unsafe worker output"
            run_worker "$APP_NAME" "$BUILDDIR" "$OUTPUT" "$PROJECT_BUILD_CMD" \
                || die "[$APP_NAME] isolated worker failed; no host fallback"
            safe_rm_rf "$STATEDIR" "$BUILDDIR" || die "unsafe source"
            mv "$OUTPUT" "$BUILDDIR"
        fi

        PUBLISH_SRC=$(validate_publish_dir "$BUILDDIR" "$PROJECT_PUBLISH_DIR") \
            || die "[$APP_NAME] каталог публикации '$PROJECT_PUBLISH_DIR' непригоден"

        echo "   публикую $PROJECT_PUBLISH_DIR → releases/$SHORT_SHA"
        publish_release "$APP_NAME" "$NEWREV" "$PUBLISH_SRC" \
            || die "[$APP_NAME] публикация релиза не удалась"
        rm -f "$STATEDIR/docker-active-sha"

        # Релиз уже переключён и сайт работает, поэтому проблема с правилами
        # раздачи не должна помечать деплой провалившимся — только предупредить.
        sync_spa_config "$APP_NAME" "$PROJECT_SPA" "$SANDBOX_DOMAIN" \
            || warn "[$APP_NAME] релиз опубликован, но правила раздачи не применились"
        ;;
esac

rm -rf "$BUILDDIR"
DEPLOY_OK=true
