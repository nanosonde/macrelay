#!/usr/bin/env bash
# One-screen view of what the lab is currently doing.
set -uo pipefail

cd "$(dirname "$0")/.."

if [[ -f .env ]]; then set -a; . ./.env; set +a; fi

section() { printf '\n== %s ==\n' "$1"; }

section "containers"
docker compose ps

section "guest interfaces"
./scripts/vm-ssh.sh 'ip -brief addr show' 2>/dev/null || echo "guest unreachable"

section "provisioned macvlans"
./scripts/vm-ssh.sh 'ip -o link show type macvlan || echo none' 2>/dev/null

section "1:1 NAT mappings"
./scripts/vm-ssh.sh 'nft list map ip nat_1to1 map_snat 2>/dev/null || echo none' 2>/dev/null

section "IPv6 proxy NDP entries"
./scripts/vm-ssh.sh 'ip -6 neigh show proxy 2>/dev/null | head -n 20 || echo none' 2>/dev/null

section "policy rules"
./scripts/vm-ssh.sh 'ip rule show; echo ---; ip -6 rule show' 2>/dev/null

section "per-host state"
./scripts/vm-ssh.sh 'ls -1 /var/run/macvlan_dyn 2>/dev/null || echo none' 2>/dev/null

section "recent macrelay log"
./scripts/vm-ssh.sh 'logread -e macrelay | tail -n 25' 2>/dev/null

section "hosts seen on the downstream LAN (IPv6)"
docker compose exec -T clients sh -c \
    'ip -o link show type macvlan | wc -l' 2>/dev/null || true
