#!/usr/bin/env bash
# Dispatcher contract without Docker: which container gets network, source,
# secrets and project code. Real isolation is checked by worker-isolation.sh.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"
SB=$(make_sandbox)
trap 'rm -rf "$SB"' EXIT
export SANDBOX_STATE_ROOT="$SB/state" SANDBOX_SITES_ROOT="$SB/sites"
# shellcheck source=deploy/lib/common.sh
source "$ROOT/deploy/lib/common.sh"
# shellcheck source=deploy/lib/runner.sh
source "$ROOT/deploy/lib/runner.sh"

# Stub on PATH (timeout execs the binary, not a shell function): every call
# is recorded, one argument per line, calls separated by ----.
mkdir "$SB/bin"
cat > "$SB/bin/docker" <<'STUB'
#!/usr/bin/env bash
{ printf '%s\n' "$@"; echo '----'; } >> "$DOCKER_LOG"
case $1 in
    create) echo "cid-$RANDOM" ;;
    inspect) echo "${FAKE_EXIT:-0}" ;;
    network) echo "${FAKE_NETWORK_LABEL-}" ;;
esac
STUB
chmod +x "$SB/bin/docker"
export PATH="$SB/bin:$PATH" DOCKER_LOG="$SB/docker.log"
IMAGE="worker@sha256:$(printf 'a%.0s' {1..64})"
load_execution_policy() {
    RUN_PROFILE=worker RUN_IMAGE=$IMAGE RUN_TIMEOUT=20 RUN_MEMORY=256 RUN_PIDS=32 RUN_CPUS=1
    RUN_FETCH_NETWORK=sandbox_build RUN_NPM_REGISTRY=https://registry.example.test/
}
prepare_state demo
mkdir "$SB/state/demo/build"
echo SECRET > "$SB/state/demo/build-env"

# create_args <n> — arguments of the n-th `docker create`, one per line.
create_args() {
    awk -v want="$1" '
        /^----$/ { if (block ~ /^create\n/) { n++; if (n == want) { printf "%s", block; exit } } block = ""; next }
        { block = block $0 "\n" }' "$SB/docker.log"
}

echo "== две фазы =="
assert_ok 'worker completes' run_worker demo "$SB/state/demo/build" "$SB/state/demo/out" 'npm run build'
fetch=$(create_args 1)
build=$(create_args 2)
assert_eq 'exactly two containers' 2 "$(grep -c '^create$' "$SB/docker.log")"
assert_ok 'fetch joins the build network' grep -qxF -- 'sandbox_build' <<< "$fetch"
assert_ok 'fetch runs the fetch mode' grep -qxF -- 'fetch' <<< "$fetch"
assert_ok 'registry comes from policy' grep -qxF -- 'npm_config_registry=https://registry.example.test/' <<< "$fetch"
assert_ok 'fetch sees the source' grep -qF -- "dst=/source,readonly" <<< "$fetch"
assert_fail 'fetch never sees build secrets' grep -qF -- 'dst=/build-env' <<< "$fetch"
assert_fail 'fetch never receives the build command' grep -qxF -- 'npm run build' <<< "$fetch"
assert_ok 'build has no network' grep -qxF -- 'none' <<< "$build"
assert_ok 'build runs the build mode' grep -qxF -- 'build' <<< "$build"
assert_ok 'build receives the command' grep -qxF -- 'npm run build' <<< "$build"
assert_ok 'build gets build secrets' grep -qF -- 'dst=/build-env,readonly' <<< "$build"
assert_fail 'build does not see the source' grep -qF -- 'dst=/source' <<< "$build"
assert_ok 'both phases drop capabilities' test "$(grep -c '^ALL$' "$SB/docker.log")" -eq 2
assert_eq 'both containers removed' 2 "$(grep -c '^rm$' "$SB/docker.log")"

echo "== непустой output отвергается =="
: > "$SB/docker.log"
touch "$SB/state/demo/out/stale"
assert_fail 'leftover output refused' run_worker demo "$SB/state/demo/build" "$SB/state/demo/out" 'npm run build'
assert_eq 'no container for leftover output' 0 "$(grep -c '^create$' "$SB/docker.log")"
rm "$SB/state/demo/out/stale"

echo "== провал fetch останавливает сборку =="
: > "$SB/docker.log"
FAKE_EXIT=1 run_worker demo "$SB/state/demo/build" "$SB/state/demo/out" 'npm run build' >/dev/null 2>&1
assert_eq 'no build container after failed fetch' 1 "$(grep -c '^create$' "$SB/docker.log")"
assert_eq 'failed container removed' 1 "$(grep -c '^rm$' "$SB/docker.log")"

echo "== сеть для fetch =="
assert_ok 'none is always allowed' validate_fetch_network none
export FAKE_NETWORK_LABEL=build
assert_ok 'labelled build network allowed' validate_fetch_network sandbox_build
FAKE_NETWORK_LABEL=''
assert_fail 'unlabelled network refused' validate_fetch_network sandbox_net
FAKE_NETWORK_LABEL=build
assert_fail 'host network refused even if labelled' validate_fetch_network host
assert_fail 'malformed network name refused' validate_fetch_network 'a b'
finish
