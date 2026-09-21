# Throwaway downstream host used as a traffic source.
FROM alpine:3.20

RUN apk add --no-cache \
        iproute2 \
        iputils \
        curl \
        tcpdump \
        bind-tools \
        tini

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
