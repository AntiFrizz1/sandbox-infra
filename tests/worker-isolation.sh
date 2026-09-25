#!/usr/bin/env bash
# Real worker boundary tests. Policy ownership is tested separately in a root container.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SB=$(mktemp -d /tmp/sandbox-worker-security.XXXXXXXX)
NET=sandbox-test-build-$$
trap 'docker network rm "$NET" >/dev/null 2>&1; rm -rf "$SB"' EXIT
export SANDBOX_STATE_ROOT="$SB/state" SANDBOX_SITES_ROOT="$SB/sites"
# shellcheck source=deploy/lib/common.sh
source "$ROOT/deploy/lib/common.sh"
# shellcheck source=deploy/lib/runner.sh
source "$ROOT/deploy/lib/runner.sh"
prepare_state demo
SRC="$SB/state/demo/build"
OUT="$SB/state/demo/output"
mkdir "$SRC"
printf '{"name":"security-fixture","version":"1.0.0"}\n' > "$SRC/package.json"
# Use the locally built content-addressed candidate; no registry push.
IMAGE=$(docker image inspect sandbox-security-worker:candidate --format '{{index .RepoDigests 0}}')
# Explicit fixture policy: the real loader is checked below, without giving the host user root.
load_execution_policy() {
    RUN_PROFILE=worker RUN_IMAGE=$IMAGE RUN_TIMEOUT=20 RUN_MEMORY=256 RUN_PIDS=32 RUN_CPUS=1
    RUN_FETCH_NETWORK=none RUN_NPM_REGISTRY=https://registry.npmjs.org/ RUN_OUTPUT_MB=2048
}
cmd='test "$(cat /sys/fs/cgroup/memory.max)" = 268435456 && test "$(cat /sys/fs/cgroup/pids.max)" = 32 && grep -q "NoNewPrivs:.*1" /proc/self/status && test ! -e /var/run/docker.sock && test ! -e /srv/state && test ! -e /srv/sites && test ! -e /root/.ssh && test ! -e /srv/deploy && test ! -e /source && mkdir dist && echo SAFE > dist/index.html'
run_worker demo "$SRC" "$OUT" "$cmd" > "$SB/build.log" 2>&1 || { cat "$SB/build.log"; exit 1; }
[[ $(cat "$OUT/dist/index.html") == SAFE ]]
[[ ! -e $SRC/injected ]]
safe_rm_rf "$SB/state/demo" "$OUT"
# Timeout leaves no container/cgroup and a subsequent attempt can succeed.
load_execution_policy() {
    RUN_PROFILE=worker RUN_IMAGE=$IMAGE RUN_TIMEOUT=2 RUN_MEMORY=256 RUN_PIDS=32 RUN_CPUS=1
    RUN_FETCH_NETWORK=none RUN_NPM_REGISTRY=https://registry.npmjs.org/ RUN_OUTPUT_MB=2048
}
if run_worker demo "$SRC" "$OUT" 'sleep 300 & wait' > "$SB/timeout.log" 2>&1; then exit 1; fi
[[ -z $(docker ps -aq --filter "ancestor=$IMAGE") ]]
safe_rm_rf "$SB/state/demo" "$OUT"
load_execution_policy() {
    RUN_PROFILE=worker RUN_IMAGE=$IMAGE RUN_TIMEOUT=20 RUN_MEMORY=256 RUN_PIDS=32 RUN_CPUS=1
    RUN_FETCH_NETWORK=none RUN_NPM_REGISTRY=https://registry.npmjs.org/ RUN_OUTPUT_MB=2048
}
run_worker demo "$SRC" "$OUT" 'printf "int main(){return 0;}" > /tmp/hello.cc; g++ /tmp/hello.cc -o /tmp/hello; /tmp/hello; mkdir dist; echo NEXT > dist/index.html' > "$SB/next.log" 2>&1
[[ $(cat "$OUT/dist/index.html") == NEXT ]]
safe_rm_rf "$SB/state/demo" "$OUT"
cat > "$SRC/oom.js" <<'JS'
const held=[]; setInterval(()=>held.push(Buffer.alloc(16*1024*1024,1)),10);
JS
load_execution_policy() {
    RUN_PROFILE=worker RUN_IMAGE=$IMAGE RUN_TIMEOUT=20 RUN_MEMORY=128 RUN_PIDS=32 RUN_CPUS=1
    RUN_FETCH_NETWORK=none RUN_NPM_REGISTRY=https://registry.npmjs.org/ RUN_OUTPUT_MB=2048
}
if run_worker demo "$SRC" "$OUT" 'node oom.js' > "$SB/oom.log" 2>&1; then exit 1; fi
grep -q '(137)' "$SB/oom.log" || { cat "$SB/oom.log"; exit 1; }
safe_rm_rf "$SB/state/demo" "$OUT"
cat > "$SRC/pids.js" <<'JS'
const {spawn}=require('child_process');
for(let i=0;i<64;i++) spawn('sleep',['100']).on('error',e=>{
  if(e.code==='EAGAIN'){console.log('PIDS_LIMIT_REACHED');process.exit(23);}
  process.exit(24);
});
JS
if run_worker demo "$SRC" "$OUT" 'node pids.js' > "$SB/pids.log" 2>&1; then exit 1; fi
grep -q PIDS_LIMIT_REACHED "$SB/pids.log" || { cat "$SB/pids.log"; exit 1; }
[[ -z $(docker ps -aq --filter "ancestor=$IMAGE") ]]
safe_rm_rf "$SB/state/demo" "$OUT"
# Dependencies are fetched with network but without scripts; the dependency's
# postinstall then runs exactly once, in the offline build phase.
docker network create --label sandbox.role=build "$NET" >/dev/null
mkdir -p "$SB/dep/package" "$SRC/vendor"
cat > "$SB/dep/package/package.json" <<'JSON'
{"name":"sandbox-dep","version":"1.0.0","scripts":{"postinstall":"node postinstall.js"}}
JSON
cat > "$SB/dep/package/postinstall.js" <<'JS'
const fs = require('fs');
fs.appendFileSync(process.env.INIT_CWD + '/lifecycle.log',
  fs.readdirSync('/sys/class/net').sort().join(',') + '\n');
JS
tar -czf "$SRC/vendor/sandbox-dep-1.0.0.tgz" -C "$SB/dep" package
# A native addon: node-gyp must build it offline from the image's headers.
mkdir -p "$SB/addon/package"
cat > "$SB/addon/package/package.json" <<'JSON'
{"name":"tiny-addon","version":"1.0.0","main":"index.js","gypfile":true}
JSON
echo '{"targets":[{"target_name":"tiny","sources":["tiny.c"]}]}' > "$SB/addon/package/binding.gyp"
cat > "$SB/addon/package/tiny.c" <<'C'
#include <node_api.h>
static napi_value Hi(napi_env env, napi_callback_info info) {
    napi_value r; napi_create_string_utf8(env, "NATIVE", NAPI_AUTO_LENGTH, &r); return r;
}
static napi_value Init(napi_env env, napi_value exports) {
    napi_value f; napi_create_function(env, NULL, 0, Hi, NULL, &f);
    napi_set_named_property(env, exports, "hi", f); return exports;
}
NAPI_MODULE(NODE_GYP_MODULE_NAME, Init)
C
echo "module.exports = require('./build/Release/tiny.node');" > "$SB/addon/package/index.js"
tar -czf "$SRC/vendor/tiny-addon-1.0.0.tgz" -C "$SB/addon" package
cat > "$SRC/package.json" <<'JSON'
{"name":"security-fixture","version":"1.0.0","dependencies":{
  "sandbox-dep":"file:vendor/sandbox-dep-1.0.0.tgz","tiny-addon":"file:vendor/tiny-addon-1.0.0.tgz"}}
JSON
load_execution_policy() {
    RUN_PROFILE=worker RUN_IMAGE=$IMAGE RUN_TIMEOUT=60 RUN_MEMORY=256 RUN_PIDS=64 RUN_CPUS=1
    RUN_FETCH_NETWORK=$NET RUN_NPM_REGISTRY=https://registry.npmjs.org/ RUN_OUTPUT_MB=2048
}
validate_fetch_network "$NET"
run_worker demo "$SRC" "$OUT" 'test -f node_modules/sandbox-dep/package.json && mkdir dist && node -e "process.stdout.write(require(\"tiny-addon\").hi())" > dist/index.html' > "$SB/deps.log" 2>&1 || { cat "$SB/deps.log"; exit 1; }
[[ $(cat "$OUT/dist/index.html") == NATIVE ]]
[[ $(cat "$OUT/lifecycle.log") == lo ]] || { echo "lifecycle ran with network or twice:"; cat "$OUT/lifecycle.log"; exit 1; }
[[ ! -e $OUT/.sandbox-npm-cache ]]
safe_rm_rf "$SB/state/demo" "$OUT"
# The output is a host bind mount: polling bounds its size and free space.
printf '{"name":"security-fixture","version":"1.0.0"}\n' > "$SRC/package.json"
rm -rf "$SRC/vendor"
load_execution_policy() {
    RUN_PROFILE=worker RUN_IMAGE=$IMAGE RUN_TIMEOUT=60 RUN_MEMORY=256 RUN_PIDS=32 RUN_CPUS=1
    RUN_FETCH_NETWORK=none RUN_NPM_REGISTRY=https://registry.npmjs.org/ RUN_OUTPUT_MB=2
}
started=$SECONDS
if SANDBOX_WATCH_INTERVAL=1 run_worker demo "$SRC" "$OUT" 'head -c 8000000 /dev/zero > big; sleep 50' > "$SB/big.log" 2>&1; then exit 1; fi
grep -q 'stopped: output' "$SB/big.log" || { cat "$SB/big.log"; exit 1; }
(( SECONDS - started < 30 )) || { echo "output limit did not stop the worker early"; exit 1; }
[[ -z $(docker ps -aq --filter "ancestor=$IMAGE") ]]
safe_rm_rf "$SB/state/demo" "$OUT"
if SANDBOX_WATCH_INTERVAL=1 SANDBOX_MIN_FREE_MB=999999999 run_worker demo "$SRC" "$OUT" 'sleep 50' > "$SB/free.log" 2>&1; then exit 1; fi
grep -q 'stopped: output' "$SB/free.log" || { cat "$SB/free.log"; exit 1; }
[[ -z $(docker ps -aq --filter "ancestor=$IMAGE") ]]
safe_rm_rf "$SB/state/demo" "$OUT"
# Real policy loader: root-owned parents accepted; writable policy and symlink rejected.
docker run --rm -i -v "$ROOT:/repo:ro" --entrypoint /bin/bash "$IMAGE" -s <<'SCRIPT'
set -euo pipefail
source /repo/deploy/lib/common.sh
source /repo/deploy/lib/runner.sh
mkdir -p /etc/sandbox/projects
printf 'profile=worker\nimage=fixture@sha256:%064d\n' 0 > /etc/sandbox/projects/demo.conf
load_execution_policy demo
chmod 666 /etc/sandbox/projects/demo.conf
if load_execution_policy demo; then exit 1; fi
chmod 644 /etc/sandbox/projects/demo.conf
ln -s demo.conf /etc/sandbox/projects/link.conf
if load_execution_policy link; then exit 1; fi
SCRIPT
printf 'PASS worker: two phases (dependency scripts and node-gyp only offline), no source in build, no host paths/socket, timeout/OOM/PID/output-size/free-space failures remove container, native build and next attempt succeed; root-owned policy guards\n'
