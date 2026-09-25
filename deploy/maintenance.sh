#!/usr/bin/env bash
# Daily retention (sandbox-maintenance.timer). Never touches current or any
# published release, Docker volumes, running containers or application data.
#
#   - completed deploy logs, via cleanup-app.sh;
#   - leftovers of interrupted deploys (staging, build trees, temp files),
#     only while the project lock is free;
#   - `git gc --auto` in bare repositories;
#   - Docker build cache and dangling images older than a week;
#   - migration backups beyond the newest SANDBOX_BACKUP_KEEP that are also
#     older than SANDBOX_BACKUP_MAX_AGE_DAYS.
#
# As root it prunes backups (root-owned) and re-runs itself as the deploy
# user for everything else, so no project file becomes root-owned.
# Exit status 2 means free space is below SANDBOX_ALERT_FREE_MB: the unit
# fails and shows up in `systemctl --failed` and the journal.
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=deploy/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

SANDBOX_MIGRATION_BACKUPS="${SANDBOX_MIGRATION_BACKUPS:-/var/backups/sandbox}"
SANDBOX_BACKUP_KEEP="${SANDBOX_BACKUP_KEEP:-3}"
SANDBOX_BACKUP_MAX_AGE_DAYS="${SANDBOX_BACKUP_MAX_AGE_DAYS:-30}"
SANDBOX_ALERT_FREE_MB="${SANDBOX_ALERT_FREE_MB:-2048}"
SANDBOX_PRUNE_DOCKER="${SANDBOX_PRUNE_DOCKER:-true}"

DRY=false
PROJECTS_ONLY=false
while (( $# )); do
    case $1 in
        --dry-run) DRY=true ;;
        --projects-only) PROJECTS_ONLY=true ;;
        *) die 'Usage: maintenance.sh [--dry-run]' ;;
    esac
    shift
done

# act <description> <command...> — runs the command, or only reports it.
act() {
    local what=$1
    shift
    if [[ $DRY == true ]]; then
        printf '   would %s\n' "$what"
    else
        printf '   %s\n' "$what"
        "$@"
    fi
}

prune_backups() {
    local project dir age_days now
    [[ -d $SANDBOX_MIGRATION_BACKUPS && -w $SANDBOX_MIGRATION_BACKUPS ]] || return 0
    assert_plain_path "$SANDBOX_MIGRATION_BACKUPS" || { warn 'unsafe backup root'; return 1; }
    now=$(date +%s)
    log "Бэкапы миграции: храню последние $SANDBOX_BACKUP_KEEP и все моложе $SANDBOX_BACKUP_MAX_AGE_DAYS дн."
    for project in "$SANDBOX_MIGRATION_BACKUPS"/*/; do
        [[ -d $project ]] || continue
        local -a dirs=()
        mapfile -t dirs < <(find "$project" -mindepth 1 -maxdepth 1 -type d -name 'migration.*' \
            -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)
        for dir in "${dirs[@]:$SANDBOX_BACKUP_KEEP}"; do
            age_days=$(( (now - $(stat -c %Y "$dir")) / 86400 ))
            (( age_days > SANDBOX_BACKUP_MAX_AGE_DAYS )) || continue
            act "remove backup $dir (${age_days} дн.)" safe_rm_rf "$SANDBOX_MIGRATION_BACKUPS" "$dir"
        done
    done
}

# Leftovers that only exist while a deploy runs. Called under the project lock.
remove_orphans() {
    local name=$1 site state path
    site=$(app_site_dir "$name")
    state=$(app_state_dir "$name")
    for path in "$site"/releases/.[!.]*; do
        [[ -e $path || -L $path ]] || continue
        act "remove staging $path" safe_rm_rf "$SANDBOX_SITES_ROOT" "$path"
    done
    for path in "$site"/.current.*; do
        [[ -L $path ]] || continue
        act "remove temporary link $path" rm -f -- "$path"
    done
    for path in "$state/build" "$state/worker-output" "$state"/worker-output.limit.* \
            "$state"/deploys.tsv.* "$state"/releases.tsv.* "$state"/.docker-active-sha.* \
            "$state"/env.*; do
        [[ -e $path || -L $path ]] || continue
        act "remove leftover $path" safe_rm_rf "$SANDBOX_STATE_ROOT" "$path"
    done
}

project_maintenance() {
    local repo name dry_flag=()
    [[ $DRY == true ]] && dry_flag=(--dry-run)
    for repo in "$SANDBOX_GIT_ROOT"/*.git; do
        [[ -d $repo ]] || continue
        name=$(basename "$repo" .git)
        is_valid_app_name "$name" || { warn "$name: имя не проходит валидацию, пропускаю"; continue; }
        log "[$name]"
        if [[ -d $(app_state_dir "$name")/logs ]]; then
            SANDBOX_LOCK_TIMEOUT=0 bash "$SCRIPT_DIR/cleanup-app.sh" "$name" "${dry_flag[@]}" \
                || warn "[$name] очистка логов пропущена (проект занят или состояние небезопасно)"
        fi
        # A busy project is skipped, never waited for: a deploy may run for minutes.
        ( SANDBOX_LOCK_TIMEOUT=0 lock_app "$name" 2>/dev/null && remove_orphans "$name" ) \
            || warn "[$name] идёт операция — остатки деплоя не трогаю"
        act "git gc --auto $repo" git --git-dir="$repo" gc --auto --quiet \
            || warn "[$name] git gc не удался"
    done
    if [[ $SANDBOX_PRUNE_DOCKER == true ]] && docker info >/dev/null 2>&1; then
        log "Docker: кеш сборки и висячие образы старше недели"
        act 'prune build cache' docker builder prune -f --filter until=168h >/dev/null
        act 'prune dangling images' docker image prune -f --filter until=168h >/dev/null
    fi
}

check_free_space() {
    local path free rc=0
    for path in "$SANDBOX_STATE_ROOT" "$SANDBOX_SITES_ROOT" "$SANDBOX_GIT_ROOT"; do
        [[ -d $path ]] || continue
        free=$(free_mb "$path")
        [[ $free =~ ^[0-9]+$ ]] || continue
        if (( free < SANDBOX_ALERT_FREE_MB )); then
            warn "мало места: ${free} МБ свободно на разделе с $path (порог $SANDBOX_ALERT_FREE_MB)"
            rc=2
        fi
    done
    return "$rc"
}

status=0
if [[ $PROJECTS_ONLY == true ]]; then
    project_maintenance
    exit 0
fi
prune_backups || status=1
if (( EUID == 0 )); then
    deploy_user=${SANDBOX_DEPLOY_OWNER:-deploy:deploy}
    deploy_user=${deploy_user%%:*}
    args=(--projects-only)
    [[ $DRY == true ]] && args+=(--dry-run)
    runuser -u "$deploy_user" -- "$SCRIPT_DIR/maintenance.sh" "${args[@]}" || status=1
else
    project_maintenance
fi
check_free_space || status=2
exit "$status"
