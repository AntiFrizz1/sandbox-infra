#!/usr/bin/env bash
# Retention: removes only finished or abandoned artefacts, skips busy projects,
# keeps recent backups, and reports low disk space through its exit status.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"
SB=$(make_sandbox)
trap 'rm -rf "$SB"' EXIT
export SANDBOX_GIT_ROOT="$SB/git" SANDBOX_SITES_ROOT="$SB/sites" SANDBOX_STATE_ROOT="$SB/state"
export SANDBOX_MIGRATION_BACKUPS="$SB/backups" SANDBOX_ALERT_FREE_MB=1
# Never prune the Docker cache of the machine running the tests.
export SANDBOX_PRUNE_DOCKER=false
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
# shellcheck source=deploy/lib/common.sh
source "$ROOT/deploy/lib/common.sh"

git init -q --bare "$SB/git/demo.git"
prepare_state demo
SITE="$SB/sites/demo" STATE="$SB/state/demo"
mkdir -p "$SITE/releases/abc" "$SITE/releases/.abc.Xy12Zq" "$STATE/build/src" "$STATE/worker-output"
echo LIVE > "$SITE/releases/abc/index.html"
ln -s releases/abc "$SITE/current"
ln -s releases/abc "$SITE/.current.4242.tmp"
echo partial > "$STATE/deploys.tsv.a1b2c3d4"
for i in {1..25}; do
    sha=$(printf '%x' "$i")
    echo log > "$STATE/logs/$sha.log"
    printf 'date\tmain\t%s\tok\t1s\n' "$sha" >> "$STATE/deploys.tsv"
done
now=$(date +%s)
for age in 0 1 2 10 60; do
    dir="$SB/backups/demo/migration.age$age"
    mkdir -p "$dir"
    touch -d "@$(( now - age * 86400 ))" "$dir"
done

run_maintenance() { bash "$ROOT/deploy/maintenance.sh" "$@"; }

echo "== dry-run ничего не меняет =="
# Lock files are created even by a dry run (same lock as the real run); they hold no data.
tree() { find "$SB" -path "$SB/state/.locks" -prune -o -printf '%p\n' | sort; }
before=$(tree)
out=$(run_maintenance --dry-run 2>&1)
assert_eq 'dry run leaves the tree unchanged' "$before" "$(tree)"
assert_ok 'dry run reports the orphan staging' grep -q 'would remove staging' <<< "$out"

echo "== занятый проект пропускается =="
( lock_app demo; touch "$SB/locked"; sleep 3 ) &
locker=$!
while [[ ! -f $SB/locked ]]; do sleep .05; done
out=$(run_maintenance 2>&1)
assert_exists 'staging kept while a deploy runs' "$SITE/releases/.abc.Xy12Zq"
assert_exists 'build tree kept while a deploy runs' "$STATE/build/src"
assert_ok 'busy project reported' grep -q 'идёт операция' <<< "$out"
wait "$locker"

echo "== очистка =="
assert_ok 'maintenance succeeds' run_maintenance
assert_missing 'orphan staging removed' "$SITE/releases/.abc.Xy12Zq"
assert_missing 'temporary current link removed' "$SITE/.current.4242.tmp"
assert_missing 'abandoned build tree removed' "$STATE/build"
assert_missing 'abandoned worker output removed' "$STATE/worker-output"
assert_missing 'temporary journal removed' "$STATE/deploys.tsv.a1b2c3d4"
assert_eq 'published release untouched' LIVE "$(cat "$SITE/current/index.html")"
assert_eq 'deploy logs trimmed to twenty' 20 "$(find "$STATE/logs" -type f | wc -l)"
assert_ok 'bare repository still valid' git --git-dir="$SB/git/demo.git" rev-parse --git-dir
assert_eq 'three newest and recent backups kept' 'migration.age0 migration.age1 migration.age10 migration.age2' \
    "$(cd "$SB/backups/demo" && echo migration.*)"
assert_ok 'repeat run is a no-op' run_maintenance

echo "== мало места =="
SANDBOX_ALERT_FREE_MB=999999999 run_maintenance >/dev/null 2>&1
assert_eq 'low disk space exits with status 2' 2 "$?"
finish
