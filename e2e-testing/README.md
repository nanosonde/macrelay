# e2e-testing

A self-contained lab for exercising [macrelay.sh](../macrelay.sh) against a real
OpenWrt kernel rather than a mock.

| container | role |
| --- | --- |
| `macrelay-e2e-fritzbox` | ISP router simulation: IPv4 DHCP + uplink NAT, RA for the `/64` the hosts keep, a fake "internet" endpoint |
| `macrelay-e2e-openwrt` | OpenWrt x86-64 booted under QEMU TCG, running `macrelay.sh` |
| `macrelay-e2e-router` | downstream gateway: IPv4 routing with **NAT disabled**, **IPv6 passthrough** (it does not touch IPv6 at all) |
| `macrelay-e2e-clients` | 100 simulated hosts, one macvlan each, so every host has its own MAC and addresses |

The OpenWrt guest is not a container process. It boots OpenWrt's own kernel, so
macvlan, nftables, policy routing, conntrack and netlink behave exactly as they do
on real hardware — which is the point, since MacRelay lives on those interfaces.

## Topology

Everything downstream shares **one layer-2 segment**, which is what makes IPv6
passthrough (and therefore per-host identity) testable:

```
                              internet (Docker NAT)
                                      |
        isp 192.168.178.0/24 ---------+------ fritzbox 192.168.178.1
        2001:db8:f412::/64                    2001:db8:f412::1
                |                             internet0: 198.51.100.1 / 2001:db8:ffff::1
                |  eth0 192.168.178.2
        .-------+--------.
        |  OpenWrt VM    |  eth2 198.18.1.50 ---- harness (ssh)
        |  macrelay.sh   |
        '-------+--------'  eth1 10.10.30.2 / 2001:db8:f412::a
                |
   downstream LAN 10.10.30.0/24 + 2001:db8:f412::/64   <- one segment, no clients of its own
                |
        .-------+--------.  eth0  10.10.30.5 (WAN) + 10.10.30.1 (LAN)
        | downstream     |  router-on-a-stick: both addresses on one NIC
        | router         |  IPv4 forwarding, no NAT; IPv6 untouched (passthrough)
        '-------+--------'
                |
   hosts 10.10.30.11 - 10.10.30.110    IPv4 +  IPv6 2001:db8:f412::100:<octet hex>
          one macvlan each, MAC 52:54:11:00:00:<octet hex>
```

There is no separate transit network: the host macvlans, the router and the
guest's `eth1` are all on the same bridge, so a frame from a host reaches MacRelay
with the host's own MAC.

## The two families arrive differently

That asymmetry is the whole point of the lab, and MacRelay's two discovery paths
exist because of it:

- **IPv4 is routed** by the downstream router, which does not NAT. The hosts'
  packets therefore reach MacRelay with the **router's MAC** and only their source
  address is visible, so a host is keyed by its address and discovered from an
  nftables set fed by forwarded traffic.
- **IPv6 is passthrough.** The router neither routes nor rewrites it — its
  `disable_ipv6` is on — so the hosts' GUAs and their **own MACs** cross it as if
  it were a switch. MacRelay keys each host by the MAC that answers NDP for its
  GUAs, and publishes those GUAs upstream with **proxy NDP on that host's macvlan**.

Each host is therefore provisioned twice, once per family, and the two land on the
same macvlan because the host addresses itself from its IPv4 octet:

```
10.10.30.11  <-> 192.168.178.11      and     2001:db8:f412::100:b
```

The GUA's last hextet is the hex of the host octet (`b` = 11), which is exactly
what `gua_v4` in [macrelay.sh](../macrelay.sh) reads to recognise that the GUA and
the 1:1 address belong to one device — and what `gua6_of` reads backwards to find
the MAC of a host whose IPv4 was seen first. With `UNIFY_MAC=1` (the default) both
families therefore end up on one interface, so the simulated FRITZ!Box sees one MAC
per host for both families — which the suite asserts.

`E2E_CLIENT_COUNT` sets how many hosts the simulator carries. Unlike the earlier
lab they are **not** extra addresses on one container: each is a macvlan child of
the client container's interface, because proxy NDP is per-MAC and hosts behind one
shared MAC could not be told apart at all.

## IPv6: what is and is not exercised

The hosts keep the ISP router's own `/64`, which is the demanding case: nothing on
the ISP router needs a route, and reachability depends entirely on MacRelay
answering NDP for each GUA on the upstream LAN.

The suite asserts:

- all 100 GUAs are discovered from traffic on the downstream segment
- a proxy NDP entry exists per host, and there are exactly `COUNT` of them
- the simulated ISP router can reach every host GUA **directly** (no route for the
  host prefix exists on it), which can only work if proxy NDP published each GUA
- the IPv4 1:1 address and the GUA of one host resolve to the **same MAC**
- the guest's main table keeps exactly one IPv6 default route, and no macvlan
  carries a stray SLAAC address
- no host address is NATed on IPv6 at all

Routed/`DHCPv6-PD` mode is no longer modelled: it is the plain case where plain
routing already covers every host and per-host provisioning adds nothing. Set
`E2E_MACRELAY_PROVISION_IPV6=0` in the guest to approximate it — the other
assertions still hold except the proxy NDP ones.

## Quick start

```sh
just e2e-preflight  # check the lab subnets against the host's own networks
just e2e-up         # build, start, wait for the guest to boot (QEMU TCG: not fast)
just e2e-deploy     # install kmod-macvlan, push macrelay.sh and its config
just e2e-test       # run the assertions
just e2e-status     # macvlans, NAT mappings, proxy NDP entries, policy rules, log
```

`just e2e-up` runs the preflight itself and refuses to start on top of a subnet the
host already uses. First start downloads and seeds the OpenWrt image and boots a VM
under software emulation, so it takes a while; the guest disk and the download are
cached afterwards. Iterating on the script is:

```sh
just e2e-deploy && just e2e-test
```

`e2e-deploy` regenerates `/etc/macrelay.conf` in the guest from the lab environment,
so changing an address in `.env` does not require re-seeding the disk image.

Provisioning 100 macvlans on an emulated guest is not instant. The suite polls for
convergence (`E2E_PROVISION_TIMEOUT`, default 300 s) rather than assuming a delay.

## Useful recipes

| recipe | what it does |
| --- | --- |
| `just e2e-preflight` | check the lab subnets against the host's routes and DNS server |
| `just e2e-ssh` | shell on the OpenWrt guest over the harness interface |
| `just e2e-run 'ip rule show'` | single command on the guest |
| `just e2e-console` | guest serial console (telnet, `ctrl-]` to leave) |
| `just e2e-logs` | follow the macrelay log inside the guest |
| `just e2e-capture 'icmp'` | tcpdump on the simulated ISP router |
| `just e2e-shell router` | shell in one of the lab containers |
| `just e2e-service-logs fritzbox` | DHCP requests and leases from the simulated ISP |
| `just e2e-restart router` | restart one service |
| `just e2e-reboot` | reboot the guest and wait for it |
| `just e2e-down` / `just e2e-destroy` | stop, keeping / discarding all state |

## Avoiding collisions with the host

Every lab subnet becomes a Docker bridge, which hijacks the host's route to that
range for as long as the lab is up. If the host's LAN, VPN or — easy to miss — its
DNS server lives inside one of them, the host loses access to it and the lab itself
ends up half broken in confusing ways.

The defaults deliberately mirror the real deployment (`192.168.178.0/24` upstream,
`10.10.10.0/24` downstream), which is exactly the kind of range a home network is
likely to be using too. `just e2e-preflight` compares the lab's subnets against
`ip route` and `/etc/resolv.conf` and refuses to start when they overlap:

```
[preflight] lab subnets: 198.18.1.0/24 192.168.178.0/24 10.10.10.0/24
[preflight] CONFLICT: lab subnet 10.10.10.0/24 contains the host's DNS server 10.10.10.1
```

Fix it by moving the lab, not the host:

```sh
cp e2e-testing/.env.example e2e-testing/.env   # uncomment and adjust a block
```

Compose reads `.env` automatically, and so do the harness scripts, so the assertions
stay in sync with whatever you picked. When you move a subnet, move **all** of its
derived addresses with it — router LAN/WAN, the client's first address,
`E2E_OPENWRT_LAN_IP`, `E2E_OPENWRT_LAN_CONTAINER_IP` and `E2E_MACRELAY_INT_PREFIX4`
— or Docker refuses the static addresses. `E2E_SKIP_PREFLIGHT=1` starts anyway.

## Configuration

Every address is an environment variable with a default. The ones worth knowing:

| variable | default | meaning |
| --- | --- | --- |
| `E2E_OPENWRT_VERSION` | `25.12.5` | OpenWrt release booted in the VM |
| `E2E_ISP_SUBNET4` | `192.168.178.0/24` | ISP LAN, i.e. `LAN_PREFIX4` |
| `E2E_ISP_SUBNET6` | `2001:db8:f412::/64` | ISP LAN prefix the hosts keep |
| `E2E_LAN_SUBNET` | `10.10.10.0/24` | the downstream LAN the hosts and the router sit on |
| `E2E_CLIENT_COUNT` | `100` | simulated hosts |
| `E2E_CLIENT_FIRST` | `10.10.10.11` | first host address |
| `E2E_ISP_SUBNET6_PREFIX` | `2001:db8:f412` | the ISP /64 the hosts take their addresses from |
| `E2E_OPENWRT_LAN_IP6` | `2001:db8:f412::a` | the guest's address in the shared `/64` |
| `E2E_MACRELAY_INT_PREFIX4` | `10.10.10` | `INT_PREFIX4` in the guest's config |
| `E2E_MACRELAY_INT_PREFIX6` | `2001:db8:f412:` | `INT_PREFIX6`, the shared prefix |
| `E2E_MACRELAY_RESERVED_OCTETS` | `0 1 2 4 5 10 254 255` | host octets MacRelay must not map |
| `E2E_MACRELAY_PROVISION_IPV6` | `1` | per-host IPv6 provisioning |
| `E2E_MACRELAY_PROXY_NDP` | `1` | publish GUAs via proxy NDP |
| `E2E_MACRELAY_UNIFY_MAC` | `1` | one MAC per host for both families |
| `E2E_ROUTER_IPV6_PASSTHROUGH` | `1` | the gateway leaves IPv6 alone |
| `E2E_ROUTER_IPV4_NAT` | `0` | turn the downstream gateway's NAT back on for comparison |
| `E2E_UPSTREAM_DNS` | *(unset)* | forward DNS here when Docker's embedded resolver has no working upstream |
| `E2E_VM_MEMORY` / `E2E_VM_CPUS` | `512` / `2` | guest sizing |
| `E2E_CONSOLE_PORT` | `2323` | published serial console port |

Docker's IPAM pool sits at the top of each subnet (`….240/28`) so the low host octets
stay free for the 1:1 mappings, and `E2E_MACRELAY_RESERVED_OCTETS` covers the lab
infrastructure's own addresses — `.1` the router's LAN address, `.2` the guest's LAN
port, `.4` the openwrt container, `.5` the router's WAN address and `.10` the client
simulator itself. Change one and you have to change the other.

## Notes

- None of the lab networks are marked `internal`. Docker implements that with a
  `! -d <subnet> -i <bridge> -j DROP` rule, which silently discards every packet the
  lab routes across a segment — which is all of them.
- The router container is router-on-a-stick. Docker assigns only the WAN address from
  Compose, so the LAN address is added to the same NIC by its entrypoint; clients would
  otherwise have no gateway. Its IPv4 default route points back at the guest, so
  downstream IPv4 genuinely depends on MacRelay's 1:1 mapping existing.
- The client container puts the hosts on macvlan children of its interface with
  per-host routing tables, so a packet sourced from a host really does leave through
  that host's interface with its MAC. Without the tables everything would leave
  through the container's single default route and share one MAC.
- The OpenWrt container is privileged: it loop-mounts the guest disk to seed it and
  rebuilds its own Docker interfaces into bridges with a tap per guest NIC. QEMU runs
  with software TCG and needs neither `/dev/kvm` nor nested virtualisation, so runs
  are slower than KVM-backed ones.
- `kmod-macvlan` and `ip-full` are not in the stock image; `just e2e-deploy` installs
  them through the simulated ISP router's uplink.
- The guest firewall is deliberately wide open and masquerading is off everywhere, so
  the 1:1 NAT is the only translation in the path.
- The guest advertises no router advertisement on the downstream LAN, but it does
  answer NDP **for the ISP router's own address** there: in the real deployment the
  hosts and the ISP router share one segment, while here the router is a bridge away
  and a host's reply to it would otherwise never find its next hop. That, plus a
  `/128` route pinning the ISP router's address to the upstream interface, is the
  lab's stand-in for the shared segment — it is what a passthrough host sees in a
  real deployment without any of it.
- The client container resolves names over IPv6, through the ISP router: the IPv4
  resolver is a routed hop away from the hosts, which is not what the DNS assertion
  is about.
- Docker installs an IPv6 default route via each bridge's own ULA gateway. The router
  and client entrypoints delete it — the router disables IPv6 outright — or it would
  interfere with the addresses the lab is actually testing.
- This lab is for local testing only: fixed addresses, a throwaway SSH key and no
  authentication anywhere. Do not expose it.
