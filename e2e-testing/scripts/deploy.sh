#!/usr/bin/env bash
# Push the current macrelay.sh into the guest, make sure the kernel modules
# and tools it needs are present, and (re)start the service.
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="${1:-../macrelay.sh}"
[[ -f "$SRC" ]] || { echo "no such file: $SRC" >&2; exit 1; }

say() { printf '[deploy] %s\n' "$*"; }

say "installing runtime dependencies in the guest"
./scripts/vm-ssh.sh 'sh -s' <<'REMOTE'
set -e
if command -v apk >/dev/null 2>&1; then
    apk update >/dev/null
    apk add kmod-macvlan ip-full >/dev/null
elif command -v opkg >/dev/null 2>&1; then
    opkg update >/dev/null
    opkg install kmod-macvlan ip-full >/dev/null
fi
modprobe macvlan 2>/dev/null || true
REMOTE

say "refreshing /etc/macrelay.conf from the lab environment"
docker compose exec -T openwrt macrelay-conf.sh \
    | ./scripts/vm-ssh.sh 'cat > /etc/macrelay.conf'

say "copying $(basename "$SRC") to /usr/sbin/macrelay.sh"
./scripts/vm-ssh.sh 'cat > /usr/sbin/macrelay.sh && chmod +x /usr/sbin/macrelay.sh' < "$SRC"

# procd SIGKILLs the old instance before its teardown trap can run, so clear
# anything it left behind or the next run inherits stale interfaces.
say "clearing leftover state"
./scripts/vm-ssh.sh 'sh -s' <<'REMOTE'
/etc/init.d/macrelay stop >/dev/null 2>&1 || true
# The old instance blocks in `ip monitor`, so it only dies once procd
# escalates to SIGKILL. Clearing state while it still runs lets it recreate
# entries using the configuration we just replaced.
n=0
while pgrep -f /usr/sbin/macrelay.sh >/dev/null 2>&1 && [ "$n" -lt 15 ]; do
    sleep 1
    n=$((n + 1))
done
killall -9 macrelay.sh 2>/dev/null || true
pkill -9 -f /usr/sbin/macrelay.sh 2>/dev/null || true
sleep 1
for i in $(ip -o link show type macvlan | cut -d: -f2 | cut -d@ -f1); do
    ip link del "$i" 2>/dev/null || true
done
ip rule show | awk '$1 == "10000:" {print}' | while read -r _ _ a _ t; do
    ip rule del from "$a" table "$t" 2>/dev/null || true
done
ip -6 rule show | awk '$1 == "10000:" {print}' | while read -r _ _ a _ t; do
    ip -6 rule del from "$a" table "$t" 2>/dev/null || true
done
# Proxy NDP entries outlive their interface, and a stale one makes the ISP
# router resolve an address to a MAC that no longer exists.
ip -6 neigh show proxy | awk '{print $1}' | while read -r a; do
    ip -6 neigh del proxy "$a" dev eth1 2>/dev/null || true
done
ip -6 neigh flush dev eth1 2>/dev/null || true
nft delete table ip nat_1to1 2>/dev/null || true
nft delete table ip macrelay_seen 2>/dev/null || true
nft delete table ip6 macrelay_seen 2>/dev/null || true
rm -rf /var/run/macvlan_dyn

# The downstream LAN address from the shared /64, in case the interface was
# re-created by netifd after seeding.
ip -6 addr replace "${E2E_OPENWRT_LAN_IP6:-2001:db8:f412::a}/64" dev eth1 2>/dev/null || true

# In the real deployment the hosts share one layer-2 segment with the ISP
# router. In this lab it is a bridge away, so the hosts cannot resolve its
# address by NDP and their replies would have nowhere to go. This box stands
# in for the router on that segment.
sysctl -qw net.ipv6.conf.eth1.proxy_ndp=1 2>/dev/null || true
ip -6 neigh replace proxy "${E2E_WAN_GW6:-2001:db8:f412::1}" dev eth1 2>/dev/null || true

# Both interfaces hold the shared /64 as a connected route, so traffic for
# the ISP router's own address would be treated as on-link on the downstream
# side and bounce back. A host route pins it to the upstream interface.
ip -6 route replace "${E2E_WAN_GW6:-2001:db8:f412::1}/128" dev eth0 2>/dev/null || true
REMOTE

say "starting the service"
./scripts/vm-ssh.sh '/etc/init.d/macrelay enable; /etc/init.d/macrelay start'
sleep 3
./scripts/vm-ssh.sh 'logread -e macrelay | tail -n 20' || true

say "done"
