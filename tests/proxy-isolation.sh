#!/usr/bin/env bash
# Real controller/server compatibility test; unique networks, no production ports.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SB=$(mktemp -d /tmp/sandbox-proxy-security.XXXXXXXX)
PROJECT="sandbox-security-${SB##*.}"
PROJECT=${PROJECT,,}
IMAGE=${SANDBOX_TEST_PROXY_IMAGE:-sandbox-security-caddy:candidate}
cleanup() {
    docker compose -p "$PROJECT" -f "$SB/compose.yml" down -v >/dev/null 2>&1 || true
    docker network rm "$PROJECT-control" "$PROJECT-ingress" >/dev/null 2>&1 || true
    rm -rf "$SB"
}
trap cleanup EXIT
docker network create --internal "$PROJECT-control" >/dev/null
docker network create "$PROJECT-ingress" >/dev/null
SUBNET=$(docker network inspect --format '{{(index .IPAM.Config 0).Subnet}}' "$PROJECT-control")
mkdir "$SB/config" "$SB/spa" "$SB/sites"
echo STATIC > "$SB/sites/index.html"
sed -n '/^(sandbox_public_guard)/,/^}/p' "$ROOT/caddy/Caddyfile" > "$SB/config/Caddyfile"
cat >> "$SB/config/Caddyfile" <<'CONFIG'
:8080 {
    root * /srv/sites
    route {
        import sandbox_public_guard
        file_server
    }
}
CONFIG
cat > "$SB/compose.yml" <<CONFIG
services:
  caddy:
    image: $IMAGE
    read_only: true
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    tmpfs: [/tmp, /data, /config]
    command: caddy docker-proxy
    environment:
      CADDY_DOCKER_MODE: server
      CADDY_CONTROLLER_NETWORK: $SUBNET
    labels:
      ${PROJECT}_controlled_server: ''
    volumes:
      - ./sites:/srv/sites:ro
      - ./config:/etc/caddy:ro
    networks: [control, ingress]
  controller:
    image: $IMAGE
    userns_mode: host
    read_only: true
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    tmpfs: [/tmp, /config]
    command: caddy docker-proxy --caddyfile-path /etc/caddy/Caddyfile --label-prefix $PROJECT
    environment:
      CADDY_DOCKER_MODE: controller
      CADDY_CONTROLLER_NETWORK: $SUBNET
      CADDY_INGRESS_NETWORKS: $PROJECT-ingress
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./config:/etc/caddy:ro
    networks: [control]
  app:
    image: $IMAGE
    command: caddy respond --listen :8080 --body BACKEND
    labels:
      $PROJECT: http://docker.test:8080
      $PROJECT.reverse_proxy: '{{upstreams 8080}}'
    networks: [ingress]
networks:
  control:
    external: true
    name: $PROJECT-control
  ingress:
    external: true
    name: $PROJECT-ingress
CONFIG
compose() { docker compose -p "$PROJECT" -f "$SB/compose.yml" "$@"; }
compose up -d >/dev/null
request() { compose exec -T caddy wget -qO- --header="Host: $1" http://127.0.0.1:8080/; }
for _ in {1..60}; do
    [[ $(request docker.test 2>/dev/null || true) == BACKEND ]] && break
    sleep .3
done
[[ $(request docker.test) == BACKEND ]] || { compose logs; exit 1; }
[[ $(request static.test) == STATIC ]]
compose exec -T caddy sh -c 'test ! -e /var/run/docker.sock'
# Neither Docker API nor control/admin API is accessible from the ingress app.
server=$(compose ps -q caddy)
server_ip=$(docker inspect --format "{{(index .NetworkSettings.Networks \"$PROJECT-ingress\").IPAddress}}" "$server")
compose exec -T app sh -c "! wget -T 2 -qO- http://$server_ip:2019/config/"
compose exec -T app sh -c "! wget -T 2 -qO- http://$server_ip:2020/"
control_ip=$(docker inspect --format "{{(index .NetworkSettings.Networks \"$PROJECT-control\").IPAddress}}" "$server")
compose exec -T app sh -c "! wget -T 2 -qO- http://$control_ip:2019/config/"
gateway=$(docker network inspect --format '{{(index .IPAM.Config 0).Gateway}}' "$PROJECT-ingress")
compose exec -T caddy sh -c "! wget -T 2 -qO- http://$gateway:2375/version"
# Atomic directory-mounted config replacement must be observed by controller.
cp "$SB/config/Caddyfile" "$SB/config/new"
printf '\nhttp://new.test:8080 {\n respond NEW\n}\n' >> "$SB/config/new"
mv "$SB/config/new" "$SB/config/Caddyfile"
compose restart controller >/dev/null
for _ in {1..60}; do
    [[ $(request new.test 2>/dev/null || true) == NEW ]] && break
    sleep .3
done
[[ $(request new.test) == NEW ]]
[[ $(request docker.test) == BACKEND ]]
printf 'PASS split proxy: static, reverse proxy labels, restart, atomic config; no server socket; ingress control/admin rejected\n'
