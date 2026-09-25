#!/usr/bin/env bash
# Administrative migration. Backups must be outside every Caddy mount.
SANDBOX_MIGRATION_BACKUPS="${SANDBOX_MIGRATION_BACKUPS:-/var/backups/sandbox}"

migration_preflight() {
    local name=$1 site
    require_valid_app_name "$name"
    site=$(app_site_dir "$name")
    require_plain_under "$SANDBOX_SITES_ROOT" "$site" || return 1
    [[ ! -e $site.flat && ! -L $site.flat && ! -e $site.migrating && ! -L $site.migrating ]] || {
        warn "$name: unexpected migration temporary path; untouched"
        return 1
    }
    if [[ -L $site/current ]]; then
        validate_site_layout "$site" || return 1
    elif [[ -e $site/releases || -L $site/releases || -e $site/current ]]; then
        warn "$name: ambiguous release layout"
        return 1
    fi
}

migration_backup() {
    local name=$1 site=$2 root real_sites
    root=$(readlink -m "$SANDBOX_MIGRATION_BACKUPS")
    real_sites=$(readlink -m "$SANDBOX_SITES_ROOT")
    [[ $root != / && $root != "$real_sites" && $root != "$real_sites"/* ]] || return 1
    local caddy_root
    caddy_root=$(readlink -m "${SANDBOX_CADDY_DIR:-/srv/caddy}")
    [[ $root != "$caddy_root" && $root != "$caddy_root"/* ]] || return 1
    assert_plain_path "$root/$name" || return 1
    private_dir "$root" && private_dir "$root/$name" || return 1
    MIGRATION_BACKUP=$(mktemp -d "$root/$name/migration.XXXXXXXX") || return 1
    (umask 077; tar -cpf "$MIGRATION_BACKUP/site.tar" -C "$site" .) || return 1
    tar -df "$MIGRATION_BACKUP/site.tar" -C "$site" || return 1
    private_dir "$MIGRATION_BACKUP/quarantine"
    log "$name: verified backup $MIGRATION_BACKUP/site.tar"
}

migrate_site() {
    local name=$1 site id release staging active dirty=false
    site=$(app_site_dir "$name")
    migration_preflight "$name" || return 1
    [[ -d $site ]] || return 0
    if [[ $REVERT == true ]]; then
        [[ -L $site/current ]] || return 0
        validate_public_tree "$site/$(readlink "$site/current")" || return 1
        [[ $DRY_RUN == true ]] && { log "$name: would revert safe current"; return 0; }
        mv "$site/$(readlink "$site/current")" "$site.flat"
        safe_rm_rf "$SANDBOX_SITES_ROOT" "$site" || return 1
        mv "$site.flat" "$site"
        log "$name: reverted safe release (private backup was not restored)"
        return 0
    fi

    if [[ -L $site/current ]]; then
        active=$(current_release_id "$name")
        # Preflight every release before any mutation or backup.
        for release in "$site/releases"/* "$site/releases"/.[!.]*; do
            [[ -e $release || -L $release ]] || continue
            require_plain_under "$site/releases" "$release" || return 1
            [[ -d $release ]] || return 1
            validate_public_tree "$release" >/dev/null 2>&1 || dirty=true
        done
        if [[ $dirty != true ]]; then
            if [[ $DRY_RUN != true ]]; then
                set_deploy_owner "$site" "$site/releases" "$site/current"
            fi
            log "$name: all releases safe"
            return 0
        fi
    fi
    [[ $DRY_RUN == true ]] && { log "$name: would back up, sanitize and quarantine unsafe releases"; return 0; }
    migration_backup "$name" "$site" || return 1
    prepare_state "$name" || return 1
    if [[ ! -L $site/current ]]; then
        staging=$(mktemp -d "$SANDBOX_SITES_ROOT/$name.migrating.XXXXXXXX")
        if ! copy_public_tree "$site" "$staging"; then
            safe_rm_rf "$SANDBOX_SITES_ROOT" "$staging"
            mv "$site" "$MIGRATION_BACKUP/quarantine/flat"
            warn "$name: unsafe site quarantined; offline; backup preserved"
            return 1
        fi
        id="legacy-$(date +%Y%m%d-%H%M%S)-${staging##*.}"
        mv "$site" "$MIGRATION_BACKUP/quarantine/flat"
        mkdir -p "$site/releases"
        chmod 755 "$site" "$site/releases"
        mv "$staging" "$site/releases/$id"
        ln -s "releases/$id" "$site/current"
        record_release "$name" "$id"
        set_deploy_owner "$site" "$site/releases" "$site/current" "$(app_state_dir "$name")" "$(releases_log "$name")"
    else
        for release in "$site/releases"/* "$site/releases"/.[!.]*; do
            [[ -d $release ]] || continue
            validate_public_tree "$release" >/dev/null 2>&1 && continue
            id=${release##*/}
            if [[ $id == "$active" ]]; then
                staging=$(mktemp -d "$site/releases/.sanitize.XXXXXXXX")
                if ! copy_public_tree "$release" "$staging"; then
                    safe_rm_rf "$SANDBOX_SITES_ROOT" "$staging"
                    rm -- "$site/current"
                    mv "$release" "$MIGRATION_BACKUP/quarantine/$id"
                    warn "$name: active release quarantined; offline"
                    return 1
                fi
                local replacement="legacy-safe-${staging##*.}"
                mv "$staging" "$site/releases/$replacement"
                ln -s "releases/$replacement" "$site/.current.migration"
                mv -T "$site/.current.migration" "$site/current"
                record_release "$name" "$replacement"
            fi
            mv "$release" "$MIGRATION_BACKUP/quarantine/$id"
        done
    fi
    log "$name: completed safe migration"
}
