# Bitcoin Core from the official release tarball, checksum-verified.
#
# The default is the version Blockbook's release pins in configs/coins/bitcoin*.json
# (v0.6.0 -> 29.2), i.e. the combination upstream tests. To use another version, add
# its checksums to the table below (from that Blockbook release's coin config, or
# SHA256SUMS on bitcoincore.org) and set BITCOIN_VERSION in .env.
FROM debian:bookworm-slim

ARG BITCOIN_VERSION=29.2
ARG TARGETARCH

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl openssl \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64) arch=x86_64 ;; \
      arm64) arch=aarch64 ;; \
      *) echo "unsupported arch: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    case "${BITCOIN_VERSION}-${arch}" in \
      29.2-x86_64)  sha=1fd58d0ae94b8a9e21bbaeab7d53395a44976e82bd5492b0a894826c135f9009 ;; \
      29.2-aarch64) sha=f88f72a3c5bf526581aae573be8c1f62133eaecfe3d34646c9ffca7b79dfdc7a ;; \
      31.1-x86_64)  sha=b80d9c3e04da78fb6f0569685673418cf686fadba9042d926d13fb87ff503f9e ;; \
      31.1-aarch64) sha=dcf1873f2208ba4f962f3398d47e154c39c0084be8f4553e05c940d0ace3d004 ;; \
      *) echo "no checksum for bitcoin ${BITCOIN_VERSION} ${arch}; add it to bitcoind/Dockerfile" >&2; exit 1 ;; \
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
