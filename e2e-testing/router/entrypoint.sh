#!/bin/sh
# Downstream router simulation -- the "gateway with NAT disabled" that
# MacRelay sits in front of.
#
#   IPv4 : plain forwarding, no NAT at all (IPV4_NAT=1 only for comparison)
#   IPv6 : passthrough. This box does not route, advertise or translate IPv6
#          at all; the hosts keep the ISP /64 and their frames cross it as if
#          it were a bridge. That is the whole difference from the routed
#          mode MacRelay used to be tested against, where this container was
#          a DHCPv6-PD client with a delegated prefix on its LAN.
#
# The container is router-on-a-stick: one interface carries both its WAN
# address (default route back to MacRelay) and its LAN address.
set -eu

WAN_ADDRESS4="${WAN_ADDRESS4:-10.10.10.5}"
WAN_GATEWAY4="${WAN_GATEWAY4:-10.10.30.2}"
LAN_ADDRESS4="${LAN_ADDRESS4:-10.10.10.1}"
LAN_SUBNET4="${LAN_SUBNET4:-10.10.10.0/24}"
IPV4_NAT="${IPV4_NAT:-0}"
IPV6_PASSTHROUGH="${IPV6_PASSTHROUGH:-1}"

log() { echo "[router] $*"; }

find_if() {
    ip -4 -o addr show | awk -v a="$1" \
        '{ split($4, p, "/"); if (p[1] == a) { print $2; exit } }'
}

# Router-on-a-stick: Docker assigns only the WAN address from compose, so the
# LAN address is added here on the same interface. Without it the clients have
# no gateway, and the return path from MacRelay has nowhere to land.
IF="$(find_if "$WAN_ADDRESS4")"
if [ -z "$IF" ]; then
    log "FATAL: no interface carries ${WAN_ADDRESS4}"
    exit 1
fi
ip addr replace "${LAN_ADDRESS4}/24" dev "$IF"
log "interface=${IF}  wan=${WAN_ADDRESS4}  lan=${LAN_ADDRESS4}"

# The runtime already applied forwarding through Compose's sysctls; retry
# here for the case where /proc/sys happens to be writable.
sysctl -qw net.ipv4.ip_forward=1 2>/dev/null || true

if [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]; then
    log "FATAL: IPv4 forwarding is off; the runtime rejected the sysctl"
    exit 1
fi

# Docker installs a default route for the segment; point IPv4 at the MacRelay
# box explicitly, since that is the next hop whose 1:1 mapping this tests.
ip route replace default via "$WAN_GATEWAY4" dev "$IF"

# --- IPv6 -------------------------------------------------------------
if [ "$IPV6_PASSTHROUGH" = "1" ]; then
    # Do not route, do not accept router advertisements, do not hold a ULA
    # from Docker: the hosts' own addresses and MACs have to cross this box
    # untouched for MacRelay's proxy NDP to mean anything.
    sysctl -qw net.ipv6.conf.all.forwarding=0 2>/dev/null || true
    sysctl -qw "net.ipv6.conf.${IF}.accept_ra=0" 2>/dev/null || true
    sysctl -qw "net.ipv6.conf.${IF}.autoconf=0" 2>/dev/null || true
    sysctl -qw "net.ipv6.conf.${IF}.forwarding=0" 2>/dev/null || true
    sysctl -qw "net.ipv6.conf.${IF}.disable_ipv6=1" 2>/dev/null || true
    ip -6 addr flush dev "$IF" scope global 2>/dev/null || true
    ip -6 route flush dev "$IF" 2>/dev/null || true
    log "IPv6 passthrough: not routing or translating IPv6 on ${IF}"
else
    log "FATAL: this lab only models IPv6 passthrough now; see the README"
    exit 1
fi

# --- IPv4 NAT (comparison only) ---------------------------------------
iptables -t nat -F POSTROUTING
if [ "$IPV4_NAT" = "1" ]; then
    log "WARNING: IPv4 NAT enabled -- this is the double-NAT case, not the lab default"
    iptables -t nat -A POSTROUTING -o "$IF" -s "$LAN_SUBNET4" -j MASQUERADE
else
    log "IPv4 NAT disabled (clients keep their own source addresses)"
fi

# This box runs no services of its own: it only has to exist, forward and
# stay reachable, so the entrypoint keeps the container alive.
log "router ready"
exec sleep infinity
