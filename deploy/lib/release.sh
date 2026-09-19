#!/usr/bin/env bash
# Атомарная публикация статических релизов и откат (раздел 4 плана).
# Файл предназначен для source и требует lib/common.sh.
#
# Раскладка:
#   /srv/sites/<name>/releases/<sha>/   собранный вывод конкретного коммита
#   /srv/sites/<name>/current -> releases/<sha>   ОТНОСИТЕЛЬНЫЙ симлинк
#
# Симлинк относительный намеренно: Caddy видит /srv/sites через bind-mount,
# и абсолютный путь разрешился бы внутри контейнера только по совпадению
# путей снаружи и внутри.

SANDBOX_KEEP_RELEASES="${SANDBOX_KEEP_RELEASES:-5}"

# Файлы, которые никогда не попадают в раздачу, даже при publish_dir=.
SANDBOX_PUBLISH_EXCLUDES=(
    '.git' '.git/**' '.gitignore' '.gitattributes'
    '.env' '.env.*' '*.env'
    '.sandbox.conf'
    '*.pem' '*.key' 'id_rsa*' 'id_ed25519*'
)

release_root()    { printf '%s/releases\n' "$(app_site_dir "$1")"; }
release_dir()     { printf '%s/releases/%s\n' "$(app_site_dir "$1")" "$2"; }
current_link()    { printf '%s/current\n' "$(app_site_dir "$1")"; }
releases_log()    { printf '%s/releases.tsv\n' "$(app_state_dir "$1")"; }

# current_release_sha <name> — печатает sha текущего релиза, если он есть.
current_release_sha() {
    local link target
    link="$(current_link "$1")"
    [[ -L $link ]] || return 1
    target=$(readlink -- "$link") || return 1
    printf '%s\n' "${target##*/}"
}

# validate_release_output <dir> — минимальная проверка того, что публиковать
# вообще есть что. Пустой каталог означает провалившуюся сборку, которая
# не должна заменить работающий сайт.
validate_release_output() {
    local dir=$1
    [[ -d $dir ]] || { warn "каталог сборки не найден: $dir"; return 1; }
    if [[ -z $(find "$dir" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
        warn "каталог сборки пуст: $dir"
        return 1
    fi
    [[ -f "$dir/index.html" ]] || warn "в сборке нет index.html — сайт может отдавать 404 на /"
    return 0
}

# publish_release <name> <sha> <srcdir>
# Копирует сборку в releases/<sha> и атомарно переключает current.
# Любая ошибка до переключения оставляет предыдущий релиз нетронутым.
publish_release() {
    [[ $# -eq 3 ]] || return 2
    local name=$1 sha=$2 src=$3
    local site rel tmp_link excludes=()

    site="$(app_site_dir "$name")"
    rel="$(release_dir "$name" "$sha")"

    validate_release_output "$src"        || return 1
    assert_no_escaping_symlinks "$src"    || {
        warn "публикация отменена: в сборке есть симлинки за пределы каталога"
        return 1
    }

    mkdir -p "$(release_root "$name")"

    # Пересборка того же коммита должна давать чистый релиз.
    if [[ -e $rel ]]; then
        safe_rm_rf "$SANDBOX_SITES_ROOT" "$rel" || return 1
    fi
    mkdir -p "$rel"

    local pat
    for pat in "${SANDBOX_PUBLISH_EXCLUDES[@]}"; do
        excludes+=( --exclude="$pat" )
    done

    # Без -L: симлинки копируются как симлинки, а не разыменовываются.
    rsync -a --delete "${excludes[@]}" "$src/" "$rel/" || {
        warn "не удалось скопировать сборку в $rel"
        return 1
    }

    # rename(2) поверх существующего симлинка атомарен: читатель видит
    # либо старый релиз, либо новый, но никогда промежуточное состояние.
    tmp_link="$site/.current.$$.tmp"
    rm -f "$tmp_link"
    ln -s "releases/$sha" "$tmp_link"
    mv -T "$tmp_link" "$(current_link "$name")" || {
        rm -f "$tmp_link"
        warn "не удалось переключить current на $sha"
        return 1
    }

    record_release "$name" "$sha"
    prune_releases "$name" "$SANDBOX_KEEP_RELEASES"
}

# record_release <name> <sha> — дописывает релиз в журнал порядка.
record_release() {
    local name=$1 sha=$2 log
    log="$(releases_log "$name")"
    mkdir -p "$(dirname "$log")"
    printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sha" >> "$log"
}

# release_history <name> — sha успешных релизов, новые сверху, без повторов.
release_history() {
    local log
    log="$(releases_log "$1")"
    [[ -f $log ]] || return 0
    tac -- "$log" | cut -f2 | awk '!seen[$0]++'
}

# prune_releases <name> <keep>
# Оставляет <keep> последних успешных релизов. Текущий не удаляется
# никогда, даже если он выпал за пределы окна хранения.
prune_releases() {
    local name=$1 keep=$2 current sha dir
    local -a protected=()

    current=$(current_release_sha "$name" || true)
    [[ -n $current ]] && protected+=( "$current" )

    local n=0
    while IFS= read -r sha; do
        [[ -n $sha ]] || continue
        n=$((n + 1))
        (( n <= keep )) && protected+=( "$sha" )
    done < <(release_history "$name")

    local root
    root="$(release_root "$name")"
    [[ -d $root ]] || return 0

    for dir in "$root"/*; do
        [[ -d $dir ]] || continue
        sha="$(basename "$dir")"
        local keep_it=false p
        for p in "${protected[@]}"; do
            [[ $p == "$sha" ]] && { keep_it=true; break; }
        done
        [[ $keep_it == true ]] && continue
        safe_rm_rf "$SANDBOX_SITES_ROOT" "$dir" || true
    done
}

# rollback_release <name> [sha]
# Переключает current на предыдущий успешный релиз (или на указанный),
# ничего не пересобирая.
rollback_release() {
    local name=$1 want=${2-} current target="" sha site tmp_link
    site="$(app_site_dir "$name")"
    current=$(current_release_sha "$name" || true)

    if [[ -n $want ]]; then
        [[ -d "$(release_dir "$name" "$want")" ]] || {
            warn "релиз '$want' не найден среди сохранённых"
            return 1
        }
        target=$want
    else
        while IFS= read -r sha; do
            [[ -n $sha ]] || continue
            [[ $sha == "$current" ]] && continue
            [[ -d "$(release_dir "$name" "$sha")" ]] || continue
            target=$sha
            break
        done < <(release_history "$name")
    fi

    [[ -n $target ]] || {
        warn "нет предыдущего релиза, к которому можно откатиться"
        return 1
    }

    tmp_link="$site/.current.$$.tmp"
    rm -f "$tmp_link"
    ln -s "releases/$target" "$tmp_link"
    mv -T "$tmp_link" "$(current_link "$name")" || {
        rm -f "$tmp_link"
        return 1
    }

    # Откат — тоже смена активного релиза, поэтому он попадает в журнал:
    # иначе следующий откат вернулся бы на тот же релиз.
    record_release "$name" "$target"
    printf '%s\n' "$target"
}
