#!/usr/bin/env bash
# Run a command on the OpenWrt guest. SSH is proxied through the openwrt
# container, which is the only thing attached to the harness network.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -f .env ]]; then set -a; . ./.env; set +a; fi

VM_IP="${E2E_CONTROL_IP:-198.18.1.50}"
SSH_OPTS=(
    -i /artifacts/ssh/id_ed25519
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=10
)

if [[ $# -eq 0 ]]; then
    exec docker compose exec openwrt ssh "${SSH_OPTS[@]}" "root@${VM_IP}"
fi

exec docker compose exec -T openwrt ssh "${SSH_OPTS[@]}" "root@${VM_IP}" "$@"
