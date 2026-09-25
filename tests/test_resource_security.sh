#!/usr/bin/env bash
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib.sh
source "$ROOT/tests/lib.sh"
SB=$(make_sandbox)
trap 'rm -rf "$SB"' EXIT
export SANDBOX_STATE_ROOT="$SB/state" SANDBOX_SITES_ROOT="$SB/sites"
# shellcheck source=deploy/lib/common.sh
source "$ROOT/deploy/lib/common.sh"
prepare_state demo
python3 -c 'import sys;sys.stdout.write("x"*1000000)' | python3 "$ROOT/deploy/bounded-log.py" "$SB/log" 1024 > "$SB/output"
assert_eq 'log byte limit enforced' 1024 "$(wc -c < "$SB/log")"
assert_eq 'client output also bounded' 1024 "$(wc -c < "$SB/output")"
assert_ok 'truncation marked' grep -q 'output truncated' "$SB/log"
for i in {1..30}; do
    sha=$(printf '%x' "$i")
    echo log > "$SB/state/demo/logs/$sha.log"
    printf 'date\tmain\t%s\tok\t1s\n' "$sha" >> "$SB/state/demo/deploys.tsv"
done
assert_ok 'cleanup dry run' bash "$ROOT/deploy/cleanup-app.sh" demo --dry-run
assert_eq 'dry run retains all logs' 30 "$(find "$SB/state/demo/logs" -type f | wc -l)"
assert_ok 'cleanup completed logs' bash "$ROOT/deploy/cleanup-app.sh" demo
assert_eq 'twenty retained logs' 20 "$(find "$SB/state/demo/logs" -type f | wc -l)"
assert_exists 'last attempt retained' "$SB/state/demo/logs/1e.log"
ln -s "$SB/log" "$SB/state/demo/logs/ff.log"
assert_fail 'cleanup rejects symlink' bash "$ROOT/deploy/cleanup-app.sh" demo
assert_exists 'external log untouched' "$SB/log"
finish
