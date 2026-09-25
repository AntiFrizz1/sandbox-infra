#!/usr/bin/env bash
# Negative regressions, separate from the immutable historical PoCs.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"
SB=$(make_sandbox)
trap 'rm -rf "$SB"' EXIT
export SANDBOX_GIT_ROOT="$SB/git" SANDBOX_APPS_ROOT="$SB/apps"
export SANDBOX_SITES_ROOT="$SB/sites" SANDBOX_STATE_ROOT="$SB/state"
export SANDBOX_CADDY_DIR="$SB/caddy" SANDBOX_MIGRATION_BACKUPS="$SB/backups"
# shellcheck source=deploy/lib/common.sh
source "$ROOT/deploy/lib/common.sh"
# shellcheck source=deploy/lib/project.sh
source "$ROOT/deploy/lib/project.sh"
# shellcheck source=deploy/lib/release.sh
source "$ROOT/deploy/lib/release.sh"
mkdir -p "$SB/outside" "$SB/state/demo/logs" "$SB/git/demo.git" "$SB/sites/demo"
echo SYNTHETIC > "$SB/outside/private.log"
echo valid > "$SB/state/demo/logs/abc123.log"
for sha in ../../../outside/private /tmp/private ABC abc.z "$(printf 'a%.0s' {1..65})"; do
    assert_fail "reject log identifier $sha" bash "$ROOT/deploy/logs-app.sh" demo "$sha"
done
assert_ok 'short log prefix works' bash "$ROOT/deploy/logs-app.sh" demo ab
ln -s "$SB/outside/private.log" "$SB/state/demo/logs/def.log"
assert_fail 'reject external log symlink' bash "$ROOT/deploy/logs-app.sh" demo def
printf 'date\tmain\t../../../outside/private\tok\t1s\n' > "$SB/state/demo/deploys.tsv"
assert_fail 'reject history traversal' bash "$ROOT/deploy/logs-app.sh" demo
rm "$SB/state/demo/logs/def.log"
mv "$SB/state/demo/logs" "$SB/outside/logs"
ln -s "$SB/outside/logs" "$SB/state/demo/logs"
assert_fail 'reject substituted log directory' bash "$ROOT/deploy/logs-app.sh" demo abc
rm "$SB/state/demo/logs"
mv "$SB/outside/logs" "$SB/state/demo/logs"

mkdir -p "$SB/outside/revert-data"
echo KEEP > "$SB/outside/revert-data/marker"
ln -s ../../outside/revert-data "$SB/sites/demo/current"
assert_fail 'revert rejects escaping current before moving' bash "$ROOT/deploy/migrate.sh" sites --revert
assert_exists 'outside data untouched' "$SB/outside/revert-data/marker"
assert_ok 'original current untouched' test -L "$SB/sites/demo/current"
rm "$SB/sites/demo/current"
mkdir -p "$SB/sites/demo/releases/abc"
echo safe > "$SB/sites/demo/releases/abc/index.html"
ln -s releases/abc "$SB/sites/demo/current"
mkdir "$SB/sites/demo.flat"
assert_fail 'unexpected flat directory stops revert' bash "$ROOT/deploy/migrate.sh" sites --revert
assert_exists 'release preserved after refusal' "$SB/sites/demo/releases/abc/index.html"
rmdir "$SB/sites/demo.flat"
echo SYNTHETIC > "$SB/sites/demo/releases/abc/.env"
assert_fail 'rollback rejects unsafe saved release' rollback_release demo abc
assert_eq 'rollback leaves current unchanged' releases/abc "$(readlink "$SB/sites/demo/current")"
assert_ok 'sanitize already migrated site' bash "$ROOT/deploy/migrate.sh" sites
assert_missing 'active env removed' "$SB/sites/demo/current/.env"
assert_missing 'unsafe old release removed from public mount' "$SB/sites/demo/releases/abc"
assert_exists 'safe index retained' "$SB/sites/demo/current/index.html"
old=$(readlink "$SB/sites/demo/current")
assert_ok 'sanitize idempotent' bash "$ROOT/deploy/migrate.sh" sites
assert_eq 'safe current stable' "$old" "$(readlink "$SB/sites/demo/current")"
backup=$(find "$SB/backups" -name site.tar -print -quit)
mkdir -m 700 "$SB/restore"
assert_ok 'private backup restores' tar -xf "$backup" -C "$SB/restore"
assert_eq 'original evidence retained privately' SYNTHETIC "$(cat "$SB/restore/releases/abc/.env")"
assert_eq 'backup file private' 600 "$(stat -c %a "$backup")"

mkdir -p "$SB/caddy"
echo SECRET > "$SB/source"
echo old > "$SB/caddy/.env"
chmod 644 "$SB/caddy/.env"
assert_ok 'atomic secret installation' install_private "$SB/source" "$SB/caddy/.env"
assert_eq 'old mode repaired' 600 "$(stat -c %a "$SB/caddy/.env")"
rm "$SB/caddy/.env"
ln -s "$SB/outside/private.log" "$SB/caddy/.env"
assert_fail 'secret destination link rejected' install_private "$SB/source" "$SB/caddy/.env"
assert_eq 'external target unchanged' SYNTHETIC "$(cat "$SB/outside/private.log")"
rm "$SB/caddy/.env"
assert_ok 'permission repair' bash "$ROOT/deploy/repair-permissions.sh"
assert_eq 'project state private' 700 "$(stat -c %a "$SB/state/demo")"
assert_eq 'existing log private' 600 "$(stat -c %a "$SB/state/demo/logs/abc123.log")"
assert_eq 'public output readable' 644 "$(stat -c %a "$SB/sites/demo/current/index.html")"
# Migration takes the same persistent project lock, including revert.
(
    lock_app demo
    touch "$SB/locked"
    sleep 2
) &
locker=$!
while [[ ! -f $SB/locked ]]; do sleep .02; done
assert_fail 'migration cannot cross active deploy lock' env SANDBOX_LOCK_TIMEOUT=.1 bash "$ROOT/deploy/migrate.sh" sites --revert
assert_eq 'locked migration leaves current intact' "$old" "$(readlink "$SB/sites/demo/current")"
wait "$locker"
# Dry run does not create backup or rewrite public content.
before=$(find "$SB/sites" "$SB/backups" -printf '%p %m %s\n' | sort)
assert_ok 'migration dry run' bash "$ROOT/deploy/migrate.sh" sites --dry-run
assert_eq 'dry run keeps public/backup trees' "$before" "$(find "$SB/sites" "$SB/backups" -printf '%p %m %s\n' | sort)"
# The hook publishes under umask 077; a proxy without CAP_DAC_OVERRIDE
# still has to traverse the new site and releases directories.
mkdir -p "$SB/pub-src"
echo PUBLIC > "$SB/pub-src/index.html"
( umask 077; publish_release fresh 0123abc "$SB/pub-src" ) >/dev/null
assert_eq 'new site dir traversable' 755 "$(stat -c %a "$SB/sites/fresh")"
assert_eq 'new releases dir traversable' 755 "$(stat -c %a "$SB/sites/fresh/releases")"

# Worker output next to a publish_dir=. build: dependencies are not published.
mkdir -p "$SB/pub-dot/node_modules/dep" "$SB/pub-dot/assets/node_modules"
echo PUBLIC > "$SB/pub-dot/index.html"
echo DEP > "$SB/pub-dot/node_modules/dep/index.js"
echo VENDORED > "$SB/pub-dot/assets/node_modules/lib.js"
publish_release fresh 0456def "$SB/pub-dot" >/dev/null
assert_missing 'top-level node_modules not published' "$SB/sites/fresh/current/node_modules"
assert_exists 'nested node_modules kept (it is site content)' "$SB/sites/fresh/current/assets/node_modules/lib.js"

# Re-running bootstrap replaces the image line instead of appending another.
printf 'TIMEWEB_API_TOKEN=x\nSANDBOX_CADDY_IMAGE=old@sha256:1\n' > "$SB/image.env"
chmod 640 "$SB/image.env"
assert_ok 'set env value' set_env_value "$SB/image.env" SANDBOX_CADDY_IMAGE 'new@sha256:2'
assert_ok 'set env value again' set_env_value "$SB/image.env" SANDBOX_CADDY_IMAGE 'new@sha256:2'
assert_eq 'single image line, other keys kept' $'TIMEWEB_API_TOKEN=x\nSANDBOX_CADDY_IMAGE=new@sha256:2' "$(cat "$SB/image.env")"
assert_eq 'env mode kept' 640 "$(stat -c %a "$SB/image.env")"
assert_fail 'newline in value refused' set_env_value "$SB/image.env" SANDBOX_CADDY_IMAGE $'a\nEVIL=1'
finish
