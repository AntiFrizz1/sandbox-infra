#!/usr/bin/env bash
# Определение типа проекта, пер-проектный конфиг и проверка каталога
# публикации. Файл предназначен для source и требует lib/common.sh.
#
# Тип проекта раньше определялся заново в четырёх местах (hook.sh,
# stop-app.sh, remove-app.sh, клиент) и успел разъехаться. Здесь он
# определяется один раз.

# Порядок важен: при нескольких файлах побеждает первый найденный.
SANDBOX_COMPOSE_FILES=(docker-compose.yml docker-compose.yaml compose.yml compose.yaml)

# find_compose_file <dir> — печатает имя compose-файла проекта, если он есть.
find_compose_file() {
    local dir=$1 f
    for f in "${SANDBOX_COMPOSE_FILES[@]}"; do
        if [[ -f "$dir/$f" ]]; then
            printf '%s\n' "$f"
            return 0
        fi
    done
    return 1
}

# detect_project_type <dir> — docker | dockerfile-only | node | static
#
# dockerfile-only — отдельный тип, а не ошибка на месте: раньше одинокий
# Dockerfile уводил в `docker compose up -d --build`, который падал с
# "no configuration file provided: not found". Вызывающий код решает, что
# с этим делать, и печатает внятное объяснение.
detect_project_type() {
    local dir=$1
    if find_compose_file "$dir" >/dev/null 2>&1; then
        printf 'docker\n'
    elif [[ -f "$dir/Dockerfile" ]]; then
        printf 'dockerfile-only\n'
    elif [[ -f "$dir/package.json" ]]; then
        printf 'node\n'
    else
        printf 'static\n'
    fi
}

# validate_publish_dir <workdir> <publish_dir>
# Печатает канонический путь публикуемого каталога.
# Отвергает пустое значение, абсолютные пути, выход за пределы репозитория
# через '..' или симлинк, а также несуществующий путь и не-каталог.
validate_publish_dir() {
    [[ $# -eq 2 ]] || return 2
    local workdir=$1 publish_dir=$2 resolved

    [[ -n $publish_dir ]] || { warn "publish_dir не задан"; return 1; }
    [[ $publish_dir != /* ]] || {
        warn "publish_dir должен быть относительным путём, получено: '$publish_dir'"
        return 1
    }

    if [[ $publish_dir == "." ]]; then
        # Публикация всего репозитория допустима только явным указанием '.'
        # — это путь для проектов, мигрировавших со старой схемы.
        resolved=$(readlink -m -- "$workdir")
    else
        resolved=$(resolve_under "$workdir" "$workdir/$publish_dir") || {
            warn "publish_dir '$publish_dir' выходит за пределы репозитория"
            return 1
        }
    fi

    [[ -d $resolved ]] || {
        warn "каталог публикации не найден: '$publish_dir' (ожидался $resolved)"
        return 1
    }

    printf '%s\n' "$resolved"
}

# assert_no_escaping_symlinks <dir>
# Проваливается, если внутри каталога есть символическая ссылка, ведущая
# за его пределы. Без этой проверки ссылка на серверный секрет уехала бы
# в раздачу вместе с сайтом.
assert_no_escaping_symlinks() {
    [[ $# -eq 1 ]] || return 2
    local dir=$1 root link target rc=0
    root=$(readlink -m -- "$dir") || return 1

    while IFS= read -r -d '' link; do
        target=$(readlink -m -- "$link") || { rc=1; continue; }
        if [[ $target != "$root" && $target != "$root"/* ]]; then
            warn "симлинк уводит за пределы публикуемого каталога: ${link#"$root"/} -> $target"
            rc=1
        fi
    done < <(find "$root" -type l -print0)

    return $rc
}

# --- пер-проектный конфиг --------------------------------------------------

PROJECT_TYPE=""
PROJECT_PUBLISH_DIR=""
PROJECT_BUILD_CMD=""
PROJECT_SPA=""
PROJECT_HEALTH_URL=""
PROJECT_COMPOSE_FILE=""
PROJECT_CONFIG_SOURCE=""

SANDBOX_PROJECT_CONF_NAME=".sandbox.conf"

# load_project_config <app-name> <workdir>
#
# Источники, в порядке убывания приоритета:
#   1. <workdir>/.sandbox.conf  — конфиг в репозитории, им владеет разработчик
#   2. /srv/state/<name>/config — серверный конфиг, им владеет админ VPS
#      (именно его создаёт миграция для проектов со старой схемой)
#   3. автоопределение по файлам репозитория
#
# Незаданные ключи добираются автоопределением, поэтому конфиг может
# переопределять только то, что нужно.
load_project_config() {
    [[ $# -eq 2 ]] || return 2
    local name=$1 workdir=$2
    local repo_conf="$workdir/$SANDBOX_PROJECT_CONF_NAME"
    local state_conf src=""

    state_conf="$(app_state_dir "$name")/config"

    PROJECT_TYPE=""; PROJECT_PUBLISH_DIR=""; PROJECT_BUILD_CMD=""
    PROJECT_SPA=""; PROJECT_HEALTH_URL=""; PROJECT_COMPOSE_FILE=""
    PROJECT_CONFIG_SOURCE=""

    if [[ -f $repo_conf ]]; then
        src=$repo_conf
    elif [[ -f $state_conf ]]; then
        src=$state_conf
    fi

    if [[ -n $src ]]; then
        # read_conf_value намеренно не использует source: конфиг не должен
        # иметь возможности выполнить код на сервере.
        PROJECT_TYPE=$(read_conf_value       "$src" type        || true)
        PROJECT_PUBLISH_DIR=$(read_conf_value "$src" publish_dir || true)
        PROJECT_BUILD_CMD=$(read_conf_value  "$src" build_cmd   || true)
        PROJECT_SPA=$(read_conf_value        "$src" spa         || true)
        # SC2034: читается вызывающими скриптами, а не внутри библиотеки.
        # shellcheck disable=SC2034
        PROJECT_HEALTH_URL=$(read_conf_value "$src" health_url  || true)
        PROJECT_CONFIG_SOURCE=$src
    else
        PROJECT_CONFIG_SOURCE="автоопределение"
    fi

    if [[ -z $PROJECT_TYPE ]]; then
        PROJECT_TYPE=$(detect_project_type "$workdir")
    fi

    case "$PROJECT_TYPE" in
        static|node|docker|dockerfile-only) ;;
        *)
            warn "неизвестный type='$PROJECT_TYPE' в $PROJECT_CONFIG_SOURCE (ожидается static, node или docker)"
            return 1
            ;;
    esac

    # Дефолты по типу. Ключевое отличие от старого поведения: plain-static
    # больше не публикует корень репозитория — только public/.
    case "$PROJECT_TYPE" in
        static)
            : "${PROJECT_PUBLISH_DIR:=public}"
            ;;
        node)
            : "${PROJECT_PUBLISH_DIR:=dist}"
            : "${PROJECT_BUILD_CMD:=npm run build}"
            ;;
        docker)
            # shellcheck disable=SC2034  # читается вызывающими скриптами
            PROJECT_COMPOSE_FILE=$(find_compose_file "$workdir" || true)
            ;;
    esac

    : "${PROJECT_SPA:=false}"

    case "$PROJECT_SPA" in
        true|false) ;;
        *)
            warn "spa должен быть true или false, получено '$PROJECT_SPA' в $PROJECT_CONFIG_SOURCE"
            return 1
            ;;
    esac

    # Для собираемых типов каталог публикации может ещё не существовать
    # (его создаст сборка), поэтому здесь проверяется только форма пути.
    if [[ $PROJECT_TYPE == static || $PROJECT_TYPE == node ]]; then
        if [[ $PROJECT_PUBLISH_DIR == /* || $PROJECT_PUBLISH_DIR == ".." || \
              $PROJECT_PUBLISH_DIR == "../"* || $PROJECT_PUBLISH_DIR == *"/.."* || \
              $PROJECT_PUBLISH_DIR == *"/../"* ]]; then
            warn "publish_dir '$PROJECT_PUBLISH_DIR' выходит за пределы репозитория ($PROJECT_CONFIG_SOURCE)"
            return 1
        fi
    fi

    return 0
}
