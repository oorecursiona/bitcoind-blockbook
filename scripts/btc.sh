#!/usr/bin/env bash
#
# Docker helper for bitcoind + Blockbook.
#
# A thin wrapper over `docker compose`. What it adds: generating a per-network .env with
# a random RPC password and non-colliding ports, telling "stop" apart from "delete my
# data", and one-line sync status for both services.
#
#   scripts/btc.sh <command> [args...]

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

COMPOSE=(docker compose)

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
die()  { red "error: $*" >&2; exit 1; }

require_docker() { docker info >/dev/null 2>&1 || die "the Docker daemon is not reachable"; }
require_env()    { [[ -f .env ]] || die ".env not found; run: scripts/btc.sh init <network>"; }

# Read one key from .env without sourcing it (values may contain shell metacharacters).
env_get() { sed -n "s/^$1=//p" .env 2>/dev/null | tail -1; }

confirm() {
  [[ "${FORCE:-0}" == "1" ]] && return 0
  local answer
  read -r -p "$1 [y/N] " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]] || { echo "aborted"; exit 1; }
}

pretty() { if command -v jq >/dev/null; then jq "$@"; else cat; fi; }

usage() {
  cat <<'USAGE'
bitcoind + Blockbook — Docker helper

  Setup
    init <network>     Write .env for mainnet|testnet|testnet4|signet (random RPC password)
    build [svc]        Build images; Blockbook from BLOCKBOOK_SRC (git URL#tag or local dir)

  Running
    up                 Start bitcoind and Blockbook (Blockbook waits for bitcoind health)
    up-bitcoind        Start bitcoind only — recommended until its initial sync is done
    down               Stop everything; data is kept
    restart [svc]      Restart one service, or both
    ps                 Container status

  Inspecting
    status             Sync progress of bitcoind and Blockbook
    logs [svc] [-f|N]  Logs of bitcoind|blockbook (follow, or last N lines; default 200)
    cli <args...>      bitcoin-cli inside the container, e.g. `cli getpeerinfo`
    sh [svc]           Shell inside a container (default blockbook)

  Data                                                    [DESTRUCTIVE]
    reset-blockbook    Delete the Blockbook index only (forces a full reindex from bitcoind)
    destroy            Stop everything and delete ALL chain data under DATA_DIR

  Set FORCE=1 to skip confirmation prompts.
USAGE
}

# Ports follow Blockbook's port registry (blockbook/docs/ports.md) so a host can run
# several networks side by side without collisions.
cmd_init() {
  local net="${1:-}"
  local public internal rpc zmq p2p dbcache mempool extra=""
  case "$net" in
    mainnet)  public=9130  internal=9030  rpc=8030  zmq=38330 p2p=8333  dbcache=4000 mempool=4096 ;;
    testnet)  public=19130 internal=19030 rpc=18030 zmq=48330 p2p=18333 dbcache=2000 mempool=2000 ;;
    testnet4) public=19129 internal=19029 rpc=18029 zmq=48329 p2p=48333 dbcache=2000 mempool=2000 ;;
    # Blockbook's signet config omits -extendedindex, which the RGB++ indexer needs to
    # resolve spenders; the other networks' configs already set it.
    signet)   public=19120 internal=19020 rpc=18020 zmq=48320 p2p=38333 dbcache=1000 mempool=1000 extra="-extendedindex" ;;
    *) die "usage: scripts/btc.sh init mainnet|testnet|testnet4|signet" ;;
  esac
  if [[ -f .env ]]; then
    confirm ".env exists (NETWORK=$(env_get NETWORK)). Overwrite it? The RPC password changes too."
  fi
  local password
  password=$(openssl rand -hex 24)
  sed \
    -e "s|^COMPOSE_PROJECT_NAME=.*|COMPOSE_PROJECT_NAME=btc-${net}|" \
    -e "s|^NETWORK=.*|NETWORK=${net}|" \
    -e "s|^RPC_PASSWORD=.*|RPC_PASSWORD=${password}|" \
    -e "s|^BITCOIND_DBCACHE=.*|BITCOIND_DBCACHE=${dbcache}|" \
    -e "s|^BITCOIND_MAXMEMPOOL=.*|BITCOIND_MAXMEMPOOL=${mempool}|" \
    -e "s|^BITCOIND_P2P_PORT=.*|BITCOIND_P2P_PORT=${p2p}|" \
    -e "s|^BITCOIND_RPC_PORT=.*|BITCOIND_RPC_PORT=${rpc}|" \
    -e "s|^BITCOIND_ZMQ_PORT=.*|BITCOIND_ZMQ_PORT=${zmq}|" \
    -e "s|^BLOCKBOOK_PUBLIC_PORT=.*|BLOCKBOOK_PUBLIC_PORT=${public}|" \
    -e "s|^BLOCKBOOK_INTERNAL_PORT=.*|BLOCKBOOK_INTERNAL_PORT=${internal}|" \
    -e "s|^BLOCKBOOK_EXTRA_ARGS=.*|BLOCKBOOK_EXTRA_ARGS=${extra}|" \
    .env.example > .env
  chmod 600 .env
  bold "wrote .env for $net"
  echo "  Blockbook API  http://127.0.0.1:${public}/api/v2/"
  echo "  bitcoind RPC   127.0.0.1:${rpc} (user rpc, password in .env)"
  echo "  data           $(env_get DATA_DIR)"
}

cmd_status() {
  require_env
  bold "bitcoind"
  if ! "${COMPOSE[@]}" exec -T bitcoind btc-cli getblockchaininfo 2>/dev/null \
      | pretty '{chain, blocks, headers, verificationprogress, initialblockdownload, size_on_disk}'; then
    echo "  not reachable (still starting, or not running)"
  fi
  bold "blockbook"
  local port; port=$(env_get BLOCKBOOK_PUBLIC_PORT)
  if ! curl -fsS "http://127.0.0.1:${port:-19129}/api/" 2>/dev/null \
      | pretty '.blockbook | {inSync, bestHeight, lastBlockTime, inSyncMempool, mempoolSize, dbSize, initialSync}'; then
    echo "  public API not answering yet — see: scripts/btc.sh logs blockbook"
  fi
}

cmd_logs() {
  local svc="" arg=""
  for a in "$@"; do
    case "$a" in bitcoind|blockbook) svc="$a" ;; *) arg="$a" ;; esac
  done
  case "$arg" in
    -f) "${COMPOSE[@]}" logs -f --tail=100 $svc ;;
    "") "${COMPOSE[@]}" logs --tail=200 $svc ;;
    *)  "${COMPOSE[@]}" logs --tail="$arg" $svc ;;
  esac
}

# Labels the Blockbook binary (shown in /api/) with what BLOCKBOOK_SRC resolves to:
# for `repo.git#ref` the ref and its commit, for a local checkout `git describe`.
# Best effort: a failed lookup only leaves the label as "unknown".
blockbook_build_labels() {
  local src; src=$(env_get BLOCKBOOK_SRC)
  src="${src:-https://github.com/trezor/blockbook.git#v0.6.0}"
  local version="devel" commit="unknown"
  if [[ "$src" == *://* || "$src" == git@* ]]; then
    local repo="${src%%#*}" ref="HEAD"
    [[ "$src" == *#* ]] && ref="${src#*#}"
    version="$ref"
    if [[ "$ref" =~ ^[0-9a-f]{7,40}$ ]]; then
      commit="${ref:0:8}"
    else
      # An annotated tag lists both the tag object and the peeled commit (^{}); prefer the latter.
      local refs
      refs=$(git ls-remote "$repo" "$ref" "$ref^{}" 2>/dev/null || true)
      commit=$( { grep '\^{}$' <<<"$refs" || head -1 <<<"$refs"; } | cut -c1-8)
      commit="${commit:-unknown}"
    fi
  elif git -C "$src" rev-parse >/dev/null 2>&1; then
    version=$(git -C "$src" describe --tags --always --dirty)
    commit=$(git -C "$src" describe --always --dirty)
  fi
  export BLOCKBOOK_VERSION="$version" BLOCKBOOK_GIT_COMMIT="$commit"
  echo "blockbook source: $src (version $version, commit $commit)"
}

data_dir() { local d; d=$(env_get DATA_DIR); echo "${d:-./data}"; }

main() {
  local cmd="${1:-help}"; shift || true
  case "$cmd" in
    init)        cmd_init "$@" ;;
    build)       require_docker; require_env; blockbook_build_labels; "${COMPOSE[@]}" build "$@" ;;
    up)          require_docker; require_env
                 mkdir -p "$(data_dir)/bitcoind" "$(data_dir)/blockbook"
                 "${COMPOSE[@]}" up -d "$@" ;;
    up-bitcoind) require_docker; require_env
                 mkdir -p "$(data_dir)/bitcoind"
                 "${COMPOSE[@]}" up -d bitcoind ;;
    down)        require_docker; "${COMPOSE[@]}" down ;;
    restart)     require_docker; "${COMPOSE[@]}" restart "$@" ;;
    ps)          require_docker; "${COMPOSE[@]}" ps ;;
    status)      require_docker; cmd_status ;;
    logs)        require_docker; cmd_logs "$@" ;;
    cli)         require_docker; "${COMPOSE[@]}" exec -T bitcoind btc-cli "$@" ;;
    sh)          require_docker; "${COMPOSE[@]}" exec "${1:-blockbook}" sh ;;
    reset-blockbook)
                 require_docker; require_env
                 confirm "Delete the Blockbook index in $(data_dir)/blockbook? Rebuilding takes hours to days."
                 "${COMPOSE[@]}" stop blockbook
                 "${COMPOSE[@]}" run --rm --no-deps --entrypoint sh blockbook -c 'rm -rf /data/db'
                 echo "index deleted; start again with: scripts/btc.sh up" ;;
    destroy)     require_docker; require_env
                 confirm "Stop everything and delete ALL chain data in $(data_dir)? This cannot be undone."
                 "${COMPOSE[@]}" down
                 # Files are owned by container users; delete them from inside a container.
                 docker run --rm -v "$(cd "$(data_dir)" && pwd):/d" debian:bookworm-slim \
                   sh -c 'rm -rf /d/bitcoind /d/blockbook'
                 echo "data deleted" ;;
    help|-h|--help) usage ;;
    *) usage; die "unknown command: $cmd" ;;
  esac
}

main "$@"
