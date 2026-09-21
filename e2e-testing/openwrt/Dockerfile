# OpenWrt x86-64 running as a real VM under QEMU TCG.
#
# Full system virtualisation with OpenWrt's own kernel rather than a
# userspace container, so macvlan, nftables, policy routing, conntrack and
# netlink all behave the way they do on real hardware. The guest NICs are
# bridged onto the container's Docker networks, which puts the VM on the
# same layer-2 segments as the simulated ISP router and the clients.
FROM alpine:3.20

RUN apk add --no-cache \
        qemu-system-x86_64 \
        qemu-img \
        iproute2 \
        bridge-utils \
        e2fsprogs \
        e2fsprogs-extra \
        util-linux \
        curl \
        gzip \
        openssh-client \
        iputils \
        socat \
        tini

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY seed-image.sh /usr/local/bin/seed-image.sh
COPY macrelay-conf.sh /usr/local/bin/macrelay-conf.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/seed-image.sh \
             /usr/local/bin/macrelay-conf.sh

VOLUME /data
EXPOSE 2323

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
