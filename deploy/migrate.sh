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
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        is_valid_app_name "$name" || {
            warn "$name: имя не проходит валидацию, пропускаю (нужно переименование)"
            continue
        }

        state="$(app_state_dir "$name")"
        work="$(app_work_dir  "$name")"
        type=$(migrate_detect_type "$name")

        if [[ -f "$state/config" ]]; then
            echo "   $name: конфиг уже есть, пропускаю"
            continue
        fi

        run mkdir -p "$state/logs"

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
            run cp -a "$work/.env" "$state/env"
        fi

        run touch "$state/lock"
    done < <(list_projects)

    echo
    log "Готово. Откат этой фазы: rm -rf $SANDBOX_STATE_ROOT"
    exit 0
fi

# ============================== sites =======================================
if [[ "$COMMAND" == sites ]]; then

    if [[ "$REVERT" == true ]]; then
        log "Возвращаю плоскую раскладку /srv/sites"
        while IFS= read -r name; do
            [[ -n "$name" ]] || continue
            site="$(app_site_dir "$name")"
            [[ -L "$site/current" ]] || continue

            target="$site/$(readlink "$site/current")"
            [[ -d "$target" ]] || { warn "$name: current ведёт в никуда, пропускаю"; continue; }

            echo "   $name: $(basename "$target") → плоский каталог"
            if [[ "$DRY_RUN" != true ]]; then
                mv "$target" "$site.flat"
                safe_rm_rf "$SANDBOX_SITES_ROOT" "$site" || die "$name: откат прерван"
                mv "$site.flat" "$site"
            fi
        done < <(list_projects)
        echo
        log "Готово. Не забудь вернуть прежний Caddyfile из бэкапа."
        exit 0
    fi

    log "Перевожу /srv/sites на релизную раскладку"
    stamp="legacy-$(date +%Y%m%d-%H%M%S)"

    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        is_valid_app_name "$name" || { warn "$name: имя не проходит валидацию, пропускаю"; continue; }

        site="$(app_site_dir "$name")"
        [[ -d "$site" ]] || continue

        if [[ -L "$site/current" ]]; then
            echo "   $name: уже мигрирован, пропускаю"
            continue
        fi

        if [[ -d "$site/releases" ]]; then
            warn "$name: есть releases/, но нет current — разбирайся вручную"
            continue
        fi

        echo "   $name: → releases/$stamp"
        if [[ "$DRY_RUN" != true ]]; then
            mv "$site" "$site.migrating"
            mkdir -p "$site/releases"
            mv "$site.migrating" "$site/releases/$stamp"
            # Ссылка ОТНОСИТЕЛЬНАЯ: Caddy видит /srv/sites через bind-mount,
            # и абсолютный путь разрешился бы только по совпадению путей.
            ln -sfn "releases/$stamp" "$site/current"

            # Без записи в журнал ротация удалила бы этот релиз при первом
            # же деплое — вместе с возможностью откатиться на версию,
            # которая работала до миграции.
            mkdir -p "$(app_state_dir "$name")"
            record_release "$name" "$stamp"
        fi
    done < <(list_projects)

    echo
    log "Готово."
    echo "   Дальше: обнови Caddyfile (./update-infra.sh --caddy-only)."
    echo "   Откат этой фазы: migrate.sh sites --revert"
    exit 0
fi
