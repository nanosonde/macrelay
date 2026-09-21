#!/usr/bin/env bash
# Block until the lab is usable: containers running, guest booted and
# answering SSH, and the guest's own interfaces configured.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -f .env ]]; then set -a; . ./.env; set +a; fi

TIMEOUT="${E2E_READY_TIMEOUT:-900}"
VM_IP="${E2E_CONTROL_IP:-198.18.1.50}"
deadline=$(( $(date +%s) + TIMEOUT ))

say() { printf '[wait] %s\n' "$*"; }

wait_for() {
    local label="$1"; shift
    say "waiting for ${label}"
    until "$@" >/dev/null 2>&1; do
        if (( $(date +%s) > deadline )); then
            say "TIMEOUT waiting for ${label}"
            return 1
        fi
        sleep 3
    done
    say "${label} ready"
}

wait_for "fritzbox" docker compose exec -T fritzbox pgrep -x dnsmasq
wait_for "openwrt container" docker compose exec -T openwrt pgrep -x qemu-system-x86_64
wait_for "guest network (${VM_IP})" docker compose exec -T openwrt ping -c1 -W1 "$VM_IP"
wait_for "guest ssh" ./scripts/vm-ssh.sh true
wait_for "guest wan address" ./scripts/vm-ssh.sh \
    "ip -4 addr show dev eth0 | grep -q 'inet '"
wait_for "guest downstream lan address" ./scripts/vm-ssh.sh \
    "ip -4 addr show dev eth1 | grep -q 'inet '"
wait_for "guest downstream lan IPv6" ./scripts/vm-ssh.sh \
    "ip -6 addr show dev eth1 scope global | grep -q 'inet6'"
wait_for "router service" docker compose exec -T router \
    "sh -c 'ip -4 route show default | grep -q default'"
wait_for "client hosts" docker compose exec -T clients \
    "sh -c 'ip -o link show type macvlan | grep -q mvhost'"

say "lab is up"
