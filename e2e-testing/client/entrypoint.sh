#!/bin/sh
# Simulated downstream hosts.
#
# Unlike the earlier lab, this is not one container with CLIENT_COUNT extra
# addresses: every host gets its own macvlan child of eth0, so its traffic
# reaches the downstream LAN with its own source MAC. That is what makes the
# IPv6 passthrough path testable at all -- proxy NDP is per-MAC, and hosts
# behind one shared MAC could never be told apart.
#
# Each host carries:
#   IPv4  10.10.10.N/24            its address on the downstream LAN, used as
#                                  the ping source
#   IPv6  <HOST_PREFIX6>:100:<hex> its GUA, inside the prefix MacRelay's RA
#                                  advertises on that LAN
#   MAC   52:54:11:00:00:N         distinct per host, so the ISP router ends
#                                  up with CLIENT_COUNT devices, not one
#
# The host octet N drives all three, so one host's IPv4 and IPv6 addresses
# identify each other -- exactly what macrelay.sh's gua_v4 reads, and what
# lets the ISP router see one MAC per device for both families.
#
# Each host also gets its own routing tables, so its traffic leaves through
# its own macvlan rather than through the container's single default route.
set -eu

GATEWAY4="${GATEWAY4:-10.10.10.1}"
# The box between the hosts and the ISP router, and the only IPv6 next hop
# they can reach: the ISP router is not on this segment, so its /64 is
# shared across a hop rather than being one flat broadcast domain.
GATEWAY6="${GATEWAY6:-2001:db8:f412::a}"
CLIENT_COUNT="${CLIENT_COUNT:-100}"
CLIENT_FIRST="${CLIENT_FIRST:-10.10.10.11}"
# The FRITZ!Box /64 itself: passthrough means the hosts keep addresses from
# the same prefix the ISP router sits on, so it resolves and delivers to
# them on-link and no route anywhere covers them.
HOST_PREFIX6="${HOST_PREFIX6:-2001:db8:f412}"
# DNS over IPv6, from the ISP router the hosts share the prefix with: the
# IPv4 resolver is a routed hop away and would answer through the 1:1
# mapping, which is not what the DNS assertion is about.
DNS6="${DNS6:-2001:db8:f412::1}"
MAC_BASE="${MAC_BASE:-52:54:11:00:00:00}"
RULE_PREF=30000

log() { echo "[clients] $*"; }

IF="$(ip -4 -o route show default 2>/dev/null | awk '{print $5; exit}')"
[ -n "$IF" ] || IF="$(ip -4 -o addr show scope global | awk '{print $2; exit}')"
[ -n "$IF" ] || { log "FATAL: no usable interface"; exit 1; }

# This container is only the carrier for the host macvlans; its own eth0
# must not look like a host to MacRelay, and Docker's ULA default route
# would only compete with the per-host ones installed below.
ip -6 route show default 2>/dev/null | awk '/via f[cd]/ {print $3}' \
    | while read -r gw; do ip -6 route del default via "$gw" 2>/dev/null || true; done

# The carrier's own ULA addresses would otherwise answer NDP for itself and
# blur the per-host picture on the segment.
ip -6 addr flush dev "$IF" scope global 2>/dev/null || true

# Names for the simulated internet endpoints resolve through the ISP router
# over IPv6 -- the address it is reachable at from this segment.
printf 'nameserver %s\n' "$DNS6" > /etc/resolv.conf

prefix4="${CLIENT_FIRST%.*}"
first4="${CLIENT_FIRST##*.}"
last4=$((first4 + CLIENT_COUNT - 1))

mac_for() {                         # last byte of the MAC for host offset $1
    base="${MAC_BASE%:*}"
    printf '%s:%02x' "$base" "$(( (first4 + $1) & 255 ))"
}

if ! ip link add mvprobe link "$IF" type macvlan mode bridge 2>/dev/null; then
    log "FATAL: macvlan is not available in this container"
    exit 1
fi
ip link del mvprobe 2>/dev/null || true

# ---- create the hosts -------------------------------------------------
i=0
while [ "$i" -lt "$CLIENT_COUNT" ]; do
    oct=$((first4 + i))
    name="mvhost${oct}"
    tid=$((oct + 1000))

    ip link del "$name" 2>/dev/null || true
    ip link add "$name" link "$IF" type macvlan mode bridge
    ip link set "$name" address "$(mac_for "$i")"
    # No RA and no autoconf: the addresses below are the ones under test, and
    # an extra SLAAC address per host would only blur the assertions.
    sysctl -qw "net.ipv6.conf.${name}.disable_ipv6=0" 2>/dev/null || true
    sysctl -qw "net.ipv6.conf.${name}.accept_ra=0" 2>/dev/null || true
    sysctl -qw "net.ipv6.conf.${name}.autoconf=0" 2>/dev/null || true
    ip link set "$name" up

    ip -4 addr replace "${prefix4}.${oct}/24" dev "$name"
    # nodad: the lab asserts reachability, not duplicate address detection,
    # and DAD would stall a hundred hosts on a busy segment.
    ip -6 addr replace "${HOST_PREFIX6}::100:$(printf '%x' "$oct")/64" \
        dev "$name" nodad

    # Per-host tables, so a packet sourced from this host genuinely leaves
    # through this host's interface. The connected route has to be repeated
    # in the table: without it the default route there would capture traffic
    # to another host in the same /64 and send it upstream instead of
    # delivering it on the segment.
    ip route replace "${prefix4}.0/24" dev "$name" scope link table "$tid"
    ip route replace default via "$GATEWAY4" dev "$name" onlink table "$tid"
    ip -6 route replace "${HOST_PREFIX6}::/64" dev "$name" scope link table "$tid"
    ip -6 route replace default via "$GATEWAY6" dev "$name" onlink table "$tid"
    ip rule del from "${prefix4}.${oct}" table "$tid" 2>/dev/null || true
    ip rule add from "${prefix4}.${oct}" table "$tid" pref "$RULE_PREF"
    ip -6 rule del from "${HOST_PREFIX6}::100:$(printf '%x' "$oct")" table "$tid" 2>/dev/null || true
    ip -6 rule add from "${HOST_PREFIX6}::100:$(printf '%x' "$oct")" table "$tid" pref "$RULE_PREF"

    i=$((i + 1))
done
log "created ${CLIENT_COUNT} hosts ${prefix4}.${first4}-${prefix4}.${last4}"
log "IPv6 from ${HOST_PREFIX6}::100:<hex octet>, gateways ${GATEWAY4} / ${GATEWAY6}"

exec sleep infinity
