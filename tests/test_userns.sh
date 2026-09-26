#!/usr/bin/env bash
# userns-remap in a throwaway Docker-in-Docker: the daemon of the machine
# running the tests is never reconfigured.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"
if ! docker info >/dev/null 2>&1; then
    echo "SKIP Docker недоступен: проверка userns-remap"
    exit 0
fi
SB=$(make_sandbox)
trap 'rm -rf "$SB"' EXIT
DIND=docker:28-dind
CADDY=sandbox-security-caddy:candidate
HAVE_CADDY=false
if docker image inspect "$CADDY" >/dev/null 2>&1; then
    docker save "$CADDY" -o "$SB/caddy.tar" && HAVE_CADDY=true
fi

docker run --rm -i --privileged --entrypoint sh -e HAVE_CADDY="$HAVE_CADDY" \
    -v "$ROOT:/repo:ro" -v "$SB:/sb:ro" "$DIND" -s > "$SB/userns.log" 2>&1 <<'SCRIPT'
set -e
apk add -q bash python3 >/dev/null
start() {
    dockerd > /var/log/dockerd.log 2>&1 &
    for _ in $(seq 60); do docker info >/dev/null 2>&1 && return 0; sleep 1; done
    cat /var/log/dockerd.log; exit 1
}
stop() {
    kill "$(cat /var/run/docker.pid)"
    while [ -e /var/run/docker.pid ]; do sleep 1; done
}
yes_no() { if "$@" >/dev/null 2>&1; then echo yes; else echo no; fi; }

# Before remapping: a volume with data owned by a non-root UID (like postgres).
start
docker pull -q busybox >/dev/null
docker save busybox -o /tmp/busybox.tar
docker volume create appdata >/dev/null
docker run --rm -v appdata:/v busybox sh -c 'echo DATA > /v/f && chown 999:999 /v/f'
stop

bash /repo/deploy/userns.sh enable
bash /repo/deploy/userns.sh enable
echo "CONFIG $(python3 -c 'import json;print(json.load(open("/etc/docker/daemon.json"))["userns-remap"])')"
start
docker load -q -i /tmp/busybox.tar >/dev/null
BASE=$(grep -m1 '^dockremap:' /etc/subuid | cut -d: -f2)
NEWROOT=/var/lib/docker/$BASE.$(grep -m1 '^dockremap:' /etc/subgid | cut -d: -f2)
echo "BASE $BASE"
echo "MAP $(docker run --rm busybox cat /proc/self/uid_map | xargs)"

mkdir -p /hostdir && chmod 755 /hostdir
echo "ROOT_WRITES_HOST $(yes_no docker run --rm -v /hostdir:/d busybox touch /d/x)"
# A real API call with the static docker CLI, not `test -w` (root always passes it).
CLI="-v /usr/local/bin/docker:/docker:ro -v /var/run/docker.sock:/var/run/docker.sock"
echo "REMAPPED_SOCKET $(yes_no docker run --rm $CLI busybox /docker ps)"
echo "HOSTNS_SOCKET $(yes_no docker run --rm --userns=host $CLI busybox /docker ps)"
mkdir /out && chown 1000:1000 /out && chmod 700 /out
echo "WORKER_HOSTNS $(yes_no docker run --rm --userns=host --user 1000:1000 -v /out:/work busybox touch /work/ok)"
echo "WORKER_REMAPPED $(yes_no docker run --rm --user 1000:1000 -v /out:/work busybox touch /work/no)"
# The public proxy stays remapped: port 80 without capabilities, and it reads
# sites owned by the deploy UID through their world-readable modes.
if [ "$HAVE_CADDY" = true ]; then
    docker load -q -i /sb/caddy.tar >/dev/null
    mkdir -p /sites/demo && echo SITE > /sites/demo/index.html
    chown -R 1000:1000 /sites && chmod 755 /sites /sites/demo && chmod 644 /sites/demo/index.html
    docker run -d --name proxy --cap-drop ALL --read-only --security-opt no-new-privileges \
        --tmpfs /tmp -p 127.0.0.1:8081:80 -v /sites:/srv/sites:ro sandbox-security-caddy:candidate \
        caddy file-server --root /srv/sites/demo --listen :80 >/dev/null
    sleep 2
    echo "PROXY_SERVES $(wget -qO- http://127.0.0.1:8081/ || echo FAIL)"
    docker rm -f proxy >/dev/null
fi
echo "VOLUME_VISIBLE_BEFORE $(docker volume ls -q | grep -c '^appdata$' || true)"
stop

bash /repo/deploy/userns.sh migrate-volumes --dry-run
[ -d "$NEWROOT/volumes" ] && [ ! -e "$NEWROOT/volumes/appdata" ] && echo "DRY_RUN_CLEAN yes"
bash /repo/deploy/userns.sh migrate-volumes
bash /repo/deploy/userns.sh migrate-volumes
start
echo "VOLUME_DATA $(docker run --rm -v appdata:/v busybox sh -c 'cat /v/f; stat -c %u /v/f' | xargs)"
echo "ORIGINAL_OWNER $(stat -c %u /var/lib/docker/volumes/appdata/_data/f)"
echo "HOST_OWNER $(stat -c %u "$NEWROOT/volumes/appdata/_data/f")"
stop
SCRIPT
rc=$?
assert_eq 'dind scenario ran' 0 "$rc"
[[ $rc -eq 0 ]] || tail -30 "$SB/userns.log"
val() { sed -n "s/^$1 //p" "$SB/userns.log"; }
assert_eq 'daemon.json enables remapping (idempotent)' default "$(val CONFIG)"
base=$(val BASE)
assert_ok 'subordinate range is unprivileged' test "${base:-0}" -ge 65536
assert_eq 'container root maps to that range' "0 $base 65536" "$(val MAP)"
assert_eq 'remapped root cannot write root-owned host paths' no "$(val ROOT_WRITES_HOST)"
assert_eq 'remapped container cannot use the Docker socket' no "$(val REMAPPED_SOCKET)"
assert_eq 'controller-style opt-out still can' yes "$(val HOSTNS_SOCKET)"
assert_eq 'worker writes its output with --userns=host' yes "$(val WORKER_HOSTNS)"
assert_eq 'without the opt-out it could not' no "$(val WORKER_REMAPPED)"
assert_eq 'old volumes are invisible before migration' 0 "$(val VOLUME_VISIBLE_BEFORE)"
assert_eq 'dry run copies nothing' yes "$(val DRY_RUN_CLEAN)"
assert_eq 'migrated volume keeps data and in-container owner' 'DATA 999' "$(val VOLUME_DATA)"
assert_eq 'original volume untouched' 999 "$(val ORIGINAL_OWNER)"
assert_eq 'on the host the owner is shifted into the range' "$(( ${base:-0} + 999 ))" "$(val HOST_OWNER)"
if [[ $HAVE_CADDY == true ]]; then
    assert_eq 'remapped public proxy serves deploy-owned sites on port 80' SITE "$(val PROXY_SERVES)"
else
    echo "  SKIP proxy under remap: $CADDY image not built locally"
fi
finish
