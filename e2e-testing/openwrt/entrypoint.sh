#!/bin/sh
# Boot OpenWrt x86-64 under QEMU TCG with its three NICs bridged onto the
# container's Docker networks, so the guest is layer-2 adjacent to the
# simulated ISP router, the downstream LAN the hosts sit on, and the harness.
set -eu

OPENWRT_VERSION="${OPENWRT_VERSION:-25.12.5}"
ISP_CONTAINER_IP="${ISP_CONTAINER_IP:-192.168.178.4}"
LAN_CONTAINER_IP="${LAN_CONTAINER_IP:-10.10.30.4}"
CONTROL_CONTAINER_IP="${CONTROL_CONTAINER_IP:-198.18.1.20}"
CONTROL_GATEWAY="${CONTROL_GATEWAY:-198.18.1.1}"
VM_MAC_WAN="${VM_MAC_WAN:-52:54:00:12:34:56}"
VM_MAC_LAN="${VM_MAC_LAN:-52:54:00:12:34:57}"
VM_MAC_CONTROL="${VM_MAC_CONTROL:-52:54:00:12:34:58}"
VM_MEMORY="${VM_MEMORY:-512}"
VM_CPUS="${VM_CPUS:-2}"

DATA_DIR=/data
DISK="${DATA_DIR}/openwrt.img"
# Bumped whenever the seed script changes, since the disk is only ever
# seeded once and an old volume would otherwise silently keep the old image.
SEED_REVISION=3
STAMP="${DATA_DIR}/.seeded-${OPENWRT_VERSION}-r${SEED_REVISION}"
IMAGE_NAME="openwrt-${OPENWRT_VERSION}-x86-64-generic-ext4-combined.img"
IMAGE_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/x86/64/${IMAGE_NAME}.gz"

log() { echo "[openwrt] $*"; }

mkdir -p "$DATA_DIR"

ensure_loop_devices() {
    [ -c /dev/loop-control ] || mknod -m 660 /dev/loop-control c 10 237
    index=0
    while [ "$index" -lt 8 ]; do
        [ -b "/dev/loop${index}" ] || mknod -m 660 "/dev/loop${index}" b 7 "$index"
        index=$((index + 1))
    done
}

# ---- disk image -------------------------------------------------------
if [ ! -f "$STAMP" ]; then
    ensure_loop_devices
    CACHE="${DATA_DIR}/${IMAGE_NAME}.gz"
    if [ ! -s "$CACHE" ] && [ -s "/artifacts/${IMAGE_NAME}.gz" ]; then
        log "using pre-fetched image from /artifacts"
        cp "/artifacts/${IMAGE_NAME}.gz" "$CACHE"
    fi
    if [ ! -s "$CACHE" ]; then
        log "fetching OpenWrt ${OPENWRT_VERSION} x86-64"
        curl -fL --retry 3 -o "${CACHE}.part" "$IMAGE_URL"
        mv "${CACHE}.part" "$CACHE"
    else
        log "using cached image download"
    fi
    rm -f "$DISK" "${DATA_DIR}/.seeded-"*
    gunzip -c "$CACHE" > "$DISK"
    log "seeding image"
    seed-image.sh "$DISK"
    touch "$STAMP"
else
    log "reusing existing disk (remove the openwrt-data volume to reset)"
fi

# ---- networking -------------------------------------------------------
# Each Docker interface is turned into a bridge carrying both the
# container's own address and a tap for the guest. Interfaces are resolved
# by address because Compose does not fix the ethX order.
bridge_interface() {
    address="$1"; bridge="$2"; tap="$3"

    interface="$(ip -4 -o addr show | awk -v a="$address" \
        '{ split($4, p, "/"); if (p[1] == a) { print $2; exit } }')"
    if [ -z "$interface" ]; then
        log "FATAL: no interface carries ${address}"
        exit 1
    fi
    cidr4="$(ip -4 -o addr show dev "$interface" | awk '{print $4; exit}')"
    cidr6="$(ip -6 -o addr show dev "$interface" scope global | awk '{print $4; exit}')"

    log "bridging ${interface} (${cidr4}${cidr6:+, $cidr6}) with ${tap} on ${bridge}"
    ip link add name "$bridge" type bridge
    sysctl -qw "net.ipv6.conf.${bridge}.accept_ra=0" 2>/dev/null || true
    ip link set "$interface" master "$bridge"
    ip addr flush dev "$interface"
    ip addr add "$cidr4" dev "$bridge"
    [ -n "$cidr6" ] && ip -6 addr add "$cidr6" dev "$bridge"
    ip link set "$interface" up
    ip link set "$bridge" up

    ip tuntap add dev "$tap" mode tap
    ip link set "$tap" master "$bridge"
    ip link set "$tap" up
}

bridge_interface "$ISP_CONTAINER_IP"   br0 tap0
bridge_interface "$LAN_CONTAINER_IP"   br1 tap1
bridge_interface "$CONTROL_CONTAINER_IP" br2 tap2

# The harness network is the only one with an uplink; keep the container's
# own default route there so image downloads keep working.
ip route replace default via "$CONTROL_GATEWAY" dev br2
sysctl -qw net.ipv4.ip_forward=0 >/dev/null

log "starting VM: ${VM_CPUS} cpu, ${VM_MEMORY}M"
log "serial console: telnet <host> 2323  (also written to /data/serial.log)"

exec qemu-system-x86_64 \
    -name macrelay-e2e \
    -machine q35,accel=tcg \
    -cpu max \
    -smp "$VM_CPUS" \
    -m "$VM_MEMORY" \
    -nographic \
    -drive file="$DISK",format=raw,if=virtio,cache=writeback \
    -netdev tap,id=wan0,ifname=tap0,script=no,downscript=no \
    -device virtio-net-pci,netdev=wan0,mac="$VM_MAC_WAN" \
    -netdev tap,id=lan0,ifname=tap1,script=no,downscript=no \
    -device virtio-net-pci,netdev=lan0,mac="$VM_MAC_LAN" \
    -netdev tap,id=ctl0,ifname=tap2,script=no,downscript=no \
    -device virtio-net-pci,netdev=ctl0,mac="$VM_MAC_CONTROL" \
    -chardev socket,id=serial0,host=0.0.0.0,port=2323,telnet=on,server=on,wait=off,logfile=/data/serial.log \
    -serial chardev:serial0 \
    -monitor none \
    -no-reboot
