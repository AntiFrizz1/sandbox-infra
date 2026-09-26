#!/usr/bin/env bash
# Installs a reviewed image from an archive instead of a registry.
#
#   load-image.sh <archive.tar> <sha256-of-archive> [--caddy] [--worker]
#
# The archive is made on the build machine by scripts/export-image.sh, which
# prints its SHA-256 and records it in the release manifest. Here the checksum
# is verified before `docker load`; the loaded image is then referred to by its
# image ID, which cannot be moved the way a tag can. The ID is printed on
# stdout. With --caddy it is also written to SANDBOX_CADDY_IMAGE in the Caddy
# .env (apply with `cd /srv/caddy && docker compose up -d`); with --worker it
# becomes image= in the default worker policy used by every Node project
# without its own policy.
#
# Load after userns-remap is enabled: remapping switches Docker to a separate
# data root, and images loaded before it are not visible afterwards.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=deploy/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() { die 'Usage: load-image.sh <archive.tar> <sha256> [--caddy] [--worker]'; }
ARCHIVE=${1-}
EXPECTED=${2-}
(( $# >= 2 )) || usage
shift 2
CADDY=false
WORKER=false
for opt in "$@"; do
    case $opt in
        --caddy) CADDY=true ;;
        --worker) WORKER=true ;;
        *) usage ;;
    esac
done
[[ -n $ARCHIVE && $EXPECTED =~ ^[a-f0-9]{64}$ ]] || usage
WORKER_POLICY="${SANDBOX_POLICY_DEFAULTS:-/etc/sandbox/defaults}/worker.conf"
# Checked before loading, so a missing policy does not leave a half-done step.
[[ $WORKER == false || -f $WORKER_POLICY ]] \
    || die "нет $WORKER_POLICY — сначала установи политики по умолчанию (update-infra.sh или bootstrap.sh)"
[[ -f $ARCHIVE ]] || die "архив не найден: $ARCHIVE"

actual=$(sha256sum -- "$ARCHIVE" | cut -d' ' -f1)
[[ $actual == "$EXPECTED" ]] || die "SHA-256 архива не совпадает: ожидался $EXPECTED, получен $actual — не загружаю"
log "SHA-256 архива совпадает" >&2

out=$(docker load -i "$ARCHIVE") || die "docker load не удался"
mapfile -t refs < <(sed -n 's/^Loaded image\( ID\)\?: //p' <<< "$out")
(( ${#refs[@]} == 1 )) || die "в архиве должен быть ровно один образ, найдено: ${#refs[@]}"
id=$(docker image inspect --format '{{.Id}}' "${refs[0]}") || die "загруженный образ не найден"
is_pinned_image "$id" || die "неожиданный ID образа: $id"
log "загружен ${refs[0]} → $id" >&2

if [[ $CADDY == true ]]; then
    envfile="${SANDBOX_CADDY_DIR:-/srv/caddy}/.env"
    set_env_value "$envfile" SANDBOX_CADDY_IMAGE "$id" || die "не удалось записать SANDBOX_CADDY_IMAGE в $envfile"
    log "SANDBOX_CADDY_IMAGE=$id записан в $envfile; применить: cd ${SANDBOX_CADDY_DIR:-/srv/caddy} && docker compose up -d" >&2
fi
if [[ $WORKER == true ]]; then
    set_env_value "$WORKER_POLICY" image "$id" || die "не удалось записать image= в $WORKER_POLICY"
    log "image=$id записан в $WORKER_POLICY — его используют все Node-проекты без своей политики" >&2
fi
printf '%s\n' "$id"
