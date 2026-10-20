FROM ubuntu:24.04@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac

ARG DUCTOR_VERSION=2.0.0-rc.1
ARG VCS_REF=unknown
ARG BUILD_DATE

LABEL org.opencontainers.image.title="Ductor" \
      org.opencontainers.image.description="SSH infrastructure deployment and operations console" \
      org.opencontainers.image.source="https://github.com/vast-development-method/ductor" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.version="${DUCTOR_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}"

COPY requirements-controller.txt /opt/ductor/requirements-controller.txt

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bash ca-certificates openssh-client python3 python3-venv tini \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/ductor/.venv \
    && /opt/ductor/.venv/bin/python -m pip install --no-cache-dir -r /opt/ductor/requirements-controller.txt \
    && install -d -m 0700 /var/lib/ductor /run/ductor-inputs

COPY src /opt/ductor/src
COPY ansible /opt/ductor/ansible
COPY VERSION LICENSE /opt/ductor/
COPY docs /opt/ductor/docs
COPY service-images /opt/ductor/service-images
RUN chmod 0755 /opt/ductor/src/ductor \
    && test "$(cat /opt/ductor/VERSION)" = "$DUCTOR_VERSION" \
    && ln -s /opt/ductor/src/ductor /usr/local/bin/ductor \
    && ! command -v docker && ! command -v incus && ! command -v sshd

ENV PATH="/opt/ductor/.venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    DUCTOR_CONTAINER=1 \
    DUCTOR_STATE_DIR=/var/lib/ductor \
    DUCTOR_CONFIG=/var/lib/ductor/config.json \
    ANSIBLE_HOME=/tmp/ductor-ansible \
    ANSIBLE_LOCAL_TEMP=/tmp/ductor-ansible/tmp \
    ANSIBLE_SSH_CONTROL_PATH_DIR=/tmp/ductor-ansible/cp \
    ANSIBLE_CONFIG=/opt/ductor/ansible/ansible.cfg
WORKDIR /var/lib/ductor
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/bin/tini", "--", "/opt/ductor/src/ductor"]
CMD ["menu"]
