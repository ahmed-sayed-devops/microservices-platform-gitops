FROM bitnami/kubectl:latest AS kubectl

FROM mysql:8.4

RUN microdnf install -y \
        bash \
        curl \
    && microdnf clean all

COPY --from=kubectl /opt/bitnami/kubectl/bin/kubectl /usr/local/bin/kubectl

COPY auto-failover.sh /scripts/auto-failover.sh
COPY auto-rejoin.sh /scripts/auto-rejoin.sh
COPY generate-haproxy-config.sh /scripts/generate-haproxy-config.sh

RUN chmod +x \
        /scripts/auto-failover.sh \
        /scripts/auto-rejoin.sh \
        /scripts/generate-haproxy-config.sh

WORKDIR /scripts
