#!/bin/sh
# ==================================================================
# macrelay.sh
#
# Per-host macvlan provisioning on an OpenWrt box wedged between an
# upstream FRITZ!Box and a downstream router.
#
#   IPv4 : 1:1 NAT  (internal 10.10.10.x  <->  FRITZ LAN 192.168.178.x)
#   IPv6 : passthrough, no NAT. The downstream hosts keep the FRITZ!Box
#          /64, so their GUAs are published on the upstream LAN via proxy
#          NDP -- from the SAME per-host macvlan, and therefore the same
#          MAC, that carries the host's 1:1 IPv4 address.
#
# The two address families are discovered differently, because they
# arrive differently:
#
#   - IPv6 reaches INT_IF through the downstream router's bridge, so the
#     hosts' own source addresses are visible there. A host is keyed by
#     the MAC that answers NDP for its GUAs, and every GUA of that MAC
#     shares one macvlan.
#   - IPv4 is routed (and usually NATed) by the downstream router, so
#     only its source addresses are visible. Hosts are keyed by address.
#
# The two keys are unified when the host's GUA identifies its IPv4
# address (see gua_v4 / UNIFY_MAC), which gives the FRITZ!Box one MAC
# per device for both families.
#
# POSIX sh / busybox ash safe. No bash substring expansion.
# ==================================================================

set -u

# ------------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------------
PARENT_IF="eth0"             # towards FRITZ!Box LAN
INT_IF="eth1"                # towards the downstream router's LAN

# --- IPv4 (1:1 NAT) ---
FRITZ_GW4="192.168.178.1"
LAN_PREFIX4="192.168.178"    # FRITZ!Box LAN /24
INT_PREFIX4="10.10.10"       # internal /24
# Host octets that must never be mapped (gateway, network, broadcast,
# and anything inside the FRITZ!Box DHCP pool -- adjust to your pool!)
RESERVED_OCTETS="0 1 255"

# --- IPv6 (passthrough: the hosts keep the FRITZ!Box /64) ---
FRITZ_GW6=""                 # leave blank to auto-detect (link-local)
INT_PREFIX6=""               # optional: only provision GUAs starting
                             # with this string, e.g. "2003:e1:"
PROVISION_IPV6=1             # 0 = leave IPv6 to the main routing table
IPV6_PROXY_NDP=1             # 1 = answer NDP for the hosts' GUAs on the
                             # upstream LAN. Required whenever the hosts
                             # live in the same /64 as the FRITZ!Box (i.e.
                             # downstream IPv6 is passthrough); set to 0
                             # when a separate prefix is delegated.
UNIFY_MAC=1                  # 1 = give a host's IPv4 and IPv6 the same
                             # macvlan (and MAC) towards the FRITZ!Box as
                             # soon as its GUA identifies its IPv4 address

# --- Housekeeping ---
STATE_DIR="/var/run/macvlan_dyn"
RULE_PREF=10000              # ip-rule preference (must be < 32766)
IDLE_TIMEOUT=3600            # no activity -> tear down
ABSENT_TIMEOUT=600           # no activity -> treat as gone, tear down sooner
GC_INTERVAL=300
DISCO_INTERVAL=5             # how often to pick up newly seen source addresses
PROBE_WAIT=2                 # seconds to wait for an NDP answer to a probe
LOG_TAG="macrelay"

# Site-specific overrides, so the defaults above never need editing.
CONF_FILE="${MACRELAY_CONF:-/etc/macrelay.conf}"
# shellcheck source=/dev/null
[ -r "$CONF_FILE" ] && . "$CONF_FILE"

# ==================================================================
# Helpers
# ==================================================================
log() { echo "$*"; logger -t "$LOG_TAG" "$*" 2>/dev/null; }

# busybox only accepts fractional sleeps when built with FANCY_SLEEP;
# without the fallback the lock below spins instead of waiting.
if sleep 0.1 2>/dev/null; then LOCK_WAIT=0.2; else LOCK_WAIT=1; fi

lock()   { while ! mkdir "$STATE_DIR/.lock" 2>/dev/null; do sleep "$LOCK_WAIT"; done; }
unlock() { rmdir "$STATE_DIR/.lock" 2>/dev/null; }

# Normalised MAC without separators, lowercase
mac_clean() { printf '%s' "$1" | tr -d ':-' | tr 'A-Z' 'a-z'; }

# Normalised MAC with colons, lowercase. The neighbour table and the kernel
# disagree about separator and case, so everything is compared through
# mac_clean; this is only for rendering one back into the usual form.

mac_is_zero() {
    case "$(mac_clean "$1")" in
        ''|000000000000) return 0 ;;
        *) return 1 ;;
    esac
}

# Does this GUA identify an internal IPv4 address? Either its last hextet is
# the hex of the host octet (what a router creates when it derives interface
# IDs from the IPv4 host part, and the only convention the lab can be sure
# of), or the low 32 bits are the address verbatim (::10.10.10.42). Prints
# the IPv4 address, or nothing.
#
# Pure shell on purpose: this runs for every GUA on every discovery sweep,
# where forking a parser per address would dominate the sweep.
gua_v4() {
    _last=${1##*:}
    [ -n "$_last" ] || return 0

    # Anything that is not plain hex is either the dotted IPv4 form or not
    # an address we can read a host octet out of.
    case "$_last" in
        *[!0-9a-fA-F]*)
            case "$_last" in
                ${INT_PREFIX4}.*) printf '%s' "$_last" ;;
            esac
            return 0 ;;
    esac

    _oct=$(( 0x$_last & 255 ))
    # A host octet, but not one belonging to the infrastructure; a random
    # privacy address would otherwise be mistaken for a client.
    [ "$_oct" -ge 2 ] && [ "$_oct" -le 254 ] && printf '%s.%s' "$INT_PREFIX4" "$_oct"
}

# Hosts are identified by an opaque key: the MAC when the host is visible on
# the downstream segment, "ip-<address>" when only its source address is.
# Hashing it keeps table ids and virtual MACs stable either way.
key_hash() { printf '%s' "$1" | md5sum | cut -c1-8; }

is_reserved_octet() {
    for o in $RESERVED_OCTETS; do [ "$1" = "$o" ] && return 0; done
    return 1
}

# An address is mappable when its host octet is not claimed by the
# infrastructure on the upstream side.
mappable4() {
    case "$1" in ${INT_PREFIX4}.*) ;; *) return 1 ;; esac
    ! is_reserved_octet "${1##*.}"
}

# ------------------------------------------------------------------
# Routing table IDs: derived from the host key but collision-checked, and
# kept clear of the reserved IDs 0/253/254/255.
# ------------------------------------------------------------------
alloc_tid() {
    _key="$1"
    _f="$STATE_DIR/${_key}.tid"
    if [ -f "$_f" ]; then cat "$_f"; return 0; fi

    _base=$(( 0x$(key_hash "$_key" | cut -c1-4) ))
    _i=0
    while [ "$_i" -lt 2000 ]; do
        _tid=$(( (_base + _i) % 60000 + 1000 ))
        if [ ! -e "$STATE_DIR/tid.$_tid" ]; then
            printf '%s\n' "$_key" > "$STATE_DIR/tid.$_tid"
            printf '%s\n' "$_tid" > "$_f"
            printf '%s\n' "$_tid"
            return 0
        fi
        _i=$((_i + 1))
    done
    log "ERROR: no free routing table id for $_key"
    return 1
}

ifname_for_tid() { printf 'mv%04x' "$1"; }

# Each macvlan sits on the upstream LAN, where accepting the ISP router's RA
# would add a competing default route and a stray SLAAC address per host.
# OpenWrt's net hotplug re-applies the system defaults to freshly created
# devices -- including overriding proxy_ndp -- so this converges on every
# call rather than being set once. It is a handful of sysctl writes, which
# is cheap next to the netlink work that surrounds it.
harden_iface() {
    _if="$1"
    sysctl -qw "net.ipv4.conf.${_if}.rp_filter=2" 2>/dev/null
    sysctl -qw "net.ipv6.conf.${_if}.accept_ra=0" 2>/dev/null
    sysctl -qw "net.ipv6.conf.${_if}.autoconf=0" 2>/dev/null
    sysctl -qw "net.ipv6.conf.${_if}.forwarding=1" 2>/dev/null
    sysctl -qw "net.ipv6.conf.${_if}.proxy_ndp=$IPV6_PROXY_NDP" 2>/dev/null
    # The hosts share the upstream prefix, so a host's next hop for that
    # prefix is on-link at L2 even though it is a routed hop for us. Telling
    # it so would send it straight to the ISP router's MAC, bypassing the
    # interface its identity -- and 1:1 NAT -- lives on.
    sysctl -qw "net.ipv6.conf.${_if}.accept_redirects=0" 2>/dev/null
    sysctl -qw "net.ipv6.conf.${_if}.send_redirects=0" 2>/dev/null
    ip -6 route flush dev "$_if" proto ra 2>/dev/null
    ip -6 addr flush dev "$_if" scope global dynamic 2>/dev/null
    return 0
}

# ==================================================================
# One-time setup
# ==================================================================
init_sysctl() {
    sysctl -qw net.ipv4.ip_forward=1
    sysctl -qw net.ipv6.conf.all.forwarding=1
    # Policy routing makes paths asymmetric -> strict RPF would drop traffic
    sysctl -qw net.ipv4.conf.all.rp_filter=2
    sysctl -qw net.ipv4.conf.default.rp_filter=2
    sysctl -qw "net.ipv4.conf.${PARENT_IF}.rp_filter=2"
    sysctl -qw "net.ipv4.conf.${INT_IF}.rp_filter=2"
    # Many interfaces share the FRITZ!Box subnet -> suppress ARP flux
    sysctl -qw net.ipv4.conf.all.arp_ignore=1
    sysctl -qw net.ipv4.conf.all.arp_announce=2
    sysctl -qw "net.ipv6.conf.${PARENT_IF}.proxy_ndp=1"
}

init_nft() {
    nft add table ip nat_1to1 2>/dev/null
    nft add map ip nat_1to1 map_dnat '{ type ipv4_addr : ipv4_addr; }' 2>/dev/null
    nft add map ip nat_1to1 map_snat '{ type ipv4_addr : ipv4_addr; }' 2>/dev/null
    nft add chain ip nat_1to1 prerouting \
        '{ type nat hook prerouting priority dstnat; policy accept; }' 2>/dev/null
    nft add chain ip nat_1to1 postrouting \
        '{ type nat hook postrouting priority srcnat; policy accept; }' 2>/dev/null
    # Only add the rules once, otherwise a restart stacks duplicates
    if ! nft list chain ip nat_1to1 prerouting 2>/dev/null | grep -q map_dnat; then
        nft add rule ip nat_1to1 prerouting dnat to ip daddr map @map_dnat
    fi
    if ! nft list chain ip nat_1to1 postrouting 2>/dev/null | grep -q map_snat; then
        nft add rule ip nat_1to1 postrouting snat to ip saddr map @map_snat
    fi
}

# Two discovery sets, because the two families arrive differently:
#
#   hosts4 -- IPv4 is routed (and usually NATed) by the downstream router,
#             so its clients are only ever visible as a source address.
#   hosts6 -- IPv6 is passthrough: the hosts' own GUAs cross INT_IF, and a
#             dynamic set keyed on them tells the GC which hosts are still
#             there, and when they go quiet.
init_disco() {
    nft add table ip macrelay_seen 2>/dev/null
    nft add set ip macrelay_seen hosts4 \
        "{ type ipv4_addr; flags dynamic,timeout; timeout ${IDLE_TIMEOUT}s; }" 2>/dev/null
    nft add chain ip macrelay_seen prerouting \
        '{ type filter hook prerouting priority -150; policy accept; }' 2>/dev/null
    if ! nft list chain ip macrelay_seen prerouting 2>/dev/null | grep -q hosts4; then
        nft add rule ip macrelay_seen prerouting iifname "$INT_IF" \
            ip saddr "${INT_PREFIX4}.0/24" update @hosts4 '{ ip saddr }'
    fi

    nft add table ip6 macrelay_seen 2>/dev/null
    nft add set ip6 macrelay_seen hosts6 \
        "{ type ipv6_addr; flags dynamic,timeout; timeout ${IDLE_TIMEOUT}s; }" 2>/dev/null
    nft add chain ip6 macrelay_seen prerouting \
        '{ type filter hook prerouting priority -150; policy accept; }' 2>/dev/null
    if ! nft list chain ip6 macrelay_seen prerouting 2>/dev/null | grep -q hosts6; then
        nft add rule ip6 macrelay_seen prerouting iifname "$INT_IF" \
            ip6 saddr != fe80::/10 update @hosts6 '{ ip6 saddr }'
    fi
}

seen_hosts4() {
    nft list set ip macrelay_seen hosts4 2>/dev/null \
        | grep -oE '\b[0-9]{1,3}(\.[0-9]{1,3}){3}\b'
}

# The GUAs seen on the downstream segment that still have a provisioned
# host behind them. Reading the set is the GC's cheap "is the host alive"
# check for IPv6 identities, which never appear in the neighbour table.
ndp_hits6() {
    _ip="$1"
    nft list set ip6 macrelay_seen hosts6 2>/dev/null \
        | grep -qiF "$(printf '%s' "$_ip" | tr 'A-F' 'a-f')"
}

# Best MAC known for an address: the neighbour table is authoritative, the
# discovery sets only know the address itself.
neigh_lookup6() {
    { ip -6 neigh show to "$1" dev "$INT_IF" 2>/dev/null
      ip -6 neigh show to "$1" dev "$PARENT_IF" 2>/dev/null
    } | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' \
      | grep -viE '^(33:33|01:00:5e)' | head -n 1
}

# Is this one of our own addresses? In passthrough mode the hosts share the
# upstream prefix with this box, so its own interfaces are on the same /64 as
# the traffic it is watching. Provisioning a macvlan for our own address
# would put the ISP router's own prefix into the host table and make the box
# answer for itself on a second MAC.
is_local_addr6() {
    ip -6 -o addr show 2>/dev/null | grep -q " $1/"
}

# Does any neighbour entry on either segment still carry this MAC? Used to
# spot a host that has gone away without its state files ever expiring.
neigh_present6() {
    _m=$(mac_clean "$1")
    [ -n "$_m" ] || return 1
    { ip -6 neigh show dev "$INT_IF" 2>/dev/null
      ip -6 neigh show dev "$PARENT_IF" 2>/dev/null
      ip neigh show dev "$INT_IF" 2>/dev/null
    } | tr 'A-F' 'a-f' | tr -d ':-' | grep -qF "$_m"
}

# Re-resolvable: the RA may not have arrived yet at startup
detect_gw6() {
    [ -n "$FRITZ_GW6" ] && return 0
    FRITZ_GW6=$(ip -6 route show default dev "$PARENT_IF" 2>/dev/null \
                | awk '/via/ {print $3; exit}')
    [ -z "$FRITZ_GW6" ] && FRITZ_GW6=$(ip -6 neigh show dev "$PARENT_IF" 2>/dev/null \
                | awk '/router/ {print $1; exit}')
    [ -n "$FRITZ_GW6" ]
}

# ------------------------------------------------------------------
# Provisioning
#
# Every host is a key: a MAC on the downstream segment, or "ip-<address>"
# when only its source address is visible. Both families of one host must
# resolve to the same key, or the host would get two interfaces and two MACs
# and the ISP router would see two devices.
#
# The two discovery workers therefore have to agree, and they run
# independently. That is arranged without ever rewriting state: both derive
# the key the same way, preferring a MAC whenever one can be established,
# and both look up an existing key before creating a new one. Whichever
# worker sees the host first, the other joins the identity it chose.
# ------------------------------------------------------------------

provision_host() {
    src_ip="$1"; key="$2"; ip_ver="$3"

    # Never burn an interface on an address that cannot be mapped.
    if [ "$ip_ver" = "4" ] && ! mappable4 "$src_ip"; then
        return 0
    fi

    # Whichever family arrives second must not give the host a second
    # identity. The IPv4 address names the host for both families, so it is
    # resolved first: a key that already holds it -- or the GUA it implies
    # -- is the identity this provision joins, and a macvlan already
    # provisioned under it is reused rather than duplicated.
    if [ "$ip_ver" = "4" ]; then
        _existing=$(host_key_for "$src_ip")
        [ -n "$_existing" ] && key="$_existing"
    fi

    tid=$(alloc_tid "$key") || return 1
    ifname=$(ifname_for_tid "$tid")
    kh=$(key_hash "$key")
    virt_mac="02:00:$(printf '%s' "$kh" | cut -c1-2):$(printf '%s' "$kh" | cut -c3-4):$(printf '%s' "$kh" | cut -c5-6):$(printf '%s' "$kh" | cut -c7-8)"

    touch "$STATE_DIR/${key}.ts"

    if ! ip link show dev "$ifname" >/dev/null 2>&1; then
        ip link add "$ifname" link "$PARENT_IF" type macvlan mode bridge || return 1
        ip link set "$ifname" address "$virt_mac"
        harden_iface "$ifname"
        ip link set "$ifname" up
        printf '%s\n' "$ifname" > "$STATE_DIR/${key}.if"
        log "Created $ifname (host $key -> $virt_mac, table $tid)"
    fi
    harden_iface "$ifname"

    if [ "$ip_ver" = "4" ]; then
        lan_ip="${LAN_PREFIX4}.${src_ip##*.}"
        old=$(cat "$STATE_DIR/${key}.v4" 2>/dev/null || true)
        [ "$old" = "$src_ip" ] && return 0
        [ -n "$old" ] && cleanup_v4 "$old" "$tid"

        # A re-provision may land the address on a new macvlan (a restart
        # with a different key, or the old interface having been torn down).
        # Whatever else still holds the /32 would keep answering ARP for it,
        # so the address moves first and the ISP router's cache is refreshed
        # by the next packet rather than serving a dangling MAC.
        for _other in $(ip -o addr show to "$lan_ip" 2>/dev/null \
                        | awk -v a="$ifname" '$2 != a { print $2 }'); do
            ip addr del "${lan_ip}/32" dev "$_other" 2>/dev/null
        done

        ip addr replace "${lan_ip}/32" dev "$ifname"
        ip route replace "${FRITZ_GW4}/32" dev "$ifname" scope link \
            src "$lan_ip" table "$tid"
        ip route replace default via "$FRITZ_GW4" dev "$ifname" table "$tid"
        ip rule del from "$src_ip" table "$tid" 2>/dev/null
        ip rule add from "$src_ip" table "$tid" pref "$RULE_PREF"

        nft add element ip nat_1to1 map_dnat "{ $lan_ip : $src_ip }"
        nft add element ip nat_1to1 map_snat "{ $src_ip : $lan_ip }"
        printf '%s\n' "$src_ip" > "$STATE_DIR/${key}.v4"
        log "IPv4 1:1 NAT: $src_ip <-> $lan_ip via $ifname (table $tid)"

    else
        # Passthrough: the host keeps its FRITZ!Box-derived GUA, so inbound
        # traffic for it is resolved by NDP on the upstream LAN. Publishing
        # it on this host's macvlan is what makes the FRITZ!Box send the
        # packet to us, and from the same MAC the 1:1 IPv4 mapping uses.
        #
        # A host may hold several GUAs (a stable one plus privacy
        # extensions, or one per interface), so .v6 accumulates them rather
        # than holding a single address.
        [ -f "$STATE_DIR/${key}.v6" ] || : > "$STATE_DIR/${key}.v6"
        if grep -qxF "$src_ip" "$STATE_DIR/${key}.v6" 2>/dev/null; then
            return 0
        fi

        ip -6 rule del from "$src_ip" table "$tid" 2>/dev/null
        ip -6 rule add from "$src_ip" table "$tid" pref "$RULE_PREF"

        if [ "$IPV6_PROXY_NDP" = "1" ]; then
            ip -6 neigh replace proxy "$src_ip" dev "$ifname" 2>/dev/null
            # Where the return path hands the packet over. The hosts share
            # the upstream /64, so the connected route cannot say which side
            # of this box a host is on -- this box holds addresses from that
            # prefix on both interfaces. One host route settles it.
            ip -6 route replace "${src_ip}/128" dev "$INT_IF" 2>/dev/null
            printf '%s\n' "$src_ip" >> "$STATE_DIR/${key}.v6"
            log "IPv6 passthrough: $src_ip proxied on $ifname (table $tid)"
        else
            # No proxy NDP: the prefix is delegated and routed, so the
            # per-host table needs somewhere to send it.
            if detect_gw6; then
                ip -6 route replace default via "$FRITZ_GW6" dev "$ifname" table "$tid"
                printf '%s\n' "$src_ip" >> "$STATE_DIR/${key}.v6"
                log "IPv6 route: $src_ip via $ifname -> $FRITZ_GW6 (table $tid)"
            else
                log "IPv6 gateway not known yet, deferring route for $src_ip"
            fi
        fi
    fi
}

cleanup_v4() {
    _ip="$1"; _tid="$2"
    _lan="${LAN_PREFIX4}.${_ip##*.}"
    while ip rule del from "$_ip" table "$_tid" 2>/dev/null; do :; done
    nft delete element ip nat_1to1 map_dnat "{ $_lan }" 2>/dev/null
    nft delete element ip nat_1to1 map_snat "{ $_ip }" 2>/dev/null
}

cleanup_v6() {
    _ip="$1"; _tid="$2"; _if="$3"
    while ip -6 rule del from "$_ip" table "$_tid" 2>/dev/null; do :; done
    [ -n "$_if" ] && ip -6 neigh del proxy "$_ip" dev "$_if" 2>/dev/null
    ip -6 route del "${_ip}/128" dev "$INT_IF" 2>/dev/null
    ip -6 route del "${_ip}/128" table "$_tid" 2>/dev/null
}

# Clean up every GUA a host holds. The reverse-path host route is only
# dropped when no other host still needs the same address -- two hosts
# sharing one GUA (a router whose clients all source from its own address)
# must not lose each other's return path.
cleanup_v6_all() {
    _key="$1"; _tid="$2"; _if="$3"
    _f="$STATE_DIR/${_key}.v6"
    [ -f "$_f" ] || return 0
    while read -r _ip; do
        [ -n "$_ip" ] || continue
        if shared_v6 "$_key" "$_ip"; then
            log "Keeping shared IPv6 address $_ip (host $_key still referenced)"
            continue
        fi
        cleanup_v6 "$_ip" "$_tid" "$_if"
    done < "$_f"
    rm -f "$_f"
}

# Is another host's state still pointing at this address?
shared_v6() {
    _self="$1"; _ip="$2"
    for _f in "$STATE_DIR"/*.v6; do
        [ -f "$_f" ] || continue
        _k=${_f##*/}; _k=${_k%.v6}
        [ "$_k" = "$_self" ] && continue
        grep -qxF "$_ip" "$_f" 2>/dev/null && return 0
    done
    return 1
}

teardown_host() {
    key="$1"; reason="$2"
    tid=$(cat "$STATE_DIR/${key}.tid" 2>/dev/null || true)
    ifname=$(cat "$STATE_DIR/${key}.if" 2>/dev/null || true)
    [ -n "$tid" ] || return 0

    v4=$(cat "$STATE_DIR/${key}.v4" 2>/dev/null || true)
    [ -n "$v4" ] && cleanup_v4 "$v4" "$tid"
    cleanup_v6_all "$key" "$tid" "$ifname"

    ip route flush table "$tid" 2>/dev/null
    ip -6 route flush table "$tid" 2>/dev/null
    [ -n "$ifname" ] && ip link del "$ifname" 2>/dev/null

    rm -f "$STATE_DIR/tid.$tid" "$STATE_DIR/${key}."*
    log "Teardown: ${ifname:-?} (host $key) removed [$reason]"
}

# ==================================================================
# Liveness / garbage collection
# ==================================================================
# Activity signal 1: conntrack flows for any of the host's addresses.
has_flows() {
    [ -r /proc/net/nf_conntrack ] || return 1
    for a in "$@"; do
        [ -n "$a" ] || continue
        grep -qF "src=$a " /proc/net/nf_conntrack && return 0
    done
    return 1
}

# Activity signal 2: the host is still around. A routing downstream hides
# its clients behind one MAC, so for those a recent IPv6 packet in the
# discovery set is the only evidence, and the neighbour table is only
# meaningful on the segment we share with the host.
host_present() {
    _key="$1"
    case "$_key" in
        ip-*)
            seen_hosts4 | grep -qx "${_key#ip-}" && return 0
            ;;
        *)
            neigh_present6 "$_key" && return 0
            ;;
    esac
    for _a in $(cat "$STATE_DIR/${_key}.v6" 2>/dev/null || true); do
        ndp_hits6 "$_a" && return 0
    done
    return 1
}

gc_worker() {
    while true; do
        sleep "$GC_INTERVAL"
        now=$(date +%s)
        for ts in "$STATE_DIR"/*.ts; do
            [ -f "$ts" ] || continue
            key=$(basename "$ts" .ts)

            v4=$(cat "$STATE_DIR/${key}.v4" 2>/dev/null || true)
            # A host may hold several GUAs; conntrack mentions whichever one
            # the flow used, so every one of them counts as activity.
            has_flows "$v4" $(cat "$STATE_DIR/${key}.v6" 2>/dev/null || true) && touch "$ts"

            idle=$(( now - $(stat -c %Y "$ts" 2>/dev/null || echo "$now") ))

            lock
            if [ "$idle" -ge "$IDLE_TIMEOUT" ]; then
                teardown_host "$key" "idle ${idle}s"
            elif [ "$idle" -ge "$ABSENT_TIMEOUT" ] && ! host_present "$key"; then
                teardown_host "$key" "host gone, idle ${idle}s"
            fi
            unlock
        done
    done
}

# Pick up hosts that only ever appear as a source address, because a
# downstream gateway routes (and usually NATs) them. IPv6 is discovered in
# disco6_worker instead, from the passthrough traffic itself.
disco_worker() {
    while true; do
        _todo=""
        for a in $(seen_hosts4); do
            mappable4 "$a" || continue
            # An existing identity always wins and is only kept alive here.
            if host_key_for "$a" >/dev/null 2>&1; then
                _k=$(host_key_for "$a")
                touch "$STATE_DIR/${_k}.ts"
                continue
            fi
            _todo="$_todo $a"
        done

        # Naming a host after its MAC means asking who answers NDP for the
        # GUA its address implies. The asks are issued for the whole batch
        # and waited on once, so a hundred new hosts cost one wait rather
        # than a hundred -- which would otherwise dominate the sweep.
        [ -n "$_todo" ] || { sleep "$DISCO_INTERVAL"; continue; }
        if [ "$UNIFY_MAC" = "1" ]; then
            for a in $_todo; do
                _g=$(gua6_of "$a")
                [ -n "$_g" ] && ip -6 neigh get "$_g" dev "$INT_IF" >/dev/null 2>&1
            done
            sleep "$PROBE_WAIT"
        fi

        for a in $_todo; do
            lock; provision_host "$a" "$(host_key_for_v4 "$a")" "4"; unlock
        done
        sleep "$DISCO_INTERVAL"
    done
}

# The identity to provision an internal IPv4 address under, and the single
# place the two families are joined.
#
# The order matters: an existing identity always wins, so a host that has
# already been provisioned keeps it and no second interface is ever created
# for it. Only a host with no identity yet is probed for the MAC that
# answers NDP for its GUA -- the convention this deployment numbers hosts
# by -- and named after that MAC if it answers. A network that numbers its
# hosts differently just gets the address-derived identity, which the IPv6
# side then joins on.
host_key_for_v4() {
    _addr="$1"
    _k=$(host_key_for "$_addr") && { printf '%s' "$_k"; return 0; }

    if [ "$UNIFY_MAC" = "1" ]; then
        _g=$(gua6_of "$_addr")
        if [ -n "$_g" ]; then
            _m=$(neigh_lookup6 "$_g")
            mac_is_zero "$_m" && _m=""
            [ -n "$_m" ] && { printf '%s' "$_m"; return 0; }
        fi
    fi
    printf 'ip-%s' "$_addr"
}

# IPv6 passthrough: the hosts' own GUAs cross INT_IF, so they are picked up
# from the discovery set rather than from the neighbour table. This is also
# where a host's two families are joined -- the packet that reveals the GUA
# is what lets us ask which MAC owns it, and the GUA itself says which IPv4
# address belongs to the same device.
disco6_worker() {
    while true; do
        if [ "$PROVISION_IPV6" = "1" ]; then
            _known=$(state_v6_map)
            _todo=""
            for a in $(seen_hosts6); do
                case "$a" in
                    fe80:*|ff*:*|::1|::) continue ;;    # link-local / multicast
                esac
                # Only addresses that identify a downstream host are
                # provisioned: the upstream prefix is ours as well, so our
                # own addresses and the ISP router's show up here too, and
                # a GUA that says nothing about which host it belongs to
                # cannot be given a per-host identity at all.
                is_local_addr6 "$a" && continue
                [ -n "$(gua_v4 "$a")" ] || continue

                if [ -n "$INT_PREFIX6" ]; then
                    case "$a" in ${INT_PREFIX6}*) ;; *) continue ;; esac
                fi
                printf '%s\n' "$_known" | grep -q " ${a}$" && continue
                _todo="$_todo $a"
            done

            # Identifying a host means asking who answers NDP for its GUA.
            # The probes are issued for the whole batch and waited on once,
            # so a hundred new hosts cost one wait rather than a hundred,
            # which would otherwise serialise the entire sweep.
            for a in $_todo; do
                ip neigh get "$a" dev "$INT_IF" >/dev/null 2>&1
                ip -6 neigh get "$a" dev "$INT_IF" >/dev/null 2>&1
            done
            [ -n "$_todo" ] && sleep "$PROBE_WAIT"

            for a in $_todo; do
                _mac=$(neigh_lookup6 "$a")
                mac_is_zero "$_mac" && _mac=""
                lock; provision_v6 "$a" "$_mac"; unlock
            done
        fi
        sleep "$DISCO_INTERVAL"
    done
}

# The GUA a host addresses itself with in this deployment, derived from its
# IPv4 octet. It is only a hint -- a network that numbers its hosts
# differently simply finds no neighbour entry and falls back to the address.
gua6_of() {
    [ -n "$INT_PREFIX6" ] || return 0
    _p=${INT_PREFIX6%:}
    _p=${_p%:}
    [ -n "$_p" ] || return 0
    printf '%s::100:%s' "$_p" "$(printf '%x' "${1##*.}")"
}

# All GUAs currently seen downstream, as bare addresses.
seen_hosts6() {
    nft list set ip6 macrelay_seen hosts6 2>/dev/null \
        | grep -oE '[0-9a-fA-F]{0,4}(:[0-9a-fA-F]{0,4}){2,7}' \
        | grep -v '^:' | sort -u
}

# "key address" for every provisioned host, one line per address, in one
# pass and without forking per entry -- this is on the hot path of every
# discovery sweep. A host may hold several GUAs, so a file can have several
# lines and each of them needs the key in front of it.
state_v6_map() {
    for _f in "$STATE_DIR"/*.v6; do
        [ -f "$_f" ] || continue
        _k=${_f##*/}; _k=${_k%.v6}
        while read -r _a; do
            [ -n "$_a" ] || continue
            printf '%s %s\n' "$_k" "$_a"
        done < "$_f"
    done
}

# Provision one discovered GUA under whichever identity the host has: the
# MAC that answered NDP for it, the IPv4 address it maps onto, or, when
# neither is available, the address itself -- which still gets the host the
# reachability a plain route would give it.
provision_v6() {
    _ip="$1"; _mac="${2:-}"

    # Our own addresses, and anything that is not a host of ours, are not
    # ours to publish: in passthrough mode this box is a member of the very
    # prefix the hosts use.
    is_local_addr6 "$_ip" && return 0

    state_v6_map | grep -q " ${_ip}$" && return 0

    _v4=$(gua_v4 "$_ip")
    # A GUA that identifies a reserved octet says nothing usable about the
    # host; keep it address-keyed rather than claim infrastructure space.
    mappable4 "$_v4" || _v4=""

    # A host is identified by a MAC whenever one can be established, so both
    # workers have to agree on which MAC that is. An existing identity is
    # therefore reused before anything else: the MAC that answered NDP may
    # not be the key the host was first provisioned under.
    if [ -n "$_v4" ]; then
        _k=$(host_key_for "$_v4")
        [ -n "$_k" ] && _mac=$_k
    fi
    if [ -z "$_mac" ] && [ -n "$_v4" ]; then
        _mac="ip-${_v4}"
    fi

    if [ -n "$_mac" ]; then
        provision_host "$_ip" "$_mac" "6"
    else
        provision_host "$_ip" "ip-${_ip}" "6"
    fi
}

# The host key that already owns an internal IPv4 address, if any. All three
# discovery paths consult this before creating anything, so it has to find
# an identity whichever family established it:
#   - a key whose .v4 says it owns the address,
#   - an address-derived key (ip-<addr>) created from the GUA alone,
#   - a key whose .v6 contains the GUA the address implies.
host_key_for() {
    _addr="$1"
    for _ts in "$STATE_DIR"/*.ts; do
        [ -f "$_ts" ] || continue
        _k=$(basename "$_ts" .ts)
        [ "$(cat "$STATE_DIR/${_k}.v4" 2>/dev/null || true)" = "$_addr" ] && {
            printf '%s' "$_k"; return 0; }
    done
    [ -f "$STATE_DIR/ip-${_addr}.tid" ] && { printf 'ip-%s' "$_addr"; return 0; }
    _g=$(gua6_of "$_addr")
    if [ -n "$_g" ]; then
        _k=$(state_v6_map | awk -v g="$_g" '$2 == g { print $1; exit }')
        if [ -n "$_k" ]; then
            printf '%s' "$_k"
            return 0
        fi
    fi
    return 1
}

# ==================================================================
# Event handling
# ==================================================================
handle() {
    _ip="$1"; _mac="$2"
    case "$_ip" in
        ${INT_PREFIX4}.*)
            lock; provision_host "$_ip" "$_mac" "4"; unlock ;;
        fe80:*|ff*:*|::*)
            : ;;                                  # link-local / multicast
        *:*)
            # IPv6 is provisioned by disco6_worker: a neighbour entry for a
            # GUA on either segment usually names the upstream router rather
            # than the host, so the MAC here is not the host's own.
            : ;;
    esac
}

# Pick up hosts that already exist (startup, or after a monitor restart)
sync_neigh() {
    {
        ip neigh show dev "$INT_IF" 2>/dev/null
        ip -6 neigh show dev "$INT_IF" 2>/dev/null
    } | while read -r line; do
        case "$line" in *FAILED*|*INCOMPLETE*) continue ;; esac
        set -- $line
        addr="$1"
        mac=$(printf '%s' "$line" | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}')
        [ -n "$mac" ] && handle "$addr" "$mac"
    done
}

cleanup_all() {
    trap '' TERM INT EXIT
    for p in ${MON_PID:-} ${GC_PID:-} ${DISCO_PID:-} ${DISCO6_PID:-}; do kill "$p" 2>/dev/null; done
    for f in "$STATE_DIR"/*.ts; do
        [ -f "$f" ] || continue
        teardown_host "$(basename "$f" .ts)" "shutdown"
    done
    nft delete table ip nat_1to1 2>/dev/null
    nft delete table ip macrelay_seen 2>/dev/null
    nft delete table ip6 macrelay_seen 2>/dev/null
    unlock
    exit 0
}

# ==================================================================
# Main
# ==================================================================
mkdir -p "$STATE_DIR"
unlock                       # clear a stale lock from a crashed run
init_sysctl
init_nft
init_disco
detect_gw6 || log "IPv6 gateway not detected yet (will retry on demand)"
trap cleanup_all TERM INT EXIT

gc_worker & GC_PID=$!
disco_worker & DISCO_PID=$!
disco6_worker & DISCO6_PID=$!

log "Controller active: $INT_IF -> $PARENT_IF (IPv4 1:1 NAT + IPv6 passthrough)"

monitor_worker() {
    ip monitor neigh dev "$INT_IF" 2>/dev/null | while read -r line; do
        case "$line" in
            Deleted*)            continue ;;   # GC owns removal
            *FAILED*|*INCOMPLETE*) continue ;;
        esac
        set -- $line
        addr="$1"
        mac=$(printf '%s' "$line" | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}')
        [ -n "$addr" ] && [ -n "$mac" ] && handle "$addr" "$mac"
    done
}

# ip monitor can die on a netlink buffer overrun -> supervise and re-sync.
# It runs in the background and is collected with `wait`, which is the only
# way a POSIX shell can react to SIGTERM while the monitor is idle; blocking
# on the pipeline directly defers the trap until procd resorts to SIGKILL,
# which skips teardown and leaves the workers orphaned.
while true; do
    sync_neigh
    monitor_worker & MON_PID=$!
    wait "$MON_PID"
    log "WARN: ip monitor exited, restarting in 2s"
    sleep 2
done
