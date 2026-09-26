#!/usr/bin/env bash
# Docker user-namespace remapping: root inside a project container becomes an
# unprivileged UID on the host (dockremap, usually 100000+). A container
# escape through a kernel bug then lands as a nobody, not as root.
#
#   userns.sh enable [--dry-run]           set "userns-remap": "default" in
#                                          daemon.json (backup kept); restart
#                                          Docker yourself afterwards
#   userns.sh migrate-volumes [--dry-run]  copy named volumes from the old data
#                                          root into the remapped one, shifting
#                                          owners by the subordinate range.
#                                          Old volumes are left untouched;
#                                          volumes already present are skipped
#
# Remapping gives the daemon a separate data root (/var/lib/docker/<uid>.<gid>):
# images, networks and volumes created before it are not visible afterwards.
# Infrastructure that must stay in the host namespace opts out explicitly:
# the Caddy controller (Docker socket) and the build worker (already an
# unprivileged UID without capabilities, writing to a deploy-owned tree).
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=deploy/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

DAEMON_JSON=${SANDBOX_DOCKER_DAEMON_JSON:-/etc/docker/daemon.json}
DOCKER_ROOT=${SANDBOX_DOCKER_ROOT:-/var/lib/docker}
SUBUID_FILE=${SANDBOX_SUBUID_FILE:-/etc/subuid}
SUBGID_FILE=${SANDBOX_SUBGID_FILE:-/etc/subgid}

COMMAND=${1-}
DRY=false
[[ ${2-} == --dry-run ]] && DRY=true
[[ $# -le 2 && ( $# -lt 2 || $DRY == true ) ]] || COMMAND=usage

enable_remap() {
    python3 - "$DAEMON_JSON" "$DRY" <<'PY'
import json, os, shutil, sys, tempfile, time
path, dry = sys.argv[1], sys.argv[2] == 'true'
config = {}
if os.path.exists(path):
    with open(path) as f:
        text = f.read()
    config = json.loads(text) if text.strip() else {}
current = config.get('userns-remap')
if current == 'default':
    print(f'   {path}: userns-remap already default')
    sys.exit(0)
if current:
    sys.exit(f'!! {path}: userns-remap is already set to {current!r}; not changing it')
config['userns-remap'] = 'default'
if dry:
    print(f'   would set userns-remap=default in {path}')
    sys.exit(0)
os.makedirs(os.path.dirname(path), exist_ok=True)
if os.path.exists(path):
    backup = f'{path}.bak-{time.strftime("%Y%m%d-%H%M%S")}'
    shutil.copy2(path, backup)
    print(f'   backup: {backup}')
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
with os.fdopen(fd, 'w') as f:
    json.dump(config, f, indent=2)
    f.write('\n')
os.chmod(tmp, 0o644)
os.replace(tmp, path)
print(f'   {path}: userns-remap=default; restart Docker to apply')
PY
}

# range_start <file> — first subordinate id of dockremap.
range_start() {
    local line
    line=$(grep -m1 '^dockremap:' "$1") || die "dockremap has no range in $1: enable remapping and restart Docker first"
    line=${line#dockremap:}
    printf '%s\n' "${line%%:*}"
}

migrate_volumes() {
    local uid gid new_root vol
    uid=$(range_start "$SUBUID_FILE")
    gid=$(range_start "$SUBGID_FILE")
    new_root="$DOCKER_ROOT/$uid.$gid/volumes"
    [[ -d $DOCKER_ROOT/volumes ]] || { log "нет томов в $DOCKER_ROOT/volumes"; return 0; }
    [[ -d $new_root ]] || die "$new_root не найден: Docker ещё не запускался с remap"
    log "Переношу тома: $DOCKER_ROOT/volumes → $new_root (владельцы +$uid/+$gid)"
    for vol in "$DOCKER_ROOT"/volumes/*/; do
        vol=$(basename "$vol")
        [[ -d $DOCKER_ROOT/volumes/$vol/_data ]] || continue
        if [[ -e $new_root/$vol ]]; then
            echo "   $vol: уже есть в новом корне, пропускаю"
            continue
        fi
        if [[ $DRY == true ]]; then
            echo "   would copy $vol"
            continue
        fi
        # Copied into a temporary name first: an interrupted copy never looks
        # like a finished volume.
        cp -a "$DOCKER_ROOT/volumes/$vol" "$new_root/.$vol.migrating"
        python3 - "$new_root/.$vol.migrating" "$uid" "$gid" <<'PY'
import os, sys
root, du, dg = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
def shift(path):
    st = os.lstat(path)
    # Only ids inside the mapped range (0..65535) have a counterpart.
    uid = st.st_uid + du if st.st_uid < 65536 else st.st_uid
    gid = st.st_gid + dg if st.st_gid < 65536 else st.st_gid
    os.lchown(path, uid, gid)
for base, dirs, files in os.walk(root):
    for name in dirs + files:
        shift(os.path.join(base, name))
data = os.path.join(root, '_data')
shift(data)
# The volume directory itself is owned by the remapped root, like new ones.
os.lchown(root, du, dg)
PY
        mv -T "$new_root/.$vol.migrating" "$new_root/$vol"
        echo "   $vol: перенесён"
    done
    echo "   Старые тома остались в $DOCKER_ROOT/volumes; удалить их можно после проверки."
    echo "   Перезапусти Docker, чтобы он увидел перенесённые тома."
}

case $COMMAND in
    enable) enable_remap ;;
    migrate-volumes) migrate_volumes ;;
    *) die 'Usage: userns.sh enable|migrate-volumes [--dry-run]' ;;
esac
