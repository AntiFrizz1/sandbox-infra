#!/usr/bin/env bash
# Keeps containers away from the host itself and from private networks, so
# code execution in a test app does not reach SSH, host services, other
# machines in the provider's private network or cloud metadata. Internet
# access stays open (bots, APIs, the worker's npm fetch).
#
#   SANDBOX-INPUT  (first in INPUT)        container → any address of the host:
#                                          dropped, except replies to connections
#                                          the host opened itself.
#   SANDBOX-EGRESS (from DOCKER-USER)      container → private and link-local
#                                          ranges outside Docker bridges: dropped.
#
# Traffic between containers on Docker bridges (Caddy → app) is untouched.
# Containers on user-defined networks resolve names through Docker's embedded
# DNS, which forwards from the host namespace, so DNS keeps working.
# IPv4 only: Docker bridges here have no IPv6.
#
# Idempotent: the chains are flushed and refilled on every run. Rules do not
# survive a reboot; sandbox-firewall.service re-applies them after Docker.
set -euo pipefail
IPT=${SANDBOX_IPTABLES:-iptables}
PRIVATE=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16)

fresh_chain() {
    "$IPT" -w -N "$1" 2>/dev/null || true
    "$IPT" -w -F "$1"
}
# jump_first <parent> <match...> — insert the jump once, at the top.
jump_first() {
    local parent=$1
    shift
    "$IPT" -w -C "$parent" "$@" 2>/dev/null || "$IPT" -w -I "$parent" 1 "$@"
}

fresh_chain SANDBOX-INPUT
"$IPT" -w -A SANDBOX-INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
"$IPT" -w -A SANDBOX-INPUT -i docker0 -j DROP
"$IPT" -w -A SANDBOX-INPUT -i br-+ -j DROP
jump_first INPUT -j SANDBOX-INPUT

# Docker creates DOCKER-USER and jumps to it first in FORWARD; creating it
# here first is harmless, Docker keeps an existing chain.
"$IPT" -w -N DOCKER-USER 2>/dev/null || true
fresh_chain SANDBOX-EGRESS
"$IPT" -w -A SANDBOX-EGRESS -o docker0 -j RETURN
"$IPT" -w -A SANDBOX-EGRESS -o br-+ -j RETURN
"$IPT" -w -A SANDBOX-EGRESS -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
for net in "${PRIVATE[@]}"; do
    "$IPT" -w -A SANDBOX-EGRESS -d "$net" -j DROP
done
jump_first DOCKER-USER -i docker0 -j SANDBOX-EGRESS
jump_first DOCKER-USER -i br-+ -j SANDBOX-EGRESS
echo "==> firewall: containers cannot reach the host or private networks"
