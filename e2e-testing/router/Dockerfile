# Downstream gateway simulation: routes IPv4 without NAT and runs a full
# IPv6 stack (DHCPv6-PD client upstream, SLAAC + DHCPv6 downstream).
FROM alpine:3.20

RUN apk add --no-cache \
        dnsmasq \
        dhcpcd \
        iproute2 \
        iptables \
        ip6tables \
        iputils \
        tcpdump \
        tini

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
