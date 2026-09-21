# Simulated ISP router ("FRITZ!Box"): IPv4 DHCP + uplink NAT, IPv6
# RA/SLAAC + stateful DHCPv6, and a fake internet endpoint to ping.
FROM alpine:3.20

RUN apk add --no-cache \
        dnsmasq \
        iproute2 \
        iptables \
        ip6tables \
        iputils \
        tcpdump \
        bind-tools \
        tini

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
