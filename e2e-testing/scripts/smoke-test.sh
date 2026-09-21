#!/usr/bin/env bash
# End-to-end assertions against the running lab.
set -uo pipefail

cd "$(dirname "$0")/.."

# Compose reads .env by itself; the assertions have to use the same values.
if [[ -f .env ]]; then set -a; . ./.env; set +a; fi

COUNT="${E2E_CLIENT_COUNT:-100}"
FIRST="${E2E_CLIENT_FIRST:-10.10.10.11}"
LAN_PREFIX="${FIRST%.*}"
FIRST_OCTET="${FIRST##*.}"
LAST_OCTET=$(( FIRST_OCTET + COUNT - 1 ))
INTERNET_IP4="${E2E_INTERNET_IP4:-198.51.100.1}"
INTERNET_IP6="${E2E_INTERNET_IP6:-2001:db8:ffff::1}"
INTERNET_NAME6="${E2E_INTERNET_NAME:-internet.lab}"
ISP_PREFIX="${E2E_FRITZ_IP4:-192.168.178.1}"; ISP_PREFIX="${ISP_PREFIX%.*}"
FRITZ_IP6="${E2E_FRITZ_IP6:-2001:db8:f412::1}"
# The ISP /64 the hosts keep, with the host octet in hex as the last hextet.
HOST_PREFIX6="${E2E_ISP_SUBNET6_PREFIX:-2001:db8:f412}"

# The GUA of host octet N, matching the client simulator's convention.
gua6() { printf '%s::100:%x' "$HOST_PREFIX6" "$1"; }

pass=0; fail=0

check() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '  ok    %s\n' "$label"; pass=$((pass + 1))
    else
        printf '  FAIL  %s\n' "$label"; fail=$((fail + 1))
    fi
}

report() {  # a check whose measured value is worth printing
    local label="$1" want="$2" got="$3"
    if [[ "$got" == "$want" ]]; then
        printf '  ok    %s (%s)\n' "$label" "$got"; pass=$((pass + 1))
    else
        printf '  FAIL  %s (want %s, got %s)\n' "$label" "$want" "$got"; fail=$((fail + 1))
    fi
}

vm()      { ./scripts/vm-ssh.sh "$@"; }
in_c()    { local svc="$1"; shift; docker compose exec -T "$svc" "$@"; }
clients() { in_c clients sh -c "$1"; }

ping_all4() {
    clients "
        ok=0
        for i in \$(seq ${FIRST_OCTET} ${LAST_OCTET}); do
            ping -c1 -W2 -I ${LAN_PREFIX}.\$i ${INTERNET_IP4} >/dev/null 2>&1 \
                || ping -c1 -W2 -I ${LAN_PREFIX}.\$i ${INTERNET_IP4} >/dev/null 2>&1 \
                && ok=\$((ok+1))
        done
        echo \$ok"
}

# Every host pings the endpoint from its own GUA, and the count is what the
# far end saw. The literal address is used rather than the name: a DNS
# lookup per host would add a second round trip to each of 100 pings, and
# the lookup is asserted separately below. A first attempt may time out
# while the proxy-NDP path is still converging, so each host retries once.
ping_all6() {
    clients "
        ok=0
        for i in \$(seq ${FIRST_OCTET} ${LAST_OCTET}); do
            ping -6 -c1 -W4 -I ${HOST_PREFIX6}::100:\$(printf '%x' \$i) ${INTERNET_IP6} >/dev/null 2>&1 \
                || ping -6 -c1 -W4 -I ${HOST_PREFIX6}::100:\$(printf '%x' \$i) ${INTERNET_IP6} >/dev/null 2>&1 \
                && ok=\$((ok+1))
        done
        echo \$ok"
}

echo "== controller =="
check "macrelay.sh is running in the guest" vm 'pgrep -f macrelay.sh'
check "nftables 1:1 NAT table exists"       vm 'nft list table ip nat_1to1'
check "IPv4 discovery set exists"           vm 'nft list set ip macrelay_seen hosts4'
check "IPv6 discovery set exists"           vm 'nft list set ip6 macrelay_seen hosts6'

echo
echo "== discovery: ${COUNT} hosts on the shared downstream LAN =="
# The hosts have to send something before either family is provisioned: IPv6
# is discovered from the passthrough traffic itself, IPv4 from the source
# addresses the downstream router forwards.
ping_all4 >/dev/null
ping_all6 >/dev/null

# Provisioning 100 interfaces on an emulated guest is not instant; wait for
# the controller to converge rather than guessing at a sleep. Both the
# interface count and a mapping at each end of the range have to be there
# before the rest is worth asserting.
deadline=$(( $(date +%s) + ${E2E_PROVISION_TIMEOUT:-600} ))
while :; do
    macvlans=$(vm 'ip -o link show type macvlan | wc -l' | tr -d ' \r')
    snat_now=$(vm 'nft list map ip nat_1to1 map_snat 2>/dev/null | tr "," "\n" | grep -cE "[0-9]+ : [0-9]+"' | tr -d ' \r')
    [[ "$macvlans" == "$COUNT" && "$snat_now" == "$COUNT" ]] && break
    (( $(date +%s) > deadline )) && break
    sleep 5
done

seen=$(vm "nft list set ip macrelay_seen hosts4 | tr ',' '\n' | grep -cE '${LAN_PREFIX}\.[0-9]+'" | tr -d ' \r')
report "IPv4 clients discovered from forwarded traffic" "$COUNT" "$seen"

gua_seen=$(vm "nft list set ip6 macrelay_seen hosts6 | tr ',' '\n' | grep -cE '$(printf '%s' "$HOST_PREFIX6" | tr 'A-Z' 'a-z')::100:'" | tr -d ' \r')
report "host GUAs discovered on the downstream LAN" "$COUNT" "$gua_seen"

report "one macvlan per host" "$COUNT" "$macvlans"

rules=$(vm 'ip rule show | grep -c 10000' | tr -d ' \r')
report "one IPv4 policy rule per host" "$COUNT" "$rules"

# A host's two families must end up on one interface: the ISP router has to
# see one device per host, and a duplicate identity would show up here as
# more macvlans than hosts, or mappings without a rule behind them.
snat=$(vm "nft list map ip nat_1to1 map_snat | tr ',' '\n' | grep -cE '${LAN_PREFIX}\.[0-9]+ : ${ISP_PREFIX}\.[0-9]+'" | tr -d ' \r')
report "one SNAT mapping per host" "$COUNT" "$snat"

dnat=$(vm "nft list map ip nat_1to1 map_dnat | tr ',' '\n' | grep -cE '${ISP_PREFIX}\.[0-9]+ : ${LAN_PREFIX}\.[0-9]+'" | tr -d ' \r')
report "one DNAT mapping per host" "$COUNT" "$dnat"

check "mapping is host-octet preserving at the bottom of the range" \
    vm "nft list map ip nat_1to1 map_snat | grep -q '${LAN_PREFIX}.${FIRST_OCTET} : ${ISP_PREFIX}.${FIRST_OCTET}'"
check "mapping is host-octet preserving at the top of the range" \
    vm "nft list map ip nat_1to1 map_snat | grep -q '${LAN_PREFIX}.${LAST_OCTET} : ${ISP_PREFIX}.${LAST_OCTET}'"

echo
echo "== IPv4: every host reaches the internet through its own address =="
report "hosts reaching ${INTERNET_IP4}" "$COUNT" "$(ping_all4 | tr -d ' \r')"

capture="$(mktemp)"
in_c fritzbox sh -c "timeout 12 tcpdump -lni any 'icmp and host ${INTERNET_IP4}' -c 8" \
    > "$capture" 2>/dev/null &
cap_pid=$!
sleep 2
clients "ping -c3 -W2 -I ${LAN_PREFIX}.${FIRST_OCTET} ${INTERNET_IP4} >/dev/null 2>&1" || true
wait "$cap_pid" 2>/dev/null
check "far end sees the host as ${ISP_PREFIX}.${FIRST_OCTET}" \
    grep -q "${ISP_PREFIX}.${FIRST_OCTET} >" "$capture"
check "far end never sees the internal address" \
    bash -c "! grep -q '${LAN_PREFIX}.${FIRST_OCTET} >' '${capture}'"
rm -f "$capture"

echo
echo "== IPv6: passthrough, proxied per host and never translated =="
report "hosts reaching ${INTERNET_IP6}" "$COUNT" "$(ping_all6 | tr -d ' \r')"

# The name resolves through the ISP router, which is only reachable at all
# because MacRelay carries the hosts' traffic there.
first_gua="$(printf '%s::100:%x' "$HOST_PREFIX6" "$FIRST_OCTET")"
check "the internet endpoint resolves through the ISP router" \
    clients "ping -6 -c1 -W2 -I ${first_gua} ${INTERNET_NAME6}"

# The hosts keep the ISP /64, so the ISP router must resolve each GUA on its
# LAN. That resolution is what proxy NDP on the per-host macvlan provides,
# and without it the return path simply does not exist - there is no route
# anywhere covering the host addresses. The lab itself proxies the ISP
# router's own address on the downstream segment (it is a bridge away
# there), so that one entry is not a host's.
proxied=$(vm "ip -6 neigh show proxy | grep -vE '^${FRITZ_IP6} ' | wc -l" | tr -d ' \r')
report "GUAs published to the ISP router via proxy NDP" "$COUNT" "$proxied"

resolve=$(in_c fritzbox sh -c "
    ok=0
    for i in \$(seq ${FIRST_OCTET} ${LAST_OCTET}); do
        ping -6 -c1 -W2 ${HOST_PREFIX6}::100:\$(printf '%x' \$i) >/dev/null 2>&1 && ok=\$((ok+1))
    done
    echo \$ok" | tr -d ' \r')
report "ISP router reaches every host GUA directly" "$COUNT" "$resolve"

check "the ISP router holds no route for a host address" \
    bash -c "! in_c fritzbox sh -c 'ip -6 route show | grep -q \"${HOST_PREFIX6}::100:\"'"

echo
echo "== identity: one MAC per host for both families =="
# The point of the unified key: a host's 1:1 IPv4 address and its GUA must be
# answered by the same MAC, and it is the ISP router that sees both answers.
# The neighbour entries are refreshed with an explicit ping first, because a
# stale entry from before a re-provision would carry the old MAC.
same_mac=0
for octet in "${FIRST_OCTET}" "${LAST_OCTET}"; do
    pair=$(in_c fritzbox sh -c "
        ping -6 -c2 -W3 $(gua6 "$octet") >/dev/null 2>&1
        ping -c2 -W3 ${ISP_PREFIX}.${octet} >/dev/null 2>&1
        ip -6 neigh flush dev eth0 >/dev/null 2>&1
        ip neigh flush dev eth0 >/dev/null 2>&1
        ping -6 -c1 -W3 $(gua6 "$octet") >/dev/null 2>&1
        ping -c1 -W3 ${ISP_PREFIX}.${octet} >/dev/null 2>&1
        m6=\$(ip -6 neigh show to $(gua6 "$octet") | grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -1)
        m4=\$(ip neigh show to ${ISP_PREFIX}.${octet} | grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -1)
        echo \"\$m6|\$m4\"" | tr -d ' \r')
    [[ "$pair" == *'|'* && "${pair%%|*}" != "" && "${pair%%|*}" == "${pair##*|}" ]] \
        && same_mac=$((same_mac + 1))
done
report "IPv4 and IPv6 of one host share one MAC (both ends of range)" "2" "$same_mac"

shared=$(vm "ip -6 neigh show proxy | grep -cE '$(printf '%s' "$HOST_PREFIX6" | tr 'A-Z' 'a-z')::100:'" | tr -d ' \r')
report "every host has its own proxy NDP entry" "$COUNT" "$shared"

echo
echo "== regressions =="
# One macvlan accepting the ISP router's RA per host swamps the main table.
defaults6=$(vm 'ip -6 route show default | wc -l' | tr -d ' \r')
report "IPv6 default routes in the guest's main table" "1" "$defaults6"
stray6=$(vm 'ip -6 -o addr show scope global | grep -c "mv" || true' | tr -d ' \r')
report "stray SLAAC addresses on macvlans" "0" "$stray6"
check "no host address was NATed on IPv6" \
    bash -c "! vm 'nft list tables' | grep -qE 'ip6.*nat'"
check "no host has two interfaces (duplicate identities reconciled)" \
    vm "test \"\$(ip -o link show type macvlan | wc -l)\" -eq $COUNT"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
