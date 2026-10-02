#!/usr/bin/env bash
# One-shot Fuji run: deploy StandingOrders (bound to Circle's test USDC), then the gasless demo
# (plan -> subscribe with zero AVAX on the subscriber -> keeper charge -> gasless cancel).
#
# Prerequisites (free, from public faucets, see README):
#   PRIVATE_KEY             relayer + merchant + deployer: needs a little Fuji AVAX
#   SUBSCRIBER_PRIVATE_KEY  payer: needs >= 3 test USDC (https://faucet.circle.com, Avalanche Fuji) and NO AVAX
# Both are read from .env (gitignored). FUJI_RPC_URL defaults to the public Fuji RPC.
#
# Writes deployments/fuji.json (contract, token, chain, deploy tx) and deployments/fuji-demo.json (tx hashes).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CLI_RPC="${FUJI_RPC_URL:-}"            # an RPC given on the command line wins over .env
set -a; [ -f .env ] && . ./.env; set +a
RPC="${CLI_RPC:-${FUJI_RPC_URL:-https://api.avax-test.network/ext/bc/C/rpc}}"
USDC=0x5425890298aed601595a70AB815c96711a31Bc65
: "${PRIVATE_KEY:?PRIVATE_KEY missing in .env}"
: "${SUBSCRIBER_PRIVATE_KEY:?SUBSCRIBER_PRIVATE_KEY missing in .env}"

[ "$(cast chain-id --rpc-url "$RPC")" = "43113" ] || { echo "RPC is not Fuji (43113). Refusing."; exit 1; }
RELAYER="$(cast wallet address --private-key "$PRIVATE_KEY")"
SUB="$(cast wallet address --private-key "$SUBSCRIBER_PRIVATE_KEY")"
first() { echo "${1%% *}"; }

RELAYER_AVAX="$(cast balance "$RELAYER" --rpc-url "$RPC")"
SUB_AVAX="$(cast balance "$SUB" --rpc-url "$RPC")"
SUB_USDC="$(first "$(cast call "$USDC" 'balanceOf(address)(uint256)' "$SUB" --rpc-url "$RPC")")"
echo "relayer   $RELAYER  AVAX(wei)=$RELAYER_AVAX"
echo "subscriber $SUB  AVAX(wei)=$SUB_AVAX  USDC(6dp)=$SUB_USDC"
[ "$RELAYER_AVAX" != "0" ] || { echo "Relayer has no Fuji AVAX yet: get a little from a faucet (see README)."; exit 1; }
[ "$SUB_AVAX" = "0" ] || { echo "Subscriber must hold NO AVAX for the demo to prove anything."; exit 1; }
[ "$SUB_USDC" -ge 3000000 ] || { echo "Subscriber needs >= 3 test USDC from https://faucet.circle.com (Avalanche Fuji)."; exit 1; }

mkdir -p deployments
LOGDIR="$(mktemp -d)"
json_get() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($2)" "$1"; }
tx_hashes() { json_get "$1" "' '.join(t['hash'] for t in d['transactions'])"; }

# ---------------------------------------------------------------- deploy
if [ -z "${STANDING_ORDERS:-}" ]; then
  echo "== deploying"
  forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC" --private-key "$PRIVATE_KEY" --broadcast
  B=broadcast/Deploy.s.sol/43113/run-latest.json
  STANDING_ORDERS="$(json_get "$B" "[t['contractAddress'] for t in d['transactions'] if t['transactionType']=='CREATE'][0]")"
  DEPLOY_TX="$(tx_hashes "$B" | awk '{print $1}')"
  DOMAIN="$(cast call "$STANDING_ORDERS" 'DOMAIN_SEPARATOR()(bytes32)' --rpc-url "$RPC")"
  cat > deployments/fuji.json <<EOF
{
  "network": "Avalanche Fuji",
  "chainId": 43113,
  "standingOrders": "$STANDING_ORDERS",
  "usdc": "$USDC",
  "deployer": "$RELAYER",
  "deployTx": "$DEPLOY_TX",
  "domainSeparator": "$DOMAIN"
}
EOF
  echo "deployed: $STANDING_ORDERS (tx $DEPLOY_TX)"
  echo "== verifying source on Sourcify (non-fatal)"
  forge verify-contract "$STANDING_ORDERS" src/StandingOrders.sol:StandingOrders --chain-id 43113 \
    --verifier sourcify --constructor-args "$(cast abi-encode 'constructor(address)' "$USDC")" || echo "(verification failed or unavailable; do it manually)"
fi
export STANDING_ORDERS

# ---------------------------------------------------------------- demo
demo() { forge script script/DemoGasless.s.sol:DemoGasless --sig "$@" --rpc-url "$RPC" --private-key "$PRIVATE_KEY" --broadcast; }
# forge names the broadcast file after the --sig function when a signature is used
last_hashes() { tx_hashes "broadcast/DemoGasless.s.sol/43113/$1-latest.json"; }

echo "== plan"
demo "plan()" | tee "$LOGDIR/plan.log"
PLAN_ID="$(grep -o 'planId: [0-9]*' "$LOGDIR/plan.log" | awk '{print $2}')"
PLAN_TX="$(last_hashes plan)"
echo "== gasless subscribe (plan $PLAN_ID)"
demo "subscribe(uint256)" "$PLAN_ID" | tee "$LOGDIR/sub.log"
SUB_ID="$(grep -o 'subscriptionId: [0-9]*' "$LOGDIR/sub.log" | awk '{print $2}')"
SUBSCRIBE_TX="$(last_hashes subscribe)"
echo "== waiting 65 s for the next period"; sleep 65
echo "== keeper charge"
# Sent with `cast send` and an explicit gas limit: gas estimation runs against the latest block, which on a
# quiet testnet can be older than the due time, so it would size the gas for the "not due yet" path.
CHARGE_TX="$(cast send "$STANDING_ORDERS" 'chargeDue(uint256[])' "[$SUB_ID]" --gas-limit 500000   --private-key "$PRIVATE_KEY" --rpc-url "$RPC" --json | python3 -c "import sys,json; print(json.load(sys.stdin)['transactionHash'])")"
echo "charge tx: $CHARGE_TX"
[ "$(first "$(cast call "$STANDING_ORDERS" 'subscription(uint256)((address,uint64,uint32,uint64,uint64,uint32,bool))' "$SUB_ID" --rpc-url "$RPC" | awk -F', ' '{print $3}')")" = "2" ]   || { echo "WARNING: chargeCount is not 2; the charge may not have been due yet"; }
echo "== gasless cancel"
demo "cancel(uint256)" "$SUB_ID"
CANCEL_TX="$(last_hashes cancel)"

SUB_AVAX_AFTER="$(cast balance "$SUB" --rpc-url "$RPC")"
SUB_USDC_AFTER="$(first "$(cast call "$USDC" 'balanceOf(address)(uint256)' "$SUB" --rpc-url "$RPC")")"
cat > deployments/fuji-demo.json <<EOF
{
  "standingOrders": "$STANDING_ORDERS",
  "planId": $PLAN_ID,
  "subscriptionId": $SUB_ID,
  "subscriber": "$SUB",
  "relayerAndMerchant": "$RELAYER",
  "createPlanTx": "$PLAN_TX",
  "subscribeWithPermitForTx": "$SUBSCRIBE_TX",
  "chargeDueTx": "$CHARGE_TX",
  "cancelForTx": "$CANCEL_TX",
  "subscriberAvaxBefore": "$SUB_AVAX",
  "subscriberAvaxAfter": "$SUB_AVAX_AFTER",
  "subscriberUsdcBefore": "$SUB_USDC",
  "subscriberUsdcAfter": "$SUB_USDC_AFTER"
}
EOF
echo
echo "DONE. Subscriber AVAX: $SUB_AVAX -> $SUB_AVAX_AFTER ; USDC: $SUB_USDC -> $SUB_USDC_AFTER"
echo "Records: deployments/fuji.json, deployments/fuji-demo.json"
