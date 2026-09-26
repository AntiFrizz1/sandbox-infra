#!/usr/bin/env bash
# Host hardening in a throwaway container with a real sshd: passwords go off
# only when root has a key, the result is what sshd actually applies, and a
# configuration sshd rejects is rolled back.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"
if ! docker info >/dev/null 2>&1; then
    echo "SKIP Docker недоступен: проверка закалки хоста"
    exit 0
fi
SB=$(make_sandbox)
trap 'rm -rf "$SB"' EXIT

docker run --rm -i -v "$ROOT:/repo:ro" debian:bookworm-slim bash -s > "$SB/harden.log" 2>&1 <<'SCRIPT'
set -uo pipefail
apt-get update -qq && apt-get install -y -qq openssh-server >/dev/null
mkdir -p /run/sshd
# Like Ubuntu cloud images: a later drop-in that turns passwords back on.
echo 'PasswordAuthentication yes' > /etc/ssh/sshd_config.d/50-cloud-init.conf
H=/repo/deploy/harden-host.sh
DROPIN=/etc/ssh/sshd_config.d/10-sandbox-hardening.conf
effective() { sshd -T 2>/dev/null | grep -E "^$1 " | cut -d' ' -f2; }

bash "$H" --dry-run >/dev/null
echo "DRY_APT $( [ -e /etc/apt/apt.conf.d/52sandbox-unattended-upgrades ] && echo yes || echo no )"

bash "$H"
echo "NOKEY_DROPIN $( [ -e "$DROPIN" ] && echo yes || echo no )"
echo "NOKEY_PASSWORD $(effective passwordauthentication)"
echo "UPGRADES $(grep -c '"1"' /etc/apt/apt.conf.d/20auto-upgrades)"
echo "REBOOT $(grep -o 'Automatic-Reboot "[a-z]*"' /etc/apt/apt.conf.d/52sandbox-unattended-upgrades)"
echo "INSTALLED $(dpkg -s unattended-upgrades >/dev/null 2>&1 && echo yes || echo no)"

mkdir -p /root/.ssh && echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAISYNTHETIC admin' > /root/.ssh/authorized_keys
bash "$H"
echo "KEY_PASSWORD $(effective passwordauthentication)"
echo "KEY_ROOT $(effective permitrootlogin)"
echo "KEY_KBD $(effective kbdinteractiveauthentication)"
echo "RERUN $(bash "$H" | grep -c 'без изменений')"

# A configuration sshd rejects: the drop-in is removed again.
rm -f "$DROPIN"
echo 'NoSuchOption yes' > /etc/ssh/sshd_config.d/20-broken.conf
bash "$H" >/dev/null 2>&1; echo "BROKEN_RC $?"
echo "BROKEN_DROPIN $( [ -e "$DROPIN" ] && echo yes || echo no )"
SCRIPT
val() { sed -n "s/^$1 //p" "$SB/harden.log"; }
assert_eq 'dry run writes nothing' no "$(val DRY_APT)"
assert_eq 'without a root key SSH is left alone' no "$(val NOKEY_DROPIN)"
assert_eq 'passwords stay on without a key (no lockout)' yes "$(val NOKEY_PASSWORD)"
assert_eq 'unattended-upgrades installed' yes "$(val INSTALLED)"
assert_eq 'daily lists and upgrades enabled' 2 "$(val UPGRADES)"
assert_eq 'reboot for new kernels enabled' 'Automatic-Reboot "true"' "$(val REBOOT)"
assert_eq 'with a root key passwords are off, despite cloud-init' no "$(val KEY_PASSWORD)"
assert_eq 'root only by key' without-password "$(val KEY_ROOT)"
assert_eq 'keyboard-interactive off' no "$(val KEY_KBD)"
assert_eq 're-run changes nothing' 3 "$(val RERUN)"
assert_ok 'rejected configuration fails' test "$(val BROKEN_RC)" -ne 0
assert_eq 'rejected drop-in rolled back' no "$(val BROKEN_DROPIN)"
[[ $_tests_failed -eq 0 ]] || tail -30 "$SB/harden.log"
finish
