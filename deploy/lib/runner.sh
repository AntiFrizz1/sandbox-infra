#!/usr/bin/env bash
# Policies are installed by root, outside repositories and deploy-owned state.
SANDBOX_POLICY_ROOT="${SANDBOX_POLICY_ROOT:-/etc/sandbox/projects}"

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

load_execution_policy() {
    local name=$1 path="$SANDBOX_POLICY_ROOT/$1.conf"
    trusted_policy_path "$path" || { warn "[$name] root-owned execution policy required"; return 1; }
    RUN_PROFILE=$(read_conf_value "$path" profile || true)
    RUN_IMAGE=$(read_conf_value "$path" image || true)
    RUN_TIMEOUT=$(read_conf_value "$path" timeout_seconds || echo 300)
    RUN_MEMORY=$(read_conf_value "$path" memory_mb || echo 512)
    RUN_PIDS=$(read_conf_value "$path" pids || echo 128)
    RUN_CPUS=$(read_conf_value "$path" cpus || echo 1)
    [[ $RUN_PROFILE == worker ]] || { warn 'Only worker profile supported; Docker projects require a separate rootless/VM migration'; return 1; }
    [[ $RUN_IMAGE =~ ^[^[:space:]]+@sha256:[a-f0-9]{64}$ ]] || return 1
    local n
    for n in "$RUN_TIMEOUT" "$RUN_MEMORY" "$RUN_PIDS" "$RUN_CPUS"; do
        [[ $n =~ ^[1-9][0-9]{0,5}$ ]] || return 1
    done
}

run_worker() (
    local name=$1 source=$2 output=$3 command=$4 cid="" rc=0
    (( EUID != 0 )) || { warn "run dispatcher as unprivileged deploy UID"; return 1; }
    load_execution_policy "$name" || return 1
    require_plain_under "$(app_state_dir "$name")" "$source" || return 1
    require_plain_under "$(app_state_dir "$name")" "$output" || return 1
    private_dir "$output" || return 1
    local -a secrets=()
    local envfile
    envfile="$(app_state_dir "$name")/build-env"
    if [[ -e $envfile || -L $envfile ]]; then
        assert_plain_path "$envfile" && [[ -f $envfile ]] || return 1
        secrets=(--mount "type=bind,src=$envfile,dst=/build-env,readonly")
    fi
    # The named container is owned only by this attempt; kill/removal never uses a wildcard.
    trap '[[ -z $cid ]] || docker rm -f "$cid" >/dev/null 2>&1' EXIT
    trap 'exit 143' TERM INT HUP
    cid=$(docker create --pull=never --user "$(id -u):$(id -g)" \
        --read-only --cap-drop ALL --security-opt no-new-privileges \
        --network none --cpus "$RUN_CPUS" --memory "${RUN_MEMORY}m" \
        --memory-swap "${RUN_MEMORY}m" --pids-limit "$RUN_PIDS" \
        --log-driver local --log-opt max-size=1m --log-opt max-file=1 --log-opt compress=false \
        --tmpfs /tmp:rw,nosuid,nodev,size=128m \
        --mount "type=bind,src=$source,dst=/source,readonly" \
        --mount "type=bind,src=$output,dst=/work" \
        "${secrets[@]}" "$RUN_IMAGE" "$command") || return 1
    # Killing the CLI alone is insufficient: EXIT always removes the container/cgroup.
    timeout --signal=TERM --kill-after=5 "$RUN_TIMEOUT" docker start -a "$cid" || rc=$?
    if (( rc == 0 )); then
        rc=$(docker inspect --format '{{.State.ExitCode}}' "$cid") || return 1
    fi
    (( rc == 0 )) || { warn "[$name] worker failed/timeout ($rc)"; return 1; }
)
