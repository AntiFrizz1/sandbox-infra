#!/usr/bin/env bash
# Policies are installed by root, outside repositories and deploy-owned state.
SANDBOX_POLICY_ROOT="${SANDBOX_POLICY_ROOT:-/etc/sandbox/projects}"
# Networks the fetch phase may join must carry this label (see bootstrap.sh).
SANDBOX_FETCH_NETWORK_LABEL="${SANDBOX_FETCH_NETWORK_LABEL:-sandbox.role=build}"

trusted_policy_path() {
    local path=$1 cursor=$1 mode
    assert_plain_path "$path" || return 1
    [[ -f $path ]] || return 1
    while [[ $cursor != / ]]; do
        [[ $(stat -c %u "$cursor") == 0 ]] || return 1
        mode=$(stat -c %a "$cursor")
        (( (8#$mode & 0022) == 0 )) || return 1
        cursor=$(dirname "$cursor")
    done
}

# validate_fetch_network <name>
# "none" keeps the fetch offline. Anything else must be a network the
# administrator labelled for builds: this is what keeps a policy typo from
# attaching the worker to sandbox_net, the Caddy control network or host.
validate_fetch_network() {
    local network=$1 key=${SANDBOX_FETCH_NETWORK_LABEL%%=*} value=${SANDBOX_FETCH_NETWORK_LABEL#*=}
    [[ $network == none ]] && return 0
    [[ $network =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}$ ]] || return 1
    [[ $network != host ]] || return 1
    [[ $(docker network inspect --format "{{index .Labels \"$key\"}}" "$network" 2>/dev/null) == "$value" ]]
}

load_execution_policy() {
    local name=$1 path="$SANDBOX_POLICY_ROOT/$1.conf"
    trusted_policy_path "$path" || { warn "[$name] root-owned execution policy required"; return 1; }
    RUN_PROFILE=$(read_conf_value "$path" profile || true)
    RUN_IMAGE=$(read_conf_value "$path" image || true)
    RUN_TIMEOUT=$(read_conf_value "$path" timeout_seconds || echo 300)
    RUN_MEMORY=$(read_conf_value "$path" memory_mb || echo 512)
    RUN_PIDS=$(read_conf_value "$path" pids || echo 128)
    RUN_CPUS=$(read_conf_value "$path" cpus || echo 1)
    RUN_OUTPUT_MB=$(read_conf_value "$path" output_mb || echo 2048)
    RUN_FETCH_NETWORK=$(read_conf_value "$path" fetch_network || echo none)
    RUN_NPM_REGISTRY=$(read_conf_value "$path" npm_registry || echo https://registry.npmjs.org/)
    [[ $RUN_PROFILE == worker ]] || { warn "[$name] execution policy profile must be worker"; return 1; }
    [[ $RUN_IMAGE =~ ^[^[:space:]]+@sha256:[a-f0-9]{64}$ ]] || return 1
    local n
    for n in "$RUN_TIMEOUT" "$RUN_MEMORY" "$RUN_PIDS" "$RUN_CPUS" "$RUN_OUTPUT_MB"; do
        [[ $n =~ ^[1-9][0-9]{0,5}$ ]] || return 1
    done
    [[ $RUN_NPM_REGISTRY =~ ^https://[A-Za-z0-9._~:/%@+-]+$ ]] \
        || { warn "[$name] npm_registry must be an https URL"; return 1; }
    validate_fetch_network "$RUN_FETCH_NETWORK" \
        || { warn "[$name] fetch_network must be none or a network labelled $SANDBOX_FETCH_NETWORK_LABEL"; return 1; }
}

# watch_output <cid> <flag-file>
# The output is a host bind mount, so neither the memory limit nor a tmpfs
# bounds it. Without filesystem quotas the dispatcher polls instead: over
# RUN_OUTPUT_MB, or below SANDBOX_MIN_FREE_MB free, the container is killed.
watch_output() {
    local cid=$1 flag=$2 used free
    while sleep "${SANDBOX_WATCH_INTERVAL:-5}"; do
        used=$(du -sm -- "$WORKER_OUTPUT" 2>/dev/null | cut -f1)
        free=$(free_mb "$WORKER_OUTPUT")
        [[ $used =~ ^[0-9]+$ && $free =~ ^[0-9]+$ ]] || continue
        if (( used > RUN_OUTPUT_MB || free < ${SANDBOX_MIN_FREE_MB:-1024} )); then
            printf 'output %s MB (limit %s), free %s MB\n' "$used" "$RUN_OUTPUT_MB" "$free" > "$flag"
            docker kill "$cid" >/dev/null 2>&1
            return 0
        fi
    done
}

# worker_phase <fetch|build> <network> [docker-args...] -- [worker-args...]
# Runs one disposable container over WORKER_OUTPUT. Sets the caller's cid so
# its EXIT trap can remove the container whatever happens.
worker_phase() {
    local mode=$1 network=$2 rc=0
    shift 2
    local -a extra=()
    while (( $# )) && [[ $1 != -- ]]; do extra+=("$1"); shift; done
    (( $# )) && shift
    # --userns=host: the worker already runs as the unprivileged deploy UID
    # without capabilities; under userns-remap it could not write its own
    # deploy-owned output tree otherwise.
    cid=$(docker create --pull=never --user "$(id -u):$(id -g)" --userns=host \
        --read-only --cap-drop ALL --security-opt no-new-privileges \
        --network "$network" --cpus "$RUN_CPUS" --memory "${RUN_MEMORY}m" \
        --memory-swap "${RUN_MEMORY}m" --pids-limit "$RUN_PIDS" \
        --log-driver local --log-opt max-size=1m --log-opt max-file=1 --log-opt compress=false \
        --tmpfs /tmp:rw,nosuid,nodev,size=128m \
        --mount "type=bind,src=$WORKER_OUTPUT,dst=/work" \
        "${extra[@]}" "$RUN_IMAGE" "$mode" "$@") || return 1
    # Killing the CLI alone is insufficient: the container is removed below
    # and, on any abort, by the caller's EXIT trap.
    local flag watcher
    flag=$(mktemp "$WORKER_OUTPUT.limit.XXXXXX") || return 1
    rm -f "$flag"
    watch_output "$cid" "$flag" &
    watcher=$!
    timeout --signal=TERM --kill-after=5 "$RUN_TIMEOUT" docker start -a "$cid" || rc=$?
    kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null
    if (( rc == 0 )); then
        rc=$(docker inspect --format '{{.State.ExitCode}}' "$cid") || return 1
    fi
    docker rm -f "$cid" >/dev/null 2>&1 || true
    cid=""
    if [[ -f $flag ]]; then
        warn "[$WORKER_NAME] worker $mode stopped: $(cat "$flag")"
        rm -f "$flag"
        return 1
    fi
    (( rc == 0 )) || { warn "[$WORKER_NAME] worker $mode failed/timeout ($rc)"; return 1; }
}

# run_worker <name> <source> <output> <command>
# Two containers share only the output tree. The fetch phase sees the source
# and possibly the network, but executes no project code. The build phase
# runs that code with no network, no source mount, and build secrets only.
run_worker() (
    local name=$1 source=$2 output=$3 command=$4 cid=""
    (( EUID != 0 )) || { warn "run dispatcher as unprivileged deploy UID"; return 1; }
    load_execution_policy "$name" || return 1
    require_plain_under "$(app_state_dir "$name")" "$source" || return 1
    require_plain_under "$(app_state_dir "$name")" "$output" || return 1
    private_dir "$output" || return 1
    # A leftover tree (stale lockfile, old build) would silently leak into this attempt.
    [[ -z $(ls -A "$output") ]] || { warn "[$name] worker output is not empty: $output"; return 1; }
    local -a secrets=()
    local envfile
    envfile="$(app_state_dir "$name")/build-env"
    if [[ -e $envfile || -L $envfile ]]; then
        assert_plain_path "$envfile" && [[ -f $envfile ]] || return 1
        secrets=(--mount "type=bind,src=$envfile,dst=/build-env,readonly")
    fi
    WORKER_NAME=$name WORKER_OUTPUT=$output
    # The named container is owned only by this attempt; kill/removal never uses a wildcard.
    trap '[[ -z $cid ]] || docker rm -f "$cid" >/dev/null 2>&1' EXIT
    trap 'exit 143' TERM INT HUP
    echo "   зависимости: сеть $RUN_FETCH_NETWORK, без выполнения скриптов"
    worker_phase fetch "$RUN_FETCH_NETWORK" \
        --env "npm_config_registry=$RUN_NPM_REGISTRY" \
        --mount "type=bind,src=$source,dst=/source,readonly" -- || return 1
    echo "   сборка без сети: $command"
    worker_phase build none "${secrets[@]}" -- "$command" || return 1
)
