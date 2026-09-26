#!/usr/bin/env bash
# Policy resolution as root in a throwaway container (root ownership is part
# of the check): the project's own file wins, the shared default applies
# otherwise, and an untrusted project file never falls back silently.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"
if ! docker info >/dev/null 2>&1; then
    echo "SKIP Docker недоступен: проверка политик по умолчанию"
    exit 0
fi
SB=$(make_sandbox)
trap 'rm -rf "$SB"' EXIT

docker run --rm -i -v "$ROOT:/repo:ro" debian:bookworm-slim bash -s > "$SB/policy.log" 2>&1 <<'SCRIPT'
set -uo pipefail
export SANDBOX_POLICY_ROOT=/etc/sandbox/projects SANDBOX_POLICY_DEFAULTS=/etc/sandbox/defaults
source /repo/deploy/lib/common.sh
source /repo/deploy/lib/runner.sh
source /repo/deploy/lib/compose.sh
# The labelled build network exists on a real server; here docker is a stub.
docker() { [[ $1 == network ]] && echo build; }
IMG_DEFAULT="sha256:$(printf 'd%.0s' {1..64})"
IMG_OWN="sha256:$(printf 'e%.0s' {1..64})"
yes_no() { if "$@" >/dev/null 2>&1; then echo yes; else echo no; fi; }

mkdir -p /etc/sandbox/projects
echo "NONE_WORKER $(yes_no load_execution_policy demo)"
echo "NONE_COMPOSE $(yes_no load_compose_policy demo)"
echo "NONE_MESSAGE $(load_execution_policy demo 2>&1 | grep -c '/etc/sandbox/defaults/worker.conf')"

install_default_policies /repo/examples >/dev/null
echo "INSTALLED $(stat -c '%a %U' /etc/sandbox/defaults/worker.conf /etc/sandbox/defaults/compose.conf | xargs)"
echo "EMPTY_IMAGE $(yes_no load_execution_policy demo)"
set_env_value /etc/sandbox/defaults/worker.conf image "$IMG_DEFAULT"
echo "DEFAULT_WORKER $(load_execution_policy demo >/dev/null 2>&1 && echo "$RUN_IMAGE $RUN_FETCH_NETWORK")"
echo "DEFAULT_COMPOSE $(load_compose_policy demo >/dev/null 2>&1 && echo "$COMPOSE_MEMORY $COMPOSE_TIMEOUT")"

# The admin's edits survive a later install.
echo 'memory_mb=777' >> /etc/sandbox/defaults/compose.conf
install_default_policies /repo/examples >/dev/null
echo "KEPT $(grep -c '^memory_mb=777$' /etc/sandbox/defaults/compose.conf) $(grep -c "^image=$IMG_DEFAULT$" /etc/sandbox/defaults/worker.conf)"

# A project file overrides the default.
printf 'profile=worker\nimage=%s\nmemory_mb=1024\nfetch_network=none\n' "$IMG_OWN" > /etc/sandbox/projects/demo.conf
chmod 644 /etc/sandbox/projects/demo.conf
echo "OWN_WORKER $(load_execution_policy demo >/dev/null 2>&1 && echo "$RUN_IMAGE $RUN_MEMORY")"
echo "OTHER_PROJECT $(load_execution_policy other >/dev/null 2>&1 && echo "$RUN_IMAGE")"
# The wrong kind in a project file is refused, not replaced by the default.
echo "WRONG_KIND $(yes_no load_compose_policy demo)"

# An untrusted project file is an error, not a fallback to the default.
chmod 666 /etc/sandbox/projects/demo.conf
echo "UNTRUSTED_OWN $(yes_no load_execution_policy demo)"
rm /etc/sandbox/projects/demo.conf
ln -s /etc/sandbox/defaults/worker.conf /etc/sandbox/projects/demo.conf
echo "SYMLINK_OWN $(yes_no load_execution_policy demo)"
rm /etc/sandbox/projects/demo.conf

# An untrusted default is refused too.
chown nobody /etc/sandbox/defaults/worker.conf
echo "UNTRUSTED_DEFAULT $(yes_no load_execution_policy demo)"
SCRIPT
val() { sed -n "s/^$1 //p" "$SB/policy.log"; }
d="sha256:$(printf 'd%.0s' {1..64})"
e="sha256:$(printf 'e%.0s' {1..64})"
assert_eq 'no policy at all: worker refused' no "$(val NONE_WORKER)"
assert_eq 'no policy at all: compose refused' no "$(val NONE_COMPOSE)"
assert_eq 'refusal names the default policy path' 1 "$(val NONE_MESSAGE)"
assert_eq 'defaults installed root-owned 0644' '644 root 644 root' "$(val INSTALLED)"
assert_eq 'default worker without image refused' no "$(val EMPTY_IMAGE)"
assert_eq 'default worker policy applies' "$d sandbox_build" "$(val DEFAULT_WORKER)"
assert_eq 'default compose policy applies' '512 900' "$(val DEFAULT_COMPOSE)"
assert_eq 'reinstall keeps admin edits and image' '1 1' "$(val KEPT)"
assert_eq 'project policy overrides the default' "$e 1024" "$(val OWN_WORKER)"
assert_eq 'other projects still use the default' "$d" "$(val OTHER_PROJECT)"
assert_eq 'project file of the wrong kind refused' no "$(val WRONG_KIND)"
assert_eq 'untrusted project file: no silent fallback' no "$(val UNTRUSTED_OWN)"
assert_eq 'symlinked project file refused' no "$(val SYMLINK_OWN)"
assert_eq 'untrusted default refused' no "$(val UNTRUSTED_DEFAULT)"
[[ $_tests_failed -eq 0 ]] || tail -20 "$SB/policy.log"
finish
