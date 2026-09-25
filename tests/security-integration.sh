#!/usr/bin/env bash
# Mandatory release gate; missing Docker is a FAILURE, never a skip.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SB=$(mktemp -d /tmp/sandbox-integration.XXXXXXXX)
CID=""
trap '[[ -z $CID ]] || docker rm -f "$CID" >/dev/null; rm -rf "$SB"' EXIT
IMAGE=${SANDBOX_TEST_CADDY_IMAGE:-caddy@sha256:14a9c00d4e833ebc2b65d36515b37bde3b73f0b323a2663aaafc88953d8c4e3f}
docker info >/dev/null
# Fixtures are written world-readable; code under test runs with the hook's umask.
umask 022
export SANDBOX_CADDY_SPA_DIR="$SB/spa" SANDBOX_SITES_MOUNT=/srv/sites
# shellcheck source=deploy/lib/common.sh
source "$ROOT/deploy/lib/common.sh"
export SANDBOX_GIT_ROOT="$SB/git" SANDBOX_STATE_ROOT="$SB/state"
export SANDBOX_SITES_ROOT="$SB/sites" SANDBOX_MIGRATION_BACKUPS="$SB/backups"
# shellcheck source=deploy/lib/project.sh
source "$ROOT/deploy/lib/project.sh"
# shellcheck source=deploy/lib/release.sh
source "$ROOT/deploy/lib/release.sh"
# shellcheck source=deploy/lib/caddy.sh
source "$ROOT/deploy/lib/caddy.sh"
mkdir -p "$SB/sites/demo" "$SB/git/demo.git" "$SB/private" "$SB/spa"
echo PUBLIC > "$SB/sites/demo/index.html"
echo SYNTHETIC > "$SB/sites/demo/.env"
(umask 077; bash "$ROOT/deploy/migrate.sh" sites) > "$SB/migration.log"
[[ ! -e $SB/sites/demo/current/.env ]]
legacy=$(current_release_id demo)
mkdir "$SB/new-source"
echo NEW > "$SB/new-source/index.html"
(
    umask 077
    publish_release demo abc123 "$SB/new-source"
    rollback_release demo "$legacy" >/dev/null
)
[[ $(cat "$SB/sites/demo/current/index.html") == PUBLIC ]]
mkdir -p "$SB/sites/demo/current/.well-known/acme-challenge"
echo PUBLIC > "$SB/sites/demo/current/index.html"
for f in .env .env.production secret.key .npmrc; do echo SYNTHETIC > "$SB/sites/demo/current/$f"; done
mkdir "$SB/sites/demo/current/nested"
echo SYNTHETIC > "$SB/sites/demo/current/nested/.env"
echo SYNTHETIC > "$SB/sites/demo/current/.well-known/.env"
echo ACME > "$SB/sites/demo/current/.well-known/acme-challenge/token"
echo SYNTHETIC > "$SB/private/env"
chmod 700 "$SB/private"
chmod 600 "$SB/private/env"
sed -n '/^(sandbox_public_guard)/,/^}/p' "$ROOT/caddy/Caddyfile" > "$SB/Caddyfile"
{
    echo ':8080 {'
    render_spa_snippet demo sandbox.invalid
    echo 'handle {'
    echo 'root * /srv/sites/demo/current'
    echo 'route {'
    echo 'import sandbox_public_guard'
    echo 'file_server'
    echo '}'
    echo '}'
    echo '}'
} >> "$SB/Caddyfile"
# Like the production proxy: root without CAP_DAC_OVERRIDE. The upstream
# binary carries a file capability, so NET_BIND_SERVICE must stay bounded.
CID=$(docker run -d --cap-drop ALL --cap-add NET_BIND_SERVICE \
    --network bridge -p 127.0.0.1::8080 \
    -v "$SB/Caddyfile:/etc/caddy/Caddyfile:ro" -v "$SB/sites:/srv/sites:ro" \
    -v "$SB/private:/private:ro" "$IMAGE" caddy run --config /etc/caddy/Caddyfile --adapter caddyfile)
PORT=$(docker port "$CID" 8080/tcp | cut -d: -f2)
for _ in {1..30}; do
    curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break
    sleep .2
done
for host in plain.sandbox.invalid demo.sandbox.invalid; do
    for method in GET HEAD; do
        for path in /.env /.env.production /secret.key /.npmrc /nested/.env /%2eenv /nested/%2eenv /.well-known/.env; do
            args=(); [[ $method != HEAD ]] || args=(-I)
            status=$(curl --path-as-is -sS "${args[@]}" -H "Host: $host" -o "$SB/body" -w '%{http_code}' "http://127.0.0.1:$PORT$path")
            [[ $status == 403 ]] || { docker logs "$CID"; echo "FAIL $host $method $path: $status"; exit 1; }
            ! grep -q SYNTHETIC "$SB/body"
        done
    done
    [[ $(curl -fsS -H "Host: $host" "http://127.0.0.1:$PORT/.well-known/acme-challenge/token") == ACME ]]
done
[[ $(curl -fsS -H 'Host: demo.sandbox.invalid' "http://127.0.0.1:$PORT/route") == PUBLIC ]]
docker exec --user 65534:65534 "$CID" sh -c '! cat /private/env && cat /srv/sites/demo/current/index.html' >/dev/null 2>&1
printf 'PASS migration/deploy/rollback and relative current; real Caddy GET/HEAD denial, encoded/nested paths, SPA, ACME; second UID cannot read private env\n'
