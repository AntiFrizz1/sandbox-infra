#!/usr/bin/env bash
# Перевод уже развёрнутой инфраструктуры на новую раскладку.
# Пошаговое описание и план отката — в docs/MIGRATION.md.
#
#   ./migrate.sh audit            только смотрит, ничего не меняет
#   ./migrate.sh state            создаёт /srv/state/<name> и конфиги
#   ./migrate.sh sites            переводит /srv/sites на релизную раскладку
#   ./migrate.sh sites --revert   возвращает плоскую раскладку
#
# Общие флаги: --dry-run
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=deploy/lib/project.sh
source "$SCRIPT_DIR/lib/project.sh"
# shellcheck source=deploy/lib/release.sh
source "$SCRIPT_DIR/lib/release.sh"

DRY_RUN=false
REVERT=false
COMMAND=""

for arg in "$@"; do
    case "$arg" in
        audit|state|sites) [[ -n "$COMMAND" ]] && die "лишняя команда: $arg"; COMMAND="$arg" ;;
        --dry-run)         DRY_RUN=true ;;
        --revert)          REVERT=true ;;
        -h|--help)         sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                 die "неизвестный аргумент: $arg" ;;
    esac
done

[[ -n "$COMMAND" ]] || { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

run() {
    if [[ "$DRY_RUN" == true ]]; then
        printf '   [dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

# Список проектов по bare-репозиториям.
list_projects() {
    shopt -s nullglob
    local repo
    for repo in "$SANDBOX_GIT_ROOT"/*.git; do
        basename "$repo" .git
    done
}

# migrate_detect_type <name> — тип по рабочему каталогу, для уже
# развёрнутых проектов. Отличается от detect_project_type тем, что
# учитывает проекты, у которых есть только статика в /srv/sites.
migrate_detect_type() {
    local name=$1 work site
    work="$(app_work_dir "$name")"
    site="$(app_site_dir "$name")"
    if [[ -d "$work" ]]; then
        local t
        t=$(detect_project_type "$work")
        if [[ "$t" == static && ! -d "$site" ]]; then
            echo "unknown"
        else
            echo "$t"
        fi
    elif [[ -d "$site" ]]; then
        echo "static"
    else
        echo "unknown"
    fi
}

# ============================== audit =======================================
if [[ "$COMMAND" == audit ]]; then
    echo "=== Проекты ==="
    printf '%-24s %-16s %-6s %-6s\n' ПРОЕКТ ТИП САЙТ РАБОЧИЙ
    found=false
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        found=true
        printf '%-24s %-16s %-6s %-6s\n' "$name" "$(migrate_detect_type "$name")" \
            "$([[ -d "$(app_site_dir "$name")" ]] && echo да || echo нет)" \
            "$([[ -d "$(app_work_dir "$name")" ]] && echo да || echo нет)"
    done < <(list_projects)
    [[ "$found" == true ]] || echo "(проектов не найдено)"

    echo
    echo "=== Имена, не проходящие валидацию ==="
    bad=false
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        if ! is_valid_app_name "$name"; then
            echo "  $name — потребует переименования (см. фазу 1 в docs/MIGRATION.md)"
            bad=true
        fi
    done < <(list_projects)
    [[ "$bad" == true ]] || echo "  все имена корректны"

    echo
    echo "=== Проекты только с Dockerfile (перестанут деплоиться) ==="
    any=false
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        if [[ "$(migrate_detect_type "$name")" == dockerfile-only ]]; then
            echo "  $name — добавь compose-файл либо задай тип в .sandbox.conf"
            any=true
        fi
    done < <(list_projects)
    [[ "$any" == true ]] || echo "  таких нет"

    echo
    echo "=== Уже опубликованные секреты и служебные файлы ==="
    any=false
    if [[ -d "$SANDBOX_SITES_ROOT" ]]; then
        while IFS= read -r f; do
            echo "  $f"
            any=true
        done < <(find "$SANDBOX_SITES_ROOT" -maxdepth 3 \
                    \( -name '.env' -o -name '.env.*' -o -name '*.pem' \
                       -o -name '*.key' -o -name '.git' \) 2>/dev/null)
    fi
    [[ "$any" == true ]] || echo "  не найдено"
    echo
    echo "  Примечание: найденное выше лежит в раздаче ПРЯМО СЕЙЧАС и"
    echo "  останется доступным до следующего деплоя проекта."
    echo "  После деплоя .env, .git и ключи в раздачу уже не попадают —"
    echo "  они исключаются при публикации. Но при publish_dir=. наружу"
    echo "  по-прежнему уедут исходники и всё остальное содержимое репозитория."
    echo "  Перевод на public/ — добровольный шаг, см. docs/MIGRATION.md."

    echo
    echo "=== Симлинки внутри раздачи ==="
    any=false
    if [[ -d "$SANDBOX_SITES_ROOT" ]]; then
        while IFS= read -r l; do
            echo "  $l -> $(readlink "$l")"
            any=true
        done < <(find "$SANDBOX_SITES_ROOT" -maxdepth 3 -type l 2>/dev/null)
    fi
    [[ "$any" == true ]] || echo "  не найдено"

    echo
    echo "=== Состояние миграции ==="
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        site="$(app_site_dir "$name")"
        state="$(app_state_dir "$name")"
        printf '  %-24s state:%-4s releases:%-4s\n' "$name" \
            "$([[ -f "$state/config" ]] && echo да || echo нет)" \
            "$([[ -L "$site/current" ]] && echo да || echo нет)"
    done < <(list_projects)
    exit 0
fi

# ============================== state =======================================
if [[ "$COMMAND" == state ]]; then
    log "Создаю серверное состояние проектов"
    assert_plain_path "$SANDBOX_STATE_ROOT/.locks" || die "unsafe lock directory"
    run mkdir -p "$SANDBOX_STATE_ROOT/.locks"
    run set_deploy_owner "$SANDBOX_STATE_ROOT" "$SANDBOX_STATE_ROOT/.locks"
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        is_valid_app_name "$name" || {
            warn "$name: имя не проходит валидацию, пропускаю (нужно переименование)"
            continue
        }

        [[ $DRY_RUN == true ]] || lock_app "$name"
        state="$(app_state_dir "$name")"
        require_plain_under "$SANDBOX_STATE_ROOT" "$state/logs" || die "unsafe state path"
        for owned in "$state/config" "$state/env" "$state/deploys.tsv" "$state/releases.tsv"; do
            assert_plain_path "$owned" || die "unsafe state file"
        done
        work="$(app_work_dir  "$name")"
        type=$(migrate_detect_type "$name")

        if [[ -f "$state/config" ]]; then
            echo "   $name: конфиг уже есть, содержимое сохраняю"
            run prepare_state "$name"
            run chmod 600 "$state/config"
            run set_deploy_owner "$state" "$state/config"
            for owned in "$state/logs" "$state/releases.tsv" "$state/deploys.tsv" "$state/env"; do
                [[ ! -e $owned ]] || run set_deploy_owner "$owned"
                [[ ! -f $owned ]] || run chmod 600 "$owned"
            done
            continue
        fi

        run prepare_state "$name"

        publish_dir=""
        build_cmd=""
        case "$type" in
            static|unknown)
                type=static
                # Ключевое решение миграции: существующие статические
                # проекты публиковали корень репозитория, и это поведение
                # сохраняется, чтобы ничего не сломалось. Перевод на
                # public/ — отдельный добровольный шаг.
                publish_dir="."
                ;;
            node)
                if [[ -d "$work/dist" ]]; then publish_dir="dist"
                elif [[ -d "$work/build" ]]; then publish_dir="build"
                else publish_dir="dist"
                    warn "$name: ни dist/, ни build/ не найдены, ставлю dist — проверь после первого деплоя"
                fi
                build_cmd="npm run build"
                ;;
            docker)
                ;;
            dockerfile-only)
                warn "$name: только Dockerfile без compose-файла — деплой будет останавливаться с ошибкой"
                type=docker
                ;;
        esac

        echo "   $name: type=$type publish_dir=${publish_dir:-—}"
        if [[ "$DRY_RUN" != true ]]; then
            {
                printf 'type=%s\n' "$type"
                [[ -n "$publish_dir" ]] && printf 'publish_dir=%s\n' "$publish_dir"
                [[ -n "$build_cmd" ]]   && printf 'build_cmd=%s\n' "$build_cmd"
                printf 'spa=false\n'
                printf 'health_url=\n'
            } > "$state/config"
        fi

        # .env копируется, а не переносится: Docker-проект продолжает читать
        # прежний файл до конца миграции, и откат остаётся возможным.
        if [[ -f "$work/.env" && ! -e "$state/env" ]]; then
            echo "   $name: переношу .env в $state/env"
            run install_private "$work/.env" "$state/env"
        fi

        run chmod 600 "$state/config"
        run touch "$(app_lock_file "$name")"
        run set_deploy_owner "$state" "$state/logs" "$state/config" "$(app_lock_file "$name")"
        [[ ! -f "$state/env" ]] || run set_deploy_owner "$state/env"
    done < <(list_projects)

    echo
    log "Готово. Private state сохранять; восстановление — по security runbook."
    exit 0
fi

# ============================== sites =======================================
if [[ "$COMMAND" == sites ]]; then
    # shellcheck source=deploy/lib/migration.sh
    source "$SCRIPT_DIR/lib/migration.sh"
    failed=0
    while IFS= read -r name; do
        [[ -n $name ]] || continue
        if ! is_valid_app_name "$name"; then
            warn "$name: invalid name, skipped"
            continue
        fi
        # A subshell releases each project's lock before moving to the next.
        set +e
        (
            set -e
            [[ $DRY_RUN == true ]] || lock_app "$name"
            migrate_site "$name"
        )
        rc=$?
        set -e
        if (( rc != 0 )); then
            warn "$name: FAILED/skipped; previously completed projects remain completed"
            failed=1
        fi
    done < <(list_projects)
    exit "$failed"
fi
