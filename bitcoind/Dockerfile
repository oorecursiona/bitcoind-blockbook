# Bitcoin Core from the official release tarball, checksum-verified.
#
# The version and checksums match the blockbook fork's configs/coins/bitcoin*.json,
# so the node is the exact build Blockbook is tested against. Bump all three together.
FROM debian:bookworm-slim

ARG BITCOIN_VERSION=31.1
ARG BITCOIN_SHA256_AMD64=b80d9c3e04da78fb6f0569685673418cf686fadba9042d926d13fb87ff503f9e
ARG BITCOIN_SHA256_ARM64=dcf1873f2208ba4f962f3398d47e154c39c0084be8f4553e05c940d0ace3d004
ARG TARGETARCH

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl openssl \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64) arch=x86_64;  sha="$BITCOIN_SHA256_AMD64" ;; \
      arm64) arch=aarch64; sha="$BITCOIN_SHA256_ARM64" ;; \
      *) echo "unsupported arch: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    tarball="bitcoin-${BITCOIN_VERSION}-${arch}-linux-gnu.tar.gz"; \
    curl -fsSLO "https://bitcoincore.org/bin/bitcoin-core-${BITCOIN_VERSION}/${tarball}"; \
    echo "${sha}  ${tarball}" | sha256sum -c -; \
    tar -xzf "$tarball" -C /usr/local --strip-components=1 \
        "bitcoin-${BITCOIN_VERSION}/bin/bitcoind" "bitcoin-${BITCOIN_VERSION}/bin/bitcoin-cli"; \
    rm "$tarball"; \
    bitcoind -version | head -1

RUN useradd --system --create-home --uid 1001 bitcoin \
 && mkdir -p /data /etc/bitcoin && chown bitcoin:bitcoin /data /etc/bitcoin

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY btc-cli /usr/local/bin/btc-cli

VOLUME /data
# RPC and ZMQ; the host only sees what docker-compose.yml publishes.
EXPOSE 8332 28332

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
