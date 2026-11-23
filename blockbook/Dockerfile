# Blockbook built from source. The source is the build context `src` (BLOCKBOOK_SRC in
# docker-compose.yml): by default the official trezor/blockbook release tag fetched
# straight from GitHub, or a local checkout for development.
#
# Mirrors upstream's own build (build/docker/bin): RocksDB v9.10.0 and Go 1.25 as pinned
# by v0.6.0, RocksDB linked statically, ZeroMQ dynamically. RocksDB is built PORTABLE so
# the image runs on any x86-64/arm64 host, not only the one that built it.

############################ builder ############################
FROM golang:1.25.4-bookworm AS builder

ARG ROCKSDB_VERSION=v9.10.0
ARG ROCKSDB_COMMIT=ae8fb3e5000e46d8d4c9dbf3a36019c0aaceebff

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential git pkg-config jq \
      libzmq3-dev libgflags-dev libsnappy-dev zlib1g-dev libbz2-dev libzstd-dev liblz4-dev libjemalloc-dev \
 && rm -rf /var/lib/apt/lists/*

# Slowest layer (10-30 min); it only rebuilds when ROCKSDB_VERSION changes.
RUN git clone -b "$ROCKSDB_VERSION" --depth 1 https://github.com/facebook/rocksdb.git /opt/rocksdb \
 && test "$(git -C /opt/rocksdb rev-parse HEAD)" = "$ROCKSDB_COMMIT" \
 && cd /opt/rocksdb \
 && ROCKSDB_DISABLE_JEMALLOC=1 PORTABLE=1 DISABLE_WARNING_AS_ERROR=1 CFLAGS=-fPIC CXXFLAGS=-fPIC \
    make -j"$(nproc)" static_lib \
 && find . -name '*.o' -delete

ENV CGO_CFLAGS="-I/opt/rocksdb/include"

WORKDIR /src
# Dependencies first so a source edit does not re-download modules.
COPY --from=src go.mod go.sum ./
RUN go mod download
COPY --from=src . .

ARG BLOCKBOOK_VERSION=devel
ARG GIT_COMMIT=unknown
# 1 links jemalloc statically, as upstream's own build does after v0.6.0 (master and the
# oorecursiona fork); v0.6.0 itself builds against glibc malloc, so the default is 0.
ARG JEMALLOC=0
RUN set -eux; \
    export CGO_LDFLAGS="-L/opt/rocksdb -ldl -lrocksdb -lstdc++ -lm -lz -lbz2 -lsnappy -llz4 -lzstd"; \
    if [ "$JEMALLOC" != "0" ]; then CGO_LDFLAGS="$CGO_LDFLAGS $(gcc -print-file-name=libjemalloc_pic.a)"; fi; \
    go build -o /out/blockbook -ldflags="-s -w \
      -X github.com/trezor/blockbook/common.version=${BLOCKBOOK_VERSION} \
      -X github.com/trezor/blockbook/common.gitcommit=${GIT_COMMIT} \
      -X github.com/trezor/blockbook/common.buildtime=$(date --iso-8601=seconds)" .

# Render blockchaincfg.json for each Bitcoin network from Blockbook's own templates, so
# the runtime config is exactly what the .deb packages would install. The entrypoint
# only rewrites the RPC/ZMQ endpoints and credentials.
# BB_BUILD_ENV=prod: the generator defaults to "dev", which merges additional_params_dev.
RUN set -eux; mkdir -p /out/config; export BB_BUILD_ENV=prod; \
    for coin in bitcoin bitcoin_testnet bitcoin_testnet4 bitcoin_signet; do \
      go run build/templates/generate.go "$coin" >/dev/null; \
      cp build/pkg-defs/blockbook/blockchaincfg.json "/out/config/${coin}.json"; \
      jq -r '.blockbook.additional_params // ""' "configs/coins/${coin}.json" > "/out/config/${coin}.args"; \
      rm -rf build/pkg-defs; \
    done

############################ runtime ############################
FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl jq \
      libzmq5 libsnappy1v5 libbz2-1.0 liblz4-1 libzstd1 zlib1g libstdc++6 \
 && rm -rf /var/lib/apt/lists/*

RUN useradd --system --create-home --uid 1002 blockbook \
 && mkdir -p /data /run/blockbook && chown blockbook:blockbook /data /run/blockbook

WORKDIR /opt/blockbook
COPY --from=builder /out/blockbook /usr/local/bin/blockbook
COPY --from=builder /out/config ./config
# The explorer and API docs are served from ./static relative to the working directory.
COPY --from=builder /src/static ./static
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# jemalloc tuning from the fork's systemd unit; ignored when built with JEMALLOC=0.
ENV MALLOC_CONF=narenas:8,background_thread:true

VOLUME /data
# 9130 public API + explorer, 9030 internal (status page, /metrics, /admin).
EXPOSE 9130 9030

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
