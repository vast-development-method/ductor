FROM ubuntu:24.04@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac

ARG DUCTOR_VERSION=0.1.0-rc.1
ARG VCS_REF=unknown
ARG BUILD_DATE
ARG DOCKER_CLI_VERSION=5:29.8.2-1~ubuntu.24.04~noble
ARG DOCKER_COMPOSE_VERSION=5.6.0-1~ubuntu.24.04~noble

LABEL org.opencontainers.image.title="Ductor" \
      org.opencontainers.image.description="Ductor infrastructure controller and terminal console" \
      org.opencontainers.image.source="https://github.com/vast-development-method/ductor" \
      org.opencontainers.image.url="https://github.com/vast-development-method/ductor" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.version="${DUCTOR_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
    && chmod 0755 /usr/sbin/policy-rc.d \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash ca-certificates coreutils curl diffutils findutils gawk git grep \
        gzip incus-client iproute2 jq openssh-client openssh-server openssl \
        procps sed sudo tar tini util-linux whiptail xz-utils \
    && install -d -m 0755 /etc/apt/keyrings \
    && curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod 0644 /etc/apt/keyrings/docker.asc \
    && printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable\n' \
        "$(dpkg --print-architecture)" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        "docker-ce-cli=${DOCKER_CLI_VERSION}" "docker-compose-plugin=${DOCKER_COMPOSE_VERSION}" \
    && rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_* \
    && useradd --system --create-home --home-dir /var/lib/ductor-broker --shell /bin/sh ductor-broker \
    && usermod --password '*' ductor-broker \
    && touch /etc/ductor-container \
    && install -d -m 0700 /var/lib/ductor

COPY --chmod=0755 src/ductor /usr/local/bin/ductor
COPY LICENSE /usr/share/doc/ductor/LICENSE
RUN test "$(ductor version)" = "Ductor ${DUCTOR_VERSION}" \
    && docker --version && docker compose version && incus --version \
    && ! command -v dockerd && ! command -v incusd

ENV DUCTOR_CONTAINER=1 \
    DUCTOR_STATE_DIR=/var/lib/ductor \
    INCUS_CONF=/var/lib/ductor/incus \
    DUCTOR_BROKER_LISTEN_ADDRESS=0.0.0.0 \
    DUCTOR_BROKER_PORT=2222 \
    DUCTOR_REAPER_INTERVAL=30
WORKDIR /var/lib/ductor
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD ["/usr/local/bin/ductor", "container-health"]
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/ductor"]
CMD ["serve"]
