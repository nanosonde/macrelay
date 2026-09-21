#!/bin/sh
# Emit the guest's /etc/macrelay.conf from the lab environment. Used both
# when seeding the disk image and by `just e2e-deploy`, so a changed address
# does not require re-seeding.
set -eu

VM_WAN_GW4="${VM_WAN_GW4:-192.168.178.1}"
VM_WAN_GW6="${VM_WAN_GW6:-2001:db8:f412::1}"
MACRELAY_INT_PREFIX4="${MACRELAY_INT_PREFIX4:-10.10.10}"
MACRELAY_RESERVED_OCTETS="${MACRELAY_RESERVED_OCTETS:-0 1 2 4 5 10 254 255}"
MACRELAY_INT_PREFIX6="${MACRELAY_INT_PREFIX6:-2001:db8:f412:}"
MACRELAY_PROXY_NDP="${MACRELAY_PROXY_NDP:-1}"
MACRELAY_PROVISION_IPV6="${MACRELAY_PROVISION_IPV6:-1}"
MACRELAY_UNIFY_MAC="${MACRELAY_UNIFY_MAC:-1}"

cat <<EOF
# Sourced by macrelay.sh; overrides the defaults compiled into the script.
PARENT_IF="eth0"
INT_IF="eth1"
FRITZ_GW4="${VM_WAN_GW4}"
LAN_PREFIX4="${VM_WAN_GW4%.*}"
# The downstream router's LAN. Its IPv4 clients are routed (and NATed) by
# that router, so they are discovered from the source addresses arriving on
# the shared segment.
INT_PREFIX4="${MACRELAY_INT_PREFIX4}"
# Octets in use by the lab infrastructure itself and by Docker's own IPAM.
RESERVED_OCTETS="${MACRELAY_RESERVED_OCTETS}"
FRITZ_GW6="${VM_WAN_GW6}"
# IPv6 passthrough: the hosts keep the FRITZ!Box /64 and their own MACs
# reach the downstream segment, so GUAs are provisioned per host and
# published upstream via proxy NDP.
INT_PREFIX6="${MACRELAY_INT_PREFIX6}"
IPV6_PROXY_NDP=${MACRELAY_PROXY_NDP}
PROVISION_IPV6=${MACRELAY_PROVISION_IPV6}
# The hosts are addressed from their IPv4 octet, so one host's GUA and its
# 1:1 address identify each other and end up on one interface.
UNIFY_MAC=${MACRELAY_UNIFY_MAC}
# Deliberately generous: a full assertion run provisions 100 hosts twice,
# resolves each GUA by proxy NDP and tears the lot down again, which takes
# far longer than a short timeout would allow. Teardown is exercised by
# lowering these by hand, not by racing the suite.
IDLE_TIMEOUT=3600
ABSENT_TIMEOUT=1800
GC_INTERVAL=120
DISCO_INTERVAL=5
EOF
