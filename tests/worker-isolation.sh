#!/usr/bin/env bash
# Real worker boundary tests. Policy ownership is tested separately in a root container.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SB=$(mktemp -d /tmp/sandbox-worker-security.XXXXXXXX)
trap 'rm -rf "$SB"' EXIT
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
}
cmd='test "$(cat /sys/fs/cgroup/memory.max)" = 268435456 && test "$(cat /sys/fs/cgroup/pids.max)" = 32 && grep -q "NoNewPrivs:.*1" /proc/self/status && test ! -e /var/run/docker.sock && test ! -e /srv/state && test ! -e /srv/sites && test ! -e /root/.ssh && test ! -e /srv/deploy && test ! -e /source/.env && ! touch /source/injected && mkdir dist && echo SAFE > dist/index.html'
run_worker demo "$SRC" "$OUT" "$cmd" > "$SB/build.log" 2>&1 || { cat "$SB/build.log"; exit 1; }
[[ $(cat "$OUT/dist/index.html") == SAFE ]]
[[ ! -e $SRC/injected ]]
safe_rm_rf "$SB/state/demo" "$OUT"
# Timeout leaves no container/cgroup and a subsequent attempt can succeed.
load_execution_policy() {
    RUN_PROFILE=worker RUN_IMAGE=$IMAGE RUN_TIMEOUT=2 RUN_MEMORY=256 RUN_PIDS=32 RUN_CPUS=1
}
if run_worker demo "$SRC" "$OUT" 'sleep 300 & wait' > "$SB/timeout.log" 2>&1; then exit 1; fi
[[ -z $(docker ps -aq --filter "ancestor=$IMAGE") ]]
safe_rm_rf "$SB/state/demo" "$OUT"
load_execution_policy() {
    RUN_PROFILE=worker RUN_IMAGE=$IMAGE RUN_TIMEOUT=20 RUN_MEMORY=256 RUN_PIDS=32 RUN_CPUS=1
}
run_worker demo "$SRC" "$OUT" 'printf "int main(){return 0;}" > /tmp/hello.cc; g++ /tmp/hello.cc -o /tmp/hello; /tmp/hello; mkdir dist; echo NEXT > dist/index.html' > "$SB/next.log" 2>&1
[[ $(cat "$OUT/dist/index.html") == NEXT ]]
safe_rm_rf "$SB/state/demo" "$OUT"
cat > "$SRC/oom.js" <<'JS'
const held=[]; setInterval(()=>held.push(Buffer.alloc(16*1024*1024,1)),10);
JS
load_execution_policy() {
    RUN_PROFILE=worker RUN_IMAGE=$IMAGE RUN_TIMEOUT=20 RUN_MEMORY=128 RUN_PIDS=32 RUN_CPUS=1
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
printf 'PASS worker: readonly source, no host paths/socket, timeout/OOM/PID failures remove container, native build and next attempt succeed; root-owned policy guards\n'
