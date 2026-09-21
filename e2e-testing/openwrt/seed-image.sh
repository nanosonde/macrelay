#!/bin/sh
# Seed a freshly downloaded OpenWrt disk image with everything the e2e run
# needs: lab addressing, a permissive lab firewall, an SSH key, macrelay.sh
# and its configuration.
#
# The image is a partitioned disk, so the rootfs is reached through an
# offset loop device. Doing this offline avoids driving the serial console
# interactively on first boot.
set -eu

IMAGE="$1"

VM_WAN_IP4="${VM_WAN_IP4:-192.168.178.2}"
VM_WAN_GW4="${VM_WAN_GW4:-192.168.178.1}"
VM_WAN_IP6="${VM_WAN_IP6:-2001:db8:f412::2}"
VM_WAN_GW6="${VM_WAN_GW6:-2001:db8:f412::1}"
VM_LAN_IP4="${VM_LAN_IP4:-10.10.30.2}"
VM_LAN_IP6="${VM_LAN_IP6:-2001:db8:f412::a}"
VM_LAN_PREFIX6="${VM_LAN_PREFIX6:-2001:db8:f412::/64}"
VM_CONTROL_IP="${VM_CONTROL_IP:-198.18.1.50}"
MACRELAY_INT_PREFIX4="${MACRELAY_INT_PREFIX4:-10.10.10}"
MACRELAY_RESERVED_OCTETS="${MACRELAY_RESERVED_OCTETS:-0 1 2 4 5 10 254 255}"
# The whole ISP /64, because in passthrough mode the downstream hosts hold
# addresses from it rather than from a prefix of their own.
MACRELAY_INT_PREFIX6="${MACRELAY_INT_PREFIX6:-2001:db8:f412:}"
MACRELAY_PROXY_NDP="${MACRELAY_PROXY_NDP:-1}"
MACRELAY_PROVISION_IPV6="${MACRELAY_PROVISION_IPV6:-1}"
MACRELAY_UNIFY_MAC="${MACRELAY_UNIFY_MAC:-1}"

LAN_PREFIX4="${VM_WAN_GW4%.*}"

log() { echo "[seed] $*"; }

# Partition device nodes (loop0p2) are not created inside a container, so
# map the rootfs partition by byte offset instead.
start_sector="$(partx -g -o START -n 2 "$IMAGE" | tr -d ' ')"
sector_count="$(partx -g -o SECTORS -n 2 "$IMAGE" | tr -d ' ')"
if [ -z "$start_sector" ] || [ -z "$sector_count" ]; then
    log "could not read the rootfs partition table entry"
    exit 1
fi

LOOP="$(losetup --find --show \
    --offset "$((start_sector * 512))" \
    --sizelimit "$((sector_count * 512))" "$IMAGE")"
trap 'umount /mnt/rootfs 2>/dev/null || true; losetup -d "$LOOP" 2>/dev/null || true' EXIT

e2fsck -p -f "$LOOP" >/dev/null 2>&1 || true
mkdir -p /mnt/rootfs
mount -t ext4 "$LOOP" /mnt/rootfs
mkdir -p /mnt/rootfs/etc/uci-defaults /mnt/rootfs/etc/init.d /mnt/rootfs/usr/sbin /mnt/rootfs/root

# ---- networking -------------------------------------------------------
cat > /mnt/rootfs/etc/uci-defaults/98-e2e-network <<EOF
#!/bin/sh
# eth0 faces the simulated FRITZ!Box, eth1 is the downstream LAN the hosts
# sit on and eth2 the harness. The generated br-lan would otherwise claim
# eth0.
while uci -q delete network.@device[0]; do :; done

uci -q batch <<UCI
set network.lan.proto='static'
set network.lan.device='eth1'
set network.lan.ipaddr='${VM_LAN_IP4}'
set network.lan.netmask='255.255.255.0'
# The same /64 the FRITZ!Box serves. The hosts keep addresses from it, so
# this box is a member of that prefix on both interfaces rather than a
# router between two of them.
set network.lan.ip6addr='${VM_LAN_IP6}/64'
set network.lan.ip6assign='0'
delete network.lan.gateway
delete network.lan.dns

set network.wan='interface'
set network.wan.device='eth0'
set network.wan.proto='static'
set network.wan.ipaddr='${VM_WAN_IP4}'
set network.wan.netmask='255.255.255.0'
set network.wan.gateway='${VM_WAN_GW4}'
set network.wan.dns='${VM_WAN_GW4}'

set network.wan6='interface'
set network.wan6.device='eth0'
set network.wan6.proto='static'
set network.wan6.ip6addr='${VM_WAN_IP6}/64'
set network.wan6.ip6gw='${VM_WAN_GW6}'
delete network.wan6.ip6prefix

set network.control='interface'
set network.control.device='eth2'
set network.control.proto='static'
set network.control.ipaddr='${VM_CONTROL_IP}'
set network.control.netmask='255.255.255.0'
delete network.control.gateway
delete network.control.dns
commit network
UCI

# An address on the downstream LAN from the shared /64, and a default route
# for the hosts to point at. It is deliberately not advertised here: the
# FRITZ!Box owns the router advertisement on this /64, and a second one
# would give the hosts a competing default route.
uci -q batch <<UCI
set dhcp.lan.interface='lan'
set dhcp.lan.ignore='1'
set dhcp.lan.ra='disabled'
set dhcp.lan.dhcpv6='disabled'
set dhcp.wan='dhcp'
set dhcp.wan.interface='wan'
set dhcp.wan.ignore='1'
set dhcp.control='dhcp'
set dhcp.control.interface='control'
set dhcp.control.ignore='1'
commit dhcp
UCI

# Lab box: no masquerading anywhere, so the 1:1 NAT is the only translation
# in the path, and nothing filters the traffic under test.
uci -q batch <<UCI
set firewall.@defaults[0].input='ACCEPT'
set firewall.@defaults[0].output='ACCEPT'
set firewall.@defaults[0].forward='ACCEPT'
set firewall.@defaults[0].flow_offloading='0'
commit firewall
UCI

i=0
while uci -q get firewall.@zone[\$i] >/dev/null 2>&1; do
    uci -q set firewall.@zone[\$i].input='ACCEPT'
    uci -q set firewall.@zone[\$i].output='ACCEPT'
    uci -q set firewall.@zone[\$i].forward='ACCEPT'
    uci -q set firewall.@zone[\$i].masq='0'
    uci -q set firewall.@zone[\$i].mtu_fix='0'
    i=\$((i + 1))
done
uci -q add_list firewall.@zone[0].network='control'
uci -q commit firewall

# In the real deployment the hosts and the ISP router share one layer-2
# segment. Here they do not: the ISP router is a bridge away, so a host
# could never resolve its address by NDP and its replies would have nowhere
# to go. This box stands in for the router on that segment, which is what a
# passthrough setup looks like from the hosts' side.
sysctl -qw net.ipv6.conf.eth1.proxy_ndp=1 2>/dev/null || true
ip -6 neigh replace proxy '${VM_WAN_GW6}' dev eth1 2>/dev/null || true

# Both of this box's interfaces hold the shared /64 as a connected route, so
# traffic for the ISP router's own address would otherwise be treated as
# on-link on the downstream side and delivered back where it came from. A
# host route pins it to the upstream interface, where it actually is.
ip -6 route replace '${VM_WAN_GW6}/128' dev eth0 2>/dev/null || true
exit 0
EOF

# ---- macrelay ---------------------------------------------------------
macrelay-conf.sh > /mnt/rootfs/etc/macrelay.conf

cat > /mnt/rootfs/etc/init.d/macrelay <<'EOF'
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=95
STOP=10

start_service() {
    procd_open_instance
    procd_set_param command /usr/sbin/macrelay.sh
    procd_set_param respawn 3600 5 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
chmod +x /mnt/rootfs/etc/init.d/macrelay

if [ -f /artifacts/macrelay.sh ]; then
    cp /artifacts/macrelay.sh /mnt/rootfs/usr/sbin/macrelay.sh
    chmod +x /mnt/rootfs/usr/sbin/macrelay.sh
    log "staged macrelay.sh"
else
    log "WARNING: /artifacts/macrelay.sh missing (use 'just e2e-deploy' later)"
fi

# Left disabled: the harness installs kmod-macvlan and starts it explicitly
# so the first run is observable.
cat > /mnt/rootfs/etc/uci-defaults/99-e2e-macrelay <<'EOF'
#!/bin/sh
[ -x /usr/sbin/macrelay.sh ] && /etc/init.d/macrelay enable
exit 0
EOF

chmod +x /mnt/rootfs/etc/uci-defaults/98-e2e-network \
         /mnt/rootfs/etc/uci-defaults/99-e2e-macrelay

log "guest LAN ${VM_LAN_IP4} + ${VM_LAN_IP6}/64 from ${VM_LAN_PREFIX6}"

# ---- harness access ---------------------------------------------------
if [ -f /artifacts/ssh/id_ed25519.pub ]; then
    mkdir -p /mnt/rootfs/etc/dropbear
    cp /artifacts/ssh/id_ed25519.pub /mnt/rootfs/etc/dropbear/authorized_keys
    chmod 600 /mnt/rootfs/etc/dropbear/authorized_keys
    log "installed ssh authorized key"
else
    log "WARNING: no ssh public key at /artifacts/ssh/id_ed25519.pub"
fi

sync
umount /mnt/rootfs
losetup -d "$LOOP"
trap - EXIT
log "image seeded"
