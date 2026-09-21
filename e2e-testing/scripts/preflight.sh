#!/usr/bin/env bash
# Refuse to start the lab on top of a subnet the host is already using.
#
# Every lab subnet becomes a Docker bridge, which hijacks the host's route to
# that range. If the host's LAN, VPN or -- easy to miss -- its DNS server
# lives inside one of them, the host loses access to it the moment the lab
# comes up, and the lab itself gets confusing half-broken connectivity.
set -uo pipefail

cd "$(dirname "$0")/.."

fail=0
say()  { printf '[preflight] %s\n' "$*"; }
warn() { printf '[preflight] CONFLICT: %s\n' "$*"; fail=1; }

# --- helpers ---------------------------------------------------------
ip2int() {
    local IFS=. ; read -r a b c d <<< "$1"
    echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

# Does a.b.c.d/len overlap with e.f.g.h/len2?
overlaps() {
    local net1="${1%/*}" len1="${1#*/}" net2="${2%/*}" len2="${2#*/}"
    local len=$(( len1 < len2 ? len1 : len2 ))
    (( len == 0 )) && return 0
    local mask=$(( 0xffffffff << (32 - len) & 0xffffffff ))
    (( ($(ip2int "$net1") & mask) == ($(ip2int "$net2") & mask) ))
}

contains() {
    local cidr="$1" addr="$2"
    overlaps "$cidr" "${addr}/32"
}

# --- what the lab will claim -----------------------------------------
mapfile -t lab_subnets < <(
    docker compose config 2>/dev/null \
        | awk '/^ *- subnet:/ { print $3 }' \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$'
)

if [[ ${#lab_subnets[@]} -eq 0 ]]; then
    say "could not read any IPv4 subnet from the compose configuration"
    exit 1
fi
say "lab subnets: ${lab_subnets[*]}"

# --- what the host already uses --------------------------------------
# Routes on the lab's own bridges are skipped, so re-running while the lab
# is up does not report itself as a conflict.
mapfile -t host_routes < <(
    ip -4 -o route show 2>/dev/null \
        | grep -v ' dev mr-e2e-' \
        | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ { print $1 " " $3 }'
)

mapfile -t host_dns < <(
    awk '/^nameserver/ && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ { print $2 }' \
        /etc/resolv.conf 2>/dev/null
)

for subnet in "${lab_subnets[@]}"; do
    for entry in "${host_routes[@]}"; do
        route="${entry%% *}"; dev="${entry##* }"
        # A default route or a container bridge is not a real conflict.
        [[ "$route" == "0.0.0.0/0" ]] && continue
        [[ "$dev" == docker0 || "$dev" == br-* ]] && continue
        if overlaps "$subnet" "$route"; then
            warn "lab subnet ${subnet} overlaps the host route ${route} on ${dev}"
        fi
    done
    for ns in "${host_dns[@]}"; do
        if contains "$subnet" "$ns"; then
            warn "lab subnet ${subnet} contains the host's DNS server ${ns}"
        fi
    done
done

if (( fail )); then
    cat >&2 <<'EOF'

[preflight] Pick different ranges in e2e-testing/.env, for example:

    E2E_LAN_SUBNET=10.10.30.0/24
    E2E_LAN_DOCKER_GATEWAY=10.10.30.254
    E2E_LAN_DOCKER_POOL=10.10.30.240/28
    E2E_ROUTER_LAN_IP=10.10.30.1
    E2E_ROUTER_WAN_IP=10.10.30.5
    E2E_CLIENT_FIRST=10.10.30.11
    E2E_LAN_DHCP_START=10.10.30.200
    E2E_LAN_DHCP_END=10.10.30.239
    E2E_MACRELAY_INT_PREFIX4=10.10.30

or, for the ISP side:

    E2E_ISP_SUBNET4=192.168.178.0/24
    E2E_ISP_DOCKER_GATEWAY=192.168.178.254
    E2E_ISP_DOCKER_POOL=192.168.178.240/28
    E2E_FRITZ_IP4=192.168.178.1
    E2E_OPENWRT_WAN_IP4=192.168.178.2

The full list of variables is in e2e-testing/README.md. Set
E2E_SKIP_PREFLIGHT=1 to start anyway.
EOF
    [[ "${E2E_SKIP_PREFLIGHT:-0}" == "1" ]] && { say "overridden, continuing"; exit 0; }
    exit 1
fi

say "no collision with the host's networks"
