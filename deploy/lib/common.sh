#!/usr/bin/env bash
# Общие хелперы sandbox-инфраструктуры. Файл предназначен для source,
# а не для прямого запуска.
#
# Корни каталогов переопределяются переменными окружения — это нужно
# тестам, чтобы никогда не работать с реальным /srv.

SANDBOX_GIT_ROOT="${SANDBOX_GIT_ROOT:-/srv/git}"
SANDBOX_APPS_ROOT="${SANDBOX_APPS_ROOT:-/srv/apps}"
SANDBOX_SITES_ROOT="${SANDBOX_SITES_ROOT:-/srv/sites}"
SANDBOX_STATE_ROOT="${SANDBOX_STATE_ROOT:-/srv/state}"
SANDBOX_CONF="${SANDBOX_CONF:-/srv/sandbox.conf}"

# --- вывод -----------------------------------------------------------------

log()  { printf '==> %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }
die()  { printf '!! %s\n' "$*" >&2; exit 1; }

# --- конфиг ----------------------------------------------------------------

# read_conf_value <файл> <ключ>
# Читает строку вида KEY=value. Намеренно без source: файл конфига не должен
# иметь возможности выполнить произвольный код.
read_conf_value() {
    local file=$1 key=$2 line value
    [[ -r $file ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == "$key="* ]] || continue
        value=${line#"$key="}
        value=${value%$'\r'}
        # снимаем обрамляющие кавычки, если они есть
        [[ $value == \"*\" ]] && value=${value:1:-1}
        [[ $value == \'*\' ]] && value=${value:1:-1}
        printf '%s\n' "$value"
        return 0
    done < "$file"
    return 1
}

# Домен и SSH-хост задаются один раз в /srv/sandbox.conf при установке,
# чтобы скрипты не печатали плейсхолдер sandbox.example.com.
SANDBOX_DOMAIN="${SANDBOX_DOMAIN:-$(read_conf_value "$SANDBOX_CONF" SANDBOX_DOMAIN || echo 'sandbox.example.com')}"
SANDBOX_SSH_HOST="${SANDBOX_SSH_HOST:-$(read_conf_value "$SANDBOX_CONF" SANDBOX_SSH_HOST || echo "$SANDBOX_DOMAIN")}"

# --- имена проектов --------------------------------------------------------

# Правило: 1–63 символа, строчные ASCII-буквы, цифры и дефис;
# первый и последний символ — буква или цифра.
#
# Имя попадает и в путь файловой системы, и в имя поддомена, и в аргумент
# SSH-команды, поэтому проверка намеренно строгая: всё, что не входит в
# набор явно, отвергается.
is_valid_app_name() {
    [[ $# -eq 1 ]] || return 2
    local name=$1
    (( ${#name} >= 1 && ${#name} <= 63 )) || return 1
    # Якоря ^...$ в bash =~ не переносятся через строку, поэтому перевод
    # строки внутри имени дополнительно отсекается отдельной проверкой.
    [[ $name == *$'\n'* ]] && return 1
    [[ $name =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
    return 0
}

require_valid_app_name() {
    local name=${1-}
    is_valid_app_name "$name" && return 0
    die "недопустимое имя проекта: '${name}'
   Разрешено: 1–63 символа, строчные латинские буквы, цифры и дефис,
   первый и последний символ — буква или цифра. Например: my-app"
}

# --- пути ------------------------------------------------------------------

# resolve_under <корень> <путь>
# Печатает канонический путь, если он лежит строго внутри корня.
# Возвращает ошибку, если путь совпадает с корнем или выходит за его пределы,
# в том числе через '..' или симлинк.
resolve_under() {
    [[ $# -eq 2 ]] || return 2
    local root=$1 path=$2 rroot rpath

    # readlink -m раскрывает символические ссылки и '..' и не требует,
    # чтобы путь существовал — это важно для идемпотентного удаления.
    rroot=$(readlink -m -- "$root") || return 1
    rpath=$(readlink -m -- "$path") || return 1

    [[ -n $rroot && $rroot != "/" ]] || return 1
    [[ $rpath != "$rroot" ]]         || return 1
    [[ $rpath == "$rroot"/* ]]       || return 1

    printf '%s\n' "$rpath"
}

# safe_rm_rf <корень> <путь>
# Удаляет путь только если он строго внутри корня. Симлинк в качестве
# цели отвергается: иначе удаление пошло бы по ссылке наружу либо оставило
# висящую ссылку.
safe_rm_rf() {
    [[ $# -eq 2 ]] || return 2
    local root=$1 path=$2 resolved

    if [[ -L $path ]]; then
        warn "отказ удалять '$path': это символическая ссылка"
        return 1
    fi

    resolved=$(resolve_under "$root" "$path") || {
        warn "отказ удалять '$path': путь вне '$root'"
        return 1
    }

    rm -rf -- "$resolved"
}

# --- пути проекта ----------------------------------------------------------

app_repo_dir()  { printf '%s/%s.git\n' "$SANDBOX_GIT_ROOT"   "$1"; }
app_work_dir()  { printf '%s/%s\n'     "$SANDBOX_APPS_ROOT"  "$1"; }
app_site_dir()  { printf '%s/%s\n'     "$SANDBOX_SITES_ROOT" "$1"; }
app_state_dir() { printf '%s/%s\n'     "$SANDBOX_STATE_ROOT" "$1"; }

# Lock-файлы не удаляются вместе с проектом: ожидающие процессы должны
# всегда блокировать один inode, в том числе после remove/new-app.
app_lock_file() { printf '%s/.locks/%s.lock\n' "$SANDBOX_STATE_ROOT" "$1"; }
lock_app() {
    require_valid_app_name "$1"
    command -v flock >/dev/null 2>&1 || die "flock обязателен (пакет util-linux)"
    assert_plain_path "$SANDBOX_STATE_ROOT/.locks/$1.lock" || die "unsafe lock path"
    mkdir -p "$SANDBOX_STATE_ROOT/.locks"
    chmod 750 "$SANDBOX_STATE_ROOT/.locks"
    (umask 027; touch "$(app_lock_file "$1")")
    set_deploy_owner "$SANDBOX_STATE_ROOT/.locks" "$(app_lock_file "$1")"
    exec 9>"$(app_lock_file "$1")"
    flock -w "${SANDBOX_LOCK_TIMEOUT:-600}" 9 \
        || die "[$1] другая операция над проектом уже выполняется"
}

# При запуске установщика/миграции от root новые файлы принадлежат deploy.
# В локальных тестах без root владельцем остаётся текущий пользователь.
set_deploy_owner() {
    if (( EUID == 0 )); then
        chown -h "${SANDBOX_DEPLOY_OWNER:-deploy:deploy}" "$@"
    fi
}

# Reject links in every component, including dangling links. This is a path
# guard, not a defence against concurrent hostile processes with the same UID.
assert_plain_path() {
    local path=$1 part cursor=""
    [[ $path == /* && $path != *'/../'* && $path != */.. ]] || return 1
    local -a parts
    IFS=/ read -r -a parts <<< "$path"
    for part in "${parts[@]}"; do
        [[ -n $part && $part != . ]] || continue
        cursor="$cursor/$part"
        [[ ! -L $cursor ]] || { warn "symbolic link forbidden: $cursor"; return 1; }
    done
}

require_plain_under() {
    resolve_under "$1" "$2" >/dev/null && assert_plain_path "$2"
}

is_log_sha() { [[ ${1-} =~ ^[a-f0-9]{1,64}$ ]]; }
is_release_id() { [[ ${1-} =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$ ]]; }

private_dir() {
    assert_plain_path "$1" || return 1
    mkdir -p -- "$1" && chmod 700 -- "$1"
}

# Atomic replacement also repairs a pre-existing 0644 destination.
install_private() {
    local src=$1 dst=$2 tmp
    assert_plain_path "$src" && assert_plain_path "$dst" || return 1
    [[ -f $src ]] || return 1
    tmp=$(mktemp "${dst}.XXXXXX") || return 1
    if cat -- "$src" > "$tmp" && chmod 600 "$tmp" && mv -T -- "$tmp" "$dst"; then
        return 0
    fi
    rm -f -- "$tmp"
    return 1
}

prepare_state() {
    local state
    state=$(app_state_dir "$1")
    require_plain_under "$SANDBOX_STATE_ROOT" "$state" || return 1
    private_dir "$state" && private_dir "$state/logs"
}

private_file() {
    assert_plain_path "$1" || return 1
    [[ ! -e $1 || -f $1 ]] || return 1
    [[ ! -e $1 || $(stat -c %h "$1") == 1 ]] || return 1
    (umask 077; touch -- "$1") && chmod 600 -- "$1"
}

# Readers (status) never acquire this lock. Writers replace the whole journal.
append_private_line() {
    local path=$1 line=$2 tmp
    private_file "$path" || return 1
    tmp=$(mktemp "${path}.XXXXXXXX") || return 1
    if cat "$path" > "$tmp" && printf '%s\n' "$line" >> "$tmp" && set_deploy_owner "$tmp" && mv -T "$tmp" "$path"; then return 0; fi
    rm -f "$tmp"
    return 1
}
