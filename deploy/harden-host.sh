#!/usr/bin/env bash
# Host hardening that matters for a public test server:
#   - unattended security upgrades, with a nightly reboot when a new kernel
#     needs one: container escapes almost always go through kernel bugs;
#   - SSH by key only (root too), no keyboard-interactive or empty passwords.
#
# SSH is changed only when root already has a key in authorized_keys: the
# admin logs in as root, and turning passwords off without a key would lock
# them out. The drop-in is validated with `sshd -t` and removed if invalid.
#
#   harden-host.sh [--dry-run]
#   SANDBOX_AUTO_REBOOT=false        no automatic reboot
#   SANDBOX_REBOOT_TIME=04:30        reboot time when one is needed
#   SANDBOX_SSH_HARDENING=false      leave SSH alone
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=deploy/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

APT_CONF_DIR=${SANDBOX_APT_CONF_DIR:-/etc/apt/apt.conf.d}
SSHD_CONFIG=${SANDBOX_SSHD_CONFIG:-/etc/ssh/sshd_config}
SSHD_DROPIN=${SANDBOX_SSHD_DROPIN:-/etc/ssh/sshd_config.d/10-sandbox-hardening.conf}
ROOT_KEYS=${SANDBOX_ROOT_KEYS:-/root/.ssh/authorized_keys}
AUTO_REBOOT=${SANDBOX_AUTO_REBOOT:-true}
REBOOT_TIME=${SANDBOX_REBOOT_TIME:-04:30}

DRY=false
[[ ${1-} == --dry-run ]] && DRY=true
[[ $# -le 1 && ( $# -eq 0 || $DRY == true ) ]] || die 'Usage: harden-host.sh [--dry-run]'
[[ $AUTO_REBOOT == true || $AUTO_REBOOT == false ]] || die "SANDBOX_AUTO_REBOOT: true или false"
[[ $REBOOT_TIME =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "SANDBOX_REBOOT_TIME: ЧЧ:ММ"

# write_file <path> <mode> <content> — atomic, reports instead in dry run.
write_file() {
    local path=$1 mode=$2 content=$3 tmp
    if [[ -f $path && $(cat "$path") == "$content" ]]; then
        echo "   $path: без изменений"
        return 0
    fi
    if [[ $DRY == true ]]; then
        echo "   would write $path"
        return 0
    fi
    mkdir -p "$(dirname "$path")"
    tmp=$(mktemp "$path.XXXXXX")
    printf '%s\n' "$content" > "$tmp"
    chmod "$mode" "$tmp"
    mv -T "$tmp" "$path"
    echo "   $path: записан"
}

log "Автоматические обновления безопасности"
if [[ $DRY == false ]] && ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y unattended-upgrades
fi
write_file "$APT_CONF_DIR/20auto-upgrades" 644 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";'
write_file "$APT_CONF_DIR/52sandbox-unattended-upgrades" 644 "// Managed by sandbox-infra (deploy/harden-host.sh).
Unattended-Upgrade::Automatic-Reboot \"$AUTO_REBOOT\";
Unattended-Upgrade::Automatic-Reboot-Time \"$REBOOT_TIME\";
Unattended-Upgrade::Remove-Unused-Kernel-Packages \"true\";"

log "SSH только по ключу"
if [[ ${SANDBOX_SSH_HARDENING:-true} != true ]]; then
    echo "   пропущено: SANDBOX_SSH_HARDENING=${SANDBOX_SSH_HARDENING}"
    exit 0
fi
if ! grep -qsE '^[[:space:]]*(ssh-|ecdsa-|sk-)' "$ROOT_KEYS"; then
    warn "у root нет ключа в $ROOT_KEYS — пароли не отключаю, чтобы не запереть вход."
    warn "Добавь ключ и запусти $0 ещё раз."
    exit 0
fi
if ! grep -qsE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSHD_CONFIG"; then
    warn "$SSHD_CONFIG не подключает sshd_config.d — настрой SSH вручную"
    exit 0
fi
# sshd takes the first value it sees; drop-ins are read in name order, so
# 10-... wins over e.g. cloud-init's 50-cloud-init.conf.
write_file "$SSHD_DROPIN" 644 '# Managed by sandbox-infra (deploy/harden-host.sh).
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin prohibit-password
X11Forwarding no
MaxAuthTries 3'
[[ $DRY == true ]] && exit 0
if ! sshd -t -f "$SSHD_CONFIG"; then
    rm -f "$SSHD_DROPIN"
    die "sshd -t не принял конфигурацию — изменения SSH откатил"
fi
if [[ -d /run/systemd/system ]]; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd
    echo "   sshd перечитал конфигурацию; текущая сессия не прерывается"
fi
