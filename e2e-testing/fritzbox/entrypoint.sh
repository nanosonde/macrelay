#!/bin/sh
# Simulated ISP router. Serves the "FRITZ!Box LAN" with IPv4 DHCP and IPv6
# RA/SLAAC, and NATs everything towards the real uplink so the OpenWrt guest
# can install packages.
#
# IPv6 is passthrough end to end: the downstream hosts keep addresses from
# this box's own /64. MacRelay answers NDP for them on the LAN, so from here
# they look like ordinary LAN devices and no route for them is needed.
#
# There is deliberately no DHCPv6 server. Every downstream client is
# statically addressed, so the only DHCPv6 traffic on the wire would be the
# simulated hosts requesting addresses that the lab then has to ignore - and
# MacRelay, which does not speak DHCPv6, would be blamed for the churn.
set -eu

LAN_ADDRESS4="${LAN_ADDRESS4:-192.168.178.1}"
LAN_PREFIX4="${LAN_PREFIX4:-192.168.178.0/24}"
LAN_ADDRESS6="${LAN_ADDRESS6:-2001:db8:f412::1}"
DHCP_START="${DHCP_START:-192.168.178.100}"
DHCP_END="${DHCP_END:-192.168.178.199}"
DHCP_NETMASK="${DHCP_NETMASK:-255.255.255.0}"
DHCP_LEASE_TIME="${DHCP_LEASE_TIME:-12h}"
TRANSIT_VIA4="${TRANSIT_VIA4:-192.168.178.2}"
RELAY_SUBNET4="${RELAY_SUBNET4:-10.10.10.0/24}"
INTERNET_IP4="${INTERNET_IP4:-198.51.100.1}"
INTERNET_IP6="${INTERNET_IP6:-2001:db8:ffff::1}"
UPLINK_NAT="${UPLINK_NAT:-1}"
UPSTREAM_DNS="${UPSTREAM_DNS:-}"

log() { echo "[fritzbox] $*"; }

# Compose does not guarantee which ethX a service lands on, so resolve the
# LAN port by the address it was given.
LAN_IF="$(ip -4 -o addr show | awk -v a="$LAN_ADDRESS4" \
    '{ split($4, p, "/"); if (p[1] == a) { print $2; exit } }')"
if [ -z "$LAN_IF" ]; then
    log "FATAL: no interface carries ${LAN_ADDRESS4}"
    exit 1
fi
log "LAN port ${LAN_IF} (${LAN_ADDRESS4}, ${LAN_ADDRESS6})"

# ---- fake internet --------------------------------------------------
# A dummy interface stands in for "somewhere on the internet", so tests can
# check which source address the far end actually sees.
ip link show internet0 >/dev/null 2>&1 || ip link add internet0 type dummy
ip link set internet0 up
ip addr replace "${INTERNET_IP4}/24" dev internet0
ip -6 addr replace "${INTERNET_IP6}/64" dev internet0

# ---- routes back into the lab ---------------------------------------
# Nothing needs to be routed for IPv6: the hosts hold addresses from this
# box's own /64 and MacRelay answers NDP for them on this LAN.
#
# IPv4 is different: every downstream host is 1:1 mapped onto this LAN by
# MacRelay, so each one is directly reachable at its own address here and
# no route for them exists. The route below only covers the shared segment
# itself, so a reply to the downstream router's WAN address - the next hop
# all unmapped traffic converges on - finds its way back.
ip route replace "$RELAY_SUBNET4" via "$TRANSIT_VIA4" dev "$LAN_IF"

# ---- uplink -----------------------------------------------------------
if [ "$UPLINK_NAT" = "1" ]; then
    iptables -t nat -F POSTROUTING
    for net in "$LAN_PREFIX4" "$RELAY_SUBNET4" "${INTERNET_IP4%.*}.0/24"; do
        iptables -t nat -A POSTROUTING -d "$net" -j RETURN
    done
    iptables -t nat -A POSTROUTING -o "$LAN_IF" -j MASQUERADE
    log "uplink NAT enabled on ${LAN_IF}"
fi

# ---- dnsmasq ----------------------------------------------------------
mkdir -p /etc/dnsmasq.d /var/lib/misc
cat > /etc/dnsmasq.conf <<EOF
interface=${LAN_IF}
# Not bind-interfaces: the hosts reach this resolver through a next hop, so
# the address they ask on is whatever routed them here, and pinning the
# listener would leave them without an answer.
bind-dynamic
log-facility=-
log-dhcp
domain=fritz.box
local=/fritz.box/
expand-hosts

# Resolves to the dummy "internet" endpoints above.
address=/internet.lab/${INTERNET_IP4}
address=/internet.lab/${INTERNET_IP6}

dhcp-authoritative
dhcp-range=${DHCP_START},${DHCP_END},${DHCP_NETMASK},${DHCP_LEASE_TIME}
dhcp-option=option:router,${LAN_ADDRESS4}
dhcp-option=option:dns-server,${LAN_ADDRESS4}

# Router advertisement only, so the segment has a default router even though
# nothing here hands out addresses. The downstream hosts are statically
# addressed from this same /64, which is what passthrough means.
enable-ra
ra-param=${LAN_IF},60,1800
EOF

if [ -n "$UPSTREAM_DNS" ]; then
    printf 'no-resolv\nserver=%s\n' "$UPSTREAM_DNS" >> /etc/dnsmasq.conf
    log "forwarding DNS to ${UPSTREAM_DNS}"
fi

log "starting dnsmasq (pool ${DHCP_START}-${DHCP_END})"
exec dnsmasq --keep-in-foreground --conf-file=/etc/dnsmasq.conf
