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
# shellcheck source=deploy/lib/compose.sh
source "$SCRIPT_DIR/lib/compose.sh"

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
exec > >(python3 "$SCRIPT_DIR/bounded-log.py" "$LOG_FILE" 1048576) 2>&1

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
        # Compose из коммита исполняется host daemon'ом, поэтому допускается
        # только по root-политике profile=compose и после проверки модели.
        load_compose_policy "$APP_NAME" || die "[$APP_NAME] Docker-проект не допущен политикой"
        echo "   compose-файл: $PROJECT_COMPOSE_FILE"
        WORKDIR="$(app_work_dir "$APP_NAME")"
        require_plain_under "$SANDBOX_APPS_ROOT" "$WORKDIR" || die "[$APP_NAME] небезопасный рабочий каталог"
        mkdir -p "$WORKDIR"
        # Docker-проект живёт в постоянном каталоге: там bind-mount данные.
        # Синхронизация без --delete — потерять данные приложения хуже,
        # чем оставить файл от прошлой версии.
        rsync -a "$BUILDDIR/" "$WORKDIR/"
        if [[ -f "$STATEDIR/env" ]]; then
            echo "   подкладываю серверный .env из $STATEDIR/env"
            install_private "$STATEDIR/env" "$WORKDIR/.env" || die "[$APP_NAME] небезопасный путь .env"
        fi

        # До этой точки работающий стек не тронут: отказ проверки оставляет
        # прежние контейнеры как есть.
        compose_lint "$APP_NAME" "$WORKDIR" "$PROJECT_COMPOSE_FILE" "$SANDBOX_DOMAIN" \
            || die "[$APP_NAME] compose-файл нарушает политику — стек не обновлён"
        OVERRIDE="$STATEDIR/compose.override.json"
        compose_write_override "$APP_NAME" "$WORKDIR" "$PROJECT_COMPOSE_FILE" "$OVERRIDE" \
            || die "[$APP_NAME] не удалось подготовить ограничения compose"

        rm -f "$STATEDIR/docker-active-sha"
        # Таймаут останавливает CLI; сборку, уже переданную daemon'у, он не прерывает.
        COMPOSE_WRAP=(timeout --signal=TERM --kill-after=10 "$COMPOSE_TIMEOUT")
        compose_run "$APP_NAME" "$WORKDIR" "$PROJECT_COMPOSE_FILE" -f "$OVERRIDE" -- \
            up -d --build --remove-orphans \
            || die "[$APP_NAME] docker compose up не удался"
        COMPOSE_WRAP=()

        if [[ -n "$PROJECT_HEALTH_URL" ]]; then
            # Порты наружу не публикуются, поэтому проверка идёт через Caddy
            # и только по адресу самого проекта.
            health_re="^https?://([a-z0-9-]+\.)*${APP_NAME}\.${SANDBOX_DOMAIN//./\\.}(/|\$)"
            [[ $PROJECT_HEALTH_URL =~ $health_re ]] \
                || die "[$APP_NAME] health_url должен вести на $APP_NAME.$SANDBOX_DOMAIN"
            # `up -d` возвращается, когда контейнеры созданы, а не когда
            # приложение готово отвечать.
            echo "   жду готовности: $PROJECT_HEALTH_URL"
            deadline=$(( $(date +%s) + ${SANDBOX_HEALTH_TIMEOUT:-60} ))
            until curl -fsS -o /dev/null --max-time 5 "$PROJECT_HEALTH_URL"; do
                if (( $(date +%s) >= deadline )); then
                    die "[$APP_NAME] приложение не ответило на $PROJECT_HEALTH_URL за отведённое время"
                fi
                sleep 2
            done
            echo "   приложение отвечает"
        fi
        # Атомарная подмена, а не запись поверх: status читает этот файл
        # без замка и не должен застать его пустым между truncate и write.
        printf '%s\n' "$NEWREV" > "$STATEDIR/.docker-active-sha.$$"
        mv -T "$STATEDIR/.docker-active-sha.$$" "$STATEDIR/docker-active-sha"
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
