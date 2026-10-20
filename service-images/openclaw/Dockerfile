# The OpenClaw entrypoint remains intact: native migrations and maintenance lock.
ARG OPENCLAW_IMAGE=ghcr.io/openclaw/openclaw:2026.10.5
FROM ${OPENCLAW_IMAGE}
USER root
ARG TARGETARCH
RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) checksum=fc4d8d04b1a596e8e5fdc6af7b0794d44f3f19c2f63153205b92d45ebc5f095b ;; \
      arm64) checksum=f950990700bda55851233c185c2397dc978a2576b113ff5567962e5387d6dd31 ;; \
      *) echo 'Unsupported architecture' >&2; exit 1 ;; \
    esac; \
    node -e 'const fs=require("node:fs"); fetch(process.argv[1]).then(async r=>{if(!r.ok)throw new Error(`HTTP ${r.status}`);fs.writeFileSync("/tmp/crabbox.tar.gz",Buffer.from(await r.arrayBuffer()))}).catch(e=>{console.error(e.message);process.exit(1)})' \
      "https://github.com/openclaw/crabbox/releases/download/v0.79.0/crabbox_0.79.0_linux_${TARGETARCH}.tar.gz"; \
    echo "$checksum  /tmp/crabbox.tar.gz" | sha256sum -c -; \
    mkdir /tmp/crabbox-extract; \
    tar -xzf /tmp/crabbox.tar.gz -C /tmp/crabbox-extract; \
    install -m 0755 /tmp/crabbox-extract/crabbox /usr/local/bin/crabbox; \
    rm -rf /tmp/crabbox-extract /tmp/crabbox.tar.gz; \
    /usr/local/bin/crabbox --version
USER node
