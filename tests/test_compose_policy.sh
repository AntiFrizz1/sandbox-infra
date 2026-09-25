#!/usr/bin/env bash
# Compose admission: an ordinary project passes, every escape to the host,
# to other projects or to the Caddy control plane is refused before `up`.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"
if ! docker compose version >/dev/null 2>&1; then
    echo "SKIP docker compose недоступен: проверка compose-политики"
    exit 0
fi
SB=$(make_sandbox)
PROJECT="sbcompose$$"
cleanup() {
    (cd / && docker compose -p "$PROJECT" down -v >/dev/null 2>&1)
    rm -rf "$SB"
}
trap cleanup EXIT
export SANDBOX_STATE_ROOT="$SB/state" SANDBOX_APPS_ROOT="$SB/apps" SANDBOX_DOMAIN=sandbox.test
# shellcheck source=deploy/lib/common.sh
source "$ROOT/deploy/lib/common.sh"
# shellcheck source=deploy/lib/runner.sh
source "$ROOT/deploy/lib/runner.sh"
# shellcheck source=deploy/lib/compose.sh
source "$ROOT/deploy/lib/compose.sh"
IMAGE=caddy@sha256:14a9c00d4e833ebc2b65d36515b37bde3b73f0b323a2663aaafc88953d8c4e3f
WORK="$SB/apps/$PROJECT"
mkdir -p "$WORK/data" "$SB/outside" "$SB/state/$PROJECT"
echo FROM scratch > "$WORK/Dockerfile"
ln -s "$SB/outside" "$WORK/escape"

GOOD="services:
  web:
    build: .
    image: $PROJECT-web
    env_file: .env
    labels:
      caddy: $PROJECT.sandbox.test api.$PROJECT.sandbox.test
      caddy.reverse_proxy: '{{upstreams 8080}}'
    networks: [sandbox_net, backend]
    volumes:
      - ./data:/data
      - db:/var/lib/db
      - type: tmpfs
        target: /cache
    security_opt: [no-new-privileges:true]
    deploy:
      resources:
        reservations: {memory: 64m}
  worker:
    image: $IMAGE
    networks: [backend]
volumes:
  db:
networks:
  sandbox_net:
    external: true
  backend: {}
"
: > "$WORK/.env"

# lint_with <описание> <ожидание ok|fail> <compose-yaml>
lint_with() {
    local desc=$1 want=$2
    printf '%s' "$3" > "$WORK/compose.yml"
    if [[ $want == ok ]]; then
        assert_ok "$desc" compose_lint "$PROJECT" "$WORK" compose.yml "$SANDBOX_DOMAIN"
    else
        # The refusal must come from the policy, not from an unrelated error.
        assert_ok "$desc" policy_refuses
    fi
}
policy_refuses() {
    local out
    if out=$(compose_lint "$PROJECT" "$WORK" compose.yml "$SANDBOX_DOMAIN" 2>&1); then return 1; fi
    grep -q '^compose policy: ' <<< "$out" || { printf 'not a policy refusal: %s\n' "$out" >&2; return 1; }
}
# bad <описание> <yaml-фрагмент сервиса web> — добавляет строки к web.
bad() {
    lint_with "$1" fail "services:
  web:
    image: $IMAGE
$2
"
}

echo "== обычный проект =="
lint_with 'ordinary project admitted' ok "$GOOD"

echo "== привилегии и пространства имён хоста =="
bad 'privileged' '    privileged: true'
bad 'cap_add' '    cap_add: [SYS_ADMIN]'
bad 'devices' '    devices: [/dev/kmsg]'
bad 'host network' '    network_mode: host'
bad 'host pid' '    pid: host'
bad 'host ipc' '    ipc: host'
bad 'userns host' '    userns_mode: host'
bad 'seccomp off' '    security_opt: [seccomp=unconfined]'
bad 'sysctls' '    sysctls: {net.core.somaxconn: 1024}'
bad 'published port' '    ports: ["8080:80"]'
bad 'own resource limits' '    mem_limit: 8g'
bad 'deploy limits' $'    deploy:\n      resources:\n        limits: {memory: 8g}'
bad 'logging driver' '    logging: {driver: syslog}'
bad 'container_name' '    container_name: caddy-caddy-1'
bad 'volumes_from another container' '    volumes_from: ["container:caddy-caddy-1"]'
bad 'lifecycle hook' $'    post_start:\n      - command: id\n        privileged: true'

echo "== файлы и данные хоста =="
bad 'absolute bind' $'    volumes:\n      - /etc:/host-etc:ro'
bad 'parent bind' $'    volumes:\n      - ../..:/up'
bad 'bind through symlink' $'    volumes:\n      - ./escape:/escape'
bad 'docker socket' $'    volumes:\n      - /var/run/docker.sock:/var/run/docker.sock'
bad 'env_file outside' '    env_file: ../../outside/secret.env'
bad 'build outside' $'    build: ../..'
bad 'build ssh' $'    build:\n      context: .\n      ssh: [default]'
bad 'build extra context' $'    build:\n      context: .\n      additional_contexts: {host: /}'
bad 'build host network' $'    build:\n      context: .\n      network: host'
lint_with 'built image hijacks a shared tag' fail "services:
  web:
    build: .
    image: nginx:latest
"
lint_with 'external volume' fail "services:
  web:
    image: $IMAGE
    volumes: [\"shared:/data\"]
volumes:
  shared:
    external: true
"
lint_with 'volume named after another project' fail "services:
  web:
    image: $IMAGE
    volumes: [\"shared:/data\"]
volumes:
  shared:
    name: otherapp_data
"
lint_with 'local driver bind to host path' fail "services:
  web:
    image: $IMAGE
    volumes: [\"shared:/data\"]
volumes:
  shared:
    driver_opts: {type: none, o: bind, device: /etc}
"
lint_with 'top-level secrets from host file' fail "services:
  web:
    image: $IMAGE
secrets:
  key:
    file: /etc/shadow
"

echo "== сети и Caddy =="
lint_with 'Caddy control network' fail "services:
  web:
    image: $IMAGE
    networks: [ctl]
networks:
  ctl:
    external: true
    name: caddy_control
"
lint_with 'network renamed onto another' fail "services:
  web:
    image: $IMAGE
    networks: [n]
networks:
  n:
    name: otherapp_default
"
bad 'foreign hostname' $'    labels:\n      caddy: otherapp.sandbox.test'
bad 'apex hostname' $'    labels:\n      caddy: sandbox.test'
bad 'lookalike hostname' "    labels:
      caddy: evil$PROJECT.sandbox.test"
bad 'proxy to Caddy admin' $'    labels:\n      caddy: '"$PROJECT"$'.sandbox.test\n      caddy.reverse_proxy: 127.0.0.1:2019'
bad 'raw Caddy directive' $'    labels:\n      caddy: '"$PROJECT"$'.sandbox.test\n      caddy.import: /etc/caddy/Caddyfile'
bad 'pretend to be the Caddy server' $'    labels:\n      caddy_controlled_server: ""'
bad 'spoof compose metadata' $'    labels:\n      com.docker.compose.project: caddy'

echo "== другие файлы и интерполяция =="
printf 'services:\n  intruder:\n    image: %s\n' "$IMAGE" > "$SB/outside/other.yml"
lint_with 'include' fail "include:
  - ../../outside/other.yml
services:
  web:
    image: $IMAGE
"
bad 'extends from another file' $'    extends:\n      file: ../../outside/other.yml\n      service: intruder'
echo 'PRIV=true' > "$SB/state/$PROJECT/env"
bad 'privilege via interpolation' '    privileged: ${PRIV}'
echo "ESCAPE=/etc" > "$SB/state/$PROJECT/env"
bad 'bind via interpolation' $'    volumes:\n      - ${ESCAPE}:/x'
rm "$SB/state/$PROJECT/env"
echo 'PRIV=true' > "$WORK/.env"
lint_with 'repository .env is not used for interpolation' ok "services:
  web:
    image: $IMAGE
    read_only: \${PRIV:-false}
"
: > "$WORK/.env"

echo "== override с ограничениями =="
printf '%s' "$GOOD" > "$WORK/compose.yml"
COMPOSE_MEMORY=128 COMPOSE_CPUS=1 COMPOSE_PIDS=64
assert_ok 'override written' compose_write_override "$PROJECT" "$WORK" compose.yml "$SB/state/$PROJECT/override.json"
assert_eq 'override covers every service' 'web,worker' \
    "$(python3 -c 'import json,sys;print(",".join(sorted(json.load(open(sys.argv[1]))["services"])))' "$SB/state/$PROJECT/override.json")"
merged=$(compose_run "$PROJECT" "$WORK" compose.yml -f "$SB/state/$PROJECT/override.json" -- config --format json)
assert_eq 'memory limit enforced' 134217728 \
    "$(python3 -c 'import json,sys;print(json.load(sys.stdin)["services"]["web"]["deploy"]["resources"]["limits"]["memory"])' <<< "$merged")"
assert_eq 'no-new-privileges enforced' 'no-new-privileges:true' \
    "$(python3 -c 'import json,sys;print(",".join(json.load(sys.stdin)["services"]["worker"]["security_opt"]))' <<< "$merged")"

if docker info >/dev/null 2>&1; then
    echo "== реальный запуск =="
    printf 'services:\n  app:\n    image: %s\n    command: caddy respond --listen :8080 OK\n' "$IMAGE" > "$WORK/compose.yml"
    assert_ok 'lint passes' compose_lint "$PROJECT" "$WORK" compose.yml "$SANDBOX_DOMAIN"
    compose_write_override "$PROJECT" "$WORK" compose.yml "$SB/state/$PROJECT/override.json"
    assert_ok 'up with enforced override' compose_run "$PROJECT" "$WORK" compose.yml \
        -f "$SB/state/$PROJECT/override.json" -- up -d
    cid=$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT")
    assert_eq 'runtime memory limit' 134217728 "$(docker inspect -f '{{.HostConfig.Memory}}' "$cid")"
    assert_eq 'runtime pids limit' 64 "$(docker inspect -f '{{.HostConfig.PidsLimit}}' "$cid")"
    assert_eq 'runtime no-new-privileges' '[no-new-privileges:true]' "$(docker inspect -f '{{.HostConfig.SecurityOpt}}' "$cid")"
    assert_eq 'runtime log driver' local "$(docker inspect -f '{{.HostConfig.LogConfig.Type}}' "$cid")"
    assert_ok 'down by project name only' bash -c "cd / && docker compose -p '$PROJECT' down"
    assert_eq 'no containers left' '' "$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")"
else
    echo "  SKIP реальный запуск: docker daemon недоступен"
fi
finish
