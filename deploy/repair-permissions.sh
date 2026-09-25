#!/usr/bin/env bash
# Idempotent private-state repair; never traverses application data/volumes.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=deploy/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
DRY=false
[[ ${1-} != --dry-run ]] || { DRY=true; shift; }
[[ $# == 0 ]] || die 'Usage: repair-permissions.sh [--dry-run]'
repair() {
    local path=$1 mode=$2
    assert_plain_path "$path" || die "unsafe private path: $path"
    [[ -e $path ]] || return 0
    if [[ $DRY == true ]]; then
        printf 'would chmod %s %s\n' "$mode" "$path"
    else
        chmod "$mode" "$path"
    fi
}
# Preflight the entire private namespace before touching modes.
assert_plain_path "$SANDBOX_STATE_ROOT" || die 'unsafe state root'
if [[ -d $SANDBOX_STATE_ROOT ]]; then
    while IFS= read -r -d '' path; do
        [[ ! -L $path ]] || die "state contains symlink: $path (repair manually)"
    done < <(find "$SANDBOX_STATE_ROOT" -path '*/build' -prune -o -type l -print0)
fi
# Compose, run by deploy from hooks, must read the Caddy .env; see bootstrap.sh.
caddy_env="${SANDBOX_CADDY_DIR:-/srv/caddy}/.env"
repair "$caddy_env" 640
if [[ -e $caddy_env ]] && (( EUID == 0 )); then
    deploy_group=${SANDBOX_DEPLOY_OWNER:-deploy:deploy}
    deploy_group=${deploy_group#*:}
    if [[ $DRY == true ]]; then
        printf 'would chown root:%s %s\n' "$deploy_group" "$caddy_env"
    else
        chown -h "root:$deploy_group" "$caddy_env"
    fi
fi
for state in "$SANDBOX_STATE_ROOT"/*; do
    [[ -d $state ]] || continue
    name=${state##*/}
    require_valid_app_name "$name"
    [[ $DRY == true ]] || lock_app "$name"
    repair "$state" 700
    repair "$state/logs" 700
    for path in "$state"/config "$state"/env "$state"/build-env "$state"/*.tsv "$state"/docker-active-sha "$state"/logs/*; do
        [[ -e $path ]] || continue
        [[ -f $path ]] || die "unexpected private file: $path"
        repair "$path" 600
        [[ $DRY == true ]] || set_deploy_owner "$path"
    done
    [[ $DRY == true ]] || set_deploy_owner "$state" "$state/logs"
done
