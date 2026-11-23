#!/bin/sh
# Points the baked-in blockchaincfg.json at the bitcoind container, then runs Blockbook
# as the unprivileged `blockbook` user with logs on stderr (docker logs).
set -eu

: "${NETWORK:=testnet4}"
: "${RPC_USER:=rpc}"
: "${RPC_PASSWORD:?RPC_PASSWORD must be set (scripts/btc.sh init generates one)}"
: "${BITCOIND_HOST:=bitcoind}"
: "${BLOCKBOOK_WORKERS:=8}"
: "${BLOCKBOOK_DBCACHE:=1073741824}"
: "${BLOCKBOOK_EXTERNAL_APIS:=1}"

case "$NETWORK" in
  mainnet)  coin=bitcoin ;;
  testnet)  coin=bitcoin_testnet ;;
  testnet4) coin=bitcoin_testnet4 ;;
  signet)   coin=bitcoin_signet ;;
  *) echo "unknown NETWORK=$NETWORK (mainnet|testnet|testnet4|signet)" >&2; exit 1 ;;
esac

cfg=/run/blockbook/blockchaincfg.json
# Without external APIs the fee estimate falls back to bitcoind's estimatesmartfee and
# fiat rates are simply absent; nothing in the RGB++ stack reads them.
jq \
  --arg rpc "http://${BITCOIND_HOST}:8332" \
  --arg ws "ws://${BITCOIND_HOST}:8332" \
  --arg zmq "tcp://${BITCOIND_HOST}:28332" \
  --arg user "$RPC_USER" \
  --arg pass "$RPC_PASSWORD" \
  --arg ext "$BLOCKBOOK_EXTERNAL_APIS" \
  '.rpc_url=$rpc | .rpc_url_ws=$ws | .message_queue_binding=$zmq
   | .rpc_user=$user | .rpc_pass=$pass
   | if $ext == "0" then del(.fiat_rates, .fiat_rates_vs_currencies, .fiat_rates_params,
                             .alternative_estimate_fee, .alternative_estimate_fee_params)
     else . end' \
  "/opt/blockbook/config/${coin}.json" > "$cfg"
chown blockbook:blockbook "$cfg"
chmod 600 "$cfg"

if [ "$(stat -c %u /data)" != "$(id -u blockbook)" ]; then
  echo "fixing ownership of /data"
  chown -R blockbook:blockbook /data
fi

# Per-coin flags from the fork's config (e.g. -extendedindex -enablesubnewtx) come first;
# Go's flag package keeps the last value, so the .env settings after them win.
coin_args=$(cat "/opt/blockbook/config/${coin}.args")

# shellcheck disable=SC2086  # flag strings are intentionally word-split
exec setpriv --reuid=blockbook --regid=blockbook --init-groups \
  blockbook \
    -blockchaincfg="$cfg" \
    -datadir=/data/db \
    -sync \
    -internal=:9030 \
    -public=:9130 \
    -logtostderr \
    $coin_args \
    -workers="$BLOCKBOOK_WORKERS" \
    -dbcache="$BLOCKBOOK_DBCACHE" \
    ${BLOCKBOOK_EXTRA_ARGS:-} "$@"
