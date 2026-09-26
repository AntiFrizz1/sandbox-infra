#!/usr/bin/env bash
# Firewall behaviour with real connections, inside a throwaway privileged
# container that builds its own network namespaces. The host's own iptables
# are never touched.
#
#   host ── br-test ─┬─ ctr   172.30.0.2  (the "compromised" container)
#     │  172.30.0.1  └─ ctr2  172.30.0.3  (another project behind Caddy)
#     ├─ v-vpc ── vpc   10.88.0.2 + 169.254.169.254  (private net, metadata)
#     └─ v-inet ─ inet  198.51.100.2                (the internet)
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# shellcheck source=tests/lib.sh
source "$HERE/lib.sh"
if ! docker info >/dev/null 2>&1; then
    echo "SKIP Docker недоступен: проверка firewall"
    exit 0
fi
SB=$(make_sandbox)
trap 'rm -rf "$SB"' EXIT

docker run --rm -i --privileged -v "$ROOT:/repo:ro" debian:bookworm-slim bash -s > "$SB/fw.log" 2>&1 <<'SCRIPT'
set -euo pipefail
apt-get update -qq && apt-get install -y -qq iptables iproute2 python3-minimal >/dev/null
echo 1 > /proc/sys/net/ipv4/ip_forward
link() {  # link <netns> <host-if> <host-ip/len> <ns-ip/len> [bridge]
    ip netns add "$1"
    ip link add "$2" type veth peer name eth0 netns "$1"
    if [[ -n ${5-} ]]; then ip link set "$2" master "$5"; else ip addr add "$3" dev "$2"; fi
    ip link set "$2" up
    ip -n "$1" addr add "$4" dev eth0
    ip -n "$1" link set eth0 up
    ip -n "$1" link set lo up
    ip -n "$1" route add default via "${3%/*}"
}
ip link add br-test type bridge
ip addr add 172.30.0.1/24 dev br-test
ip link set br-test up
link ctr  v-ctr  172.30.0.1/24 172.30.0.2/24 br-test
link ctr2 v-ctr2 172.30.0.1/24 172.30.0.3/24 br-test
link vpc  v-vpc  10.88.0.1/24  10.88.0.2/24
link inet v-inet 198.51.100.1/24 198.51.100.2/24
ip -n vpc addr add 169.254.169.254/32 dev eth0
ip route add 169.254.169.254/32 via 10.88.0.2
# Docker's own wiring: FORWARD consults DOCKER-USER first.
iptables -N DOCKER-USER
iptables -A FORWARD -j DOCKER-USER

serve() { ${1:+ip netns exec "$1"} python3 -c '
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((sys.argv[1], 7000)); s.listen()
while True:
    c, _ = s.accept(); c.sendall(b"ok"); c.close()' "$2" & }
serve "" 172.30.0.1
serve "" 10.88.0.1
serve ctr2 172.30.0.3
serve vpc 10.88.0.2
serve vpc 169.254.169.254
serve inet 198.51.100.2
sleep 1
# reach <from-netns|host> <ip> — prints yes/no
reach() {
    local cmd=(python3 -c 'import socket,sys; socket.create_connection((sys.argv[1],7000),timeout=2).recv(2)' "$2")
    if [[ $1 == host ]]; then "${cmd[@]}" 2>/dev/null; else ip netns exec "$1" "${cmd[@]}" 2>/dev/null; fi \
        && echo yes || echo no
}
matrix() {
    printf '%s ' "$(reach ctr 172.30.0.1)" "$(reach ctr 10.88.0.1)" "$(reach ctr 10.88.0.2)" \
        "$(reach ctr 169.254.169.254)" "$(reach ctr 198.51.100.2)" "$(reach ctr 172.30.0.3)" \
        "$(reach host 172.30.0.3)"
    echo
}
echo "BEFORE $(matrix)"
bash /repo/deploy/firewall.sh >/dev/null
first=$(iptables-save | grep -v '^#' | sed 's/\[[0-9:]*\]//')
bash /repo/deploy/firewall.sh >/dev/null
second=$(iptables-save | grep -v '^#' | sed 's/\[[0-9:]*\]//')
[[ $first == "$second" ]] && echo "IDEMPOTENT yes" || echo "IDEMPOTENT no"
echo "AFTER $(matrix)"
SCRIPT
rc=$?
assert_eq 'firewall scenario ran' 0 "$rc"
[[ $rc -eq 0 ]] || cat "$SB/fw.log"
# Columns: host-bridge-ip host-other-ip vpc metadata internet same-bridge host→container
assert_eq 'everything reachable before the firewall' 'yes yes yes yes yes yes yes' \
    "$(sed -n 's/^BEFORE //p' "$SB/fw.log" | xargs)"
after=$(sed -n 's/^AFTER //p' "$SB/fw.log" | xargs)
read -r to_host to_host_other to_vpc to_meta to_inet to_peer host_to_ctr <<< "$after"
assert_eq 'container cannot reach the host' no "$to_host"
assert_eq 'container cannot reach other host addresses' no "$to_host_other"
assert_eq 'container cannot reach the private network' no "$to_vpc"
assert_eq 'container cannot reach cloud metadata' no "$to_meta"
assert_eq 'container still reaches the internet' yes "$to_inet"
assert_eq 'containers on the bridge still talk (Caddy → app)' yes "$to_peer"
assert_eq 'host still reaches containers (health checks)' yes "$host_to_ctr"
assert_eq 're-running produces the same ruleset' yes "$(sed -n 's/^IDEMPOTENT //p' "$SB/fw.log")"
finish
