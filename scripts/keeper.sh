#!/usr/bin/env bash
# Standing Orders keeper — charges every due subscription of the given plans.
#
# Anyone can run it (charges are permissionless and always pay the merchant); the caller only
# pays gas, in AVAX, on the order of 70,000 gas per charge (a fraction of a cent on C-Chain).
# Requires Foundry's `cast`.
#
#   export STANDING_ORDERS=0x...        # deployed contract
#   export PLAN_IDS="1 2"               # plans to service
#   export RPC_URL=https://api.avax-test.network/ext/bc/C/rpc   # Fuji; mainnet: https://api.avax.network/ext/bc/C/rpc
#   export PRIVATE_KEY=0x...            # keeper wallet with a little AVAX for gas (never commit it)
#   ./scripts/keeper.sh --once          # single pass (cron-friendly)
#   ./scripts/keeper.sh --interval 60   # loop forever
set -euo pipefail

: "${STANDING_ORDERS:?set STANDING_ORDERS to the contract address}"
: "${PLAN_IDS:?set PLAN_IDS, e.g. \"1 2\"}"
: "${PRIVATE_KEY:?set PRIVATE_KEY for the keeper wallet}"
RPC_URL="${RPC_URL:-https://api.avax-test.network/ext/bc/C/rpc}"
CAST="${CAST:-cast}"
PAGE=200
INTERVAL=60
ONCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --once) ONCE=1 ;;
    --interval) INTERVAL="$2"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

first_word() { echo "${1%% *}"; }   # cast prints big numbers as "1000 [1e3]"

run_once() {
  for plan in $PLAN_IDS; do
    total=$(first_word "$("$CAST" call "$STANDING_ORDERS" "subscriptionCountOfPlan(uint256)(uint256)" "$plan" --rpc-url "$RPC_URL")")
    offset=0
    while [ "$offset" -lt "$total" ]; do
      due=$("$CAST" call "$STANDING_ORDERS" "dueSubscriptionsOfPlan(uint256,uint256,uint256)(uint256[])" \
        "$plan" "$offset" "$PAGE" --rpc-url "$RPC_URL" | tr -d ' ')
      if [ "$due" != "[]" ]; then
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) plan $plan: charging $due"
        "$CAST" send "$STANDING_ORDERS" "chargeDue(uint256[])" "$due" \
          --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) plan $plan: done"
      fi
      offset=$((offset + PAGE))
    done
  done
}

if [ "$ONCE" -eq 1 ]; then
  run_once
else
  while true; do
    run_once || echo "keeper pass failed, retrying in ${INTERVAL}s" >&2
    sleep "$INTERVAL"
  done
fi
