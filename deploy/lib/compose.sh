#!/usr/bin/env bash
# Compose projects on the host daemon. Admitted only with a root-owned
# profile=compose policy and a model that passes lint-compose.py; resource
# limits, logging and no-new-privileges come from a server-side override.
# Requires common.sh and runner.sh (trusted_policy_path).
COMPOSE_WRAP=()
SANDBOX_LINT_COMPOSE="${SANDBOX_LINT_COMPOSE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lint-compose.py}"

load_compose_policy() {
    local name=$1 path n
    path=$(resolve_policy "$name" compose) || return 1
    [[ $(read_conf_value "$path" profile || true) == compose ]] \
        || { warn "[$name] Docker projects need profile=compose in $path"; return 1; }
    COMPOSE_TIMEOUT=$(read_conf_value "$path" timeout_seconds || echo 900)
    COMPOSE_MEMORY=$(read_conf_value "$path" memory_mb || echo 512)
    COMPOSE_PIDS=$(read_conf_value "$path" pids || echo 256)
    COMPOSE_CPUS=$(read_conf_value "$path" cpus || echo 1)
    for n in "$COMPOSE_TIMEOUT" "$COMPOSE_MEMORY" "$COMPOSE_PIDS" "$COMPOSE_CPUS"; do
        [[ $n =~ ^[1-9][0-9]{0,5}$ ]] || { warn "[$name] invalid compose policy value '$n'"; return 1; }
    done
}

# compose_run <name> <workdir> <compose-file> [-f extra]... -- <compose args...>
# A clean environment: interpolation sees only the server-side state env,
# never the repository's .env or the deploy user's variables.
compose_run() {
    local name=$1 workdir=$2 file=$3 envfile
    shift 3
    local -a files=(-f "$workdir/$file")
    while (( $# )) && [[ $1 != -- ]]; do files+=("$1"); shift; done
    (( $# )) && shift
    envfile="$(app_state_dir "$name")/env"
    [[ -f $envfile ]] || envfile=/dev/null
    # COMPOSE_WRAP (array, optional) prefixes the command, e.g. with timeout.
    "${COMPOSE_WRAP[@]}" env -i PATH="$PATH" HOME="$HOME" \
        docker compose -p "$name" --project-directory "$workdir" \
        "${files[@]}" --env-file "$envfile" "$@"
}

# compose_lint <name> <workdir> <compose-file> <domain>
compose_lint() {
    local name=$1 workdir=$2 file=$3 domain=$4 model
    model=$(compose_run "$name" "$workdir" "$file" -- --profile '*' \
        config --format json --no-path-resolution --no-env-resolution) \
        || { warn "[$name] docker compose config failed"; return 1; }
    python3 "$SANDBOX_LINT_COMPOSE" \
        "$name" "$domain" "$workdir" "$workdir/$file" <<< "$model"
}

# compose_write_override <name> <workdir> <compose-file> <path>
compose_write_override() {
    local name=$1 workdir=$2 file=$3 path=$4
    local -a services
    mapfile -t services < <(compose_run "$name" "$workdir" "$file" -- --profile '*' config --services)
    (( ${#services[@]} )) || { warn "[$name] no services in $file"; return 1; }
    python3 - "$path" "$COMPOSE_MEMORY" "$COMPOSE_CPUS" "$COMPOSE_PIDS" "${services[@]}" <<'PY'
import json, sys
path, memory, cpus, pids = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
services = sys.argv[5:]
enforced = {
    'security_opt': ['no-new-privileges:true'],
    # Docker's defaults minus what ordinary services (nginx, postgres, node)
    # never need but an attacker with code execution would use: raw sockets
    # to spoof traffic on sandbox_net, device nodes, chroot, file capabilities.
    'cap_drop': ['NET_RAW', 'MKNOD', 'SYS_CHROOT', 'SETFCAP', 'AUDIT_WRITE'],
    'logging': {'driver': 'local', 'options': {'max-size': '10m', 'max-file': '3'}},
    'memswap_limit': f'{memory}m',
    'deploy': {'resources': {'limits': {'memory': f'{memory}m', 'cpus': cpus, 'pids': pids}}},
}
with open(path, 'w') as f:
    json.dump({'services': {s: enforced for s in services}}, f, indent=2)
PY
}
