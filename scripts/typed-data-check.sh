#!/usr/bin/env bash
# Cross-implementation check of the typed data documented in the README.
#
# The subscriber's messages are signed by `cast wallet sign --data` (an EIP-712 implementation that is
# independent of the contract and of Foundry's `vm.sign`), then submitted to a local anvil node.
# Passing proves that the JSON in the README is exactly what the contract verifies, and that a subscriber
# with ZERO native balance can subscribe (EIP-2612 permit + Subscribe message) and cancel (Cancel message).
#
#   ./scripts/typed-data-check.sh        # needs Foundry (forge, cast, anvil); touches only a local node
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
PORT=8547
L="http://127.0.0.1:$PORT"
# anvil's well-known dev key #0: relayer and merchant (local node only)
RELAYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
MERCHANT=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

wallet_field() { cast wallet new --json | python3 -c "import sys,json; d=json.load(sys.stdin)['data']; d=d[0] if isinstance(d,list) else d; print(d['$1'])"; }
SUB_KEY="$(wallet_field private_key)"
SUB="$(cast wallet address --private-key "$SUB_KEY")"

cleanup() { kill "$ANVIL_PID" 2>/dev/null || true; rm -rf "$TMP" "$ROOT/broadcast/DeployLocal.s.sol"; }
anvil --port "$PORT" --silent &
ANVIL_PID=$!
trap cleanup EXIT
sleep 3

cd "$ROOT"
OUT="$(forge script script/DeployLocal.s.sol:DeployLocal --rpc-url "$L" --private-key "$RELAYER_KEY" --broadcast 2>&1)"
USDC="$(echo "$OUT" | grep "MockUSDC deployed at" | awk '{print $NF}')"
SO="$(echo "$OUT" | grep "StandingOrders deployed at" | awk '{print $NF}')"
CHAIN="$(cast chain-id --rpc-url "$L")"

cast send "$SO" "createPlan(string,uint96,uint32)" "Typed-data check" 2000000 60 --private-key "$RELAYER_KEY" --rpc-url "$L" >/dev/null
cast send "$USDC" "mint(address,uint256)" "$SUB" 10000000 --private-key "$RELAYER_KEY" --rpc-url "$L" >/dev/null

DEADLINE=$(( $(cast block latest --field timestamp --rpc-url "$L") + 1800 ))
SO_NONCE="$(cast call "$SO" "nonces(address)(uint256)" "$SUB" --rpc-url "$L" | awk '{print $1}')"
TOKEN_NONCE="$(cast call "$USDC" "nonces(address)(uint256)" "$SUB" --rpc-url "$L" | awk '{print $1}')"

domain_types='"EIP712Domain": [
      {"name": "name", "type": "string"}, {"name": "version", "type": "string"},
      {"name": "chainId", "type": "uint256"}, {"name": "verifyingContract", "type": "address"}]'

cat > "$TMP/permit.json" <<EOF
{ "types": { $domain_types,
    "Permit": [{"name":"owner","type":"address"},{"name":"spender","type":"address"},{"name":"value","type":"uint256"},{"name":"nonce","type":"uint256"},{"name":"deadline","type":"uint256"}] },
  "primaryType": "Permit",
  "domain": {"name": "USD Coin", "version": "2", "chainId": $CHAIN, "verifyingContract": "$USDC"},
  "message": {"owner": "$SUB", "spender": "$SO", "value": "6000000", "nonce": "$TOKEN_NONCE", "deadline": "$DEADLINE"} }
EOF
cat > "$TMP/subscribe.json" <<EOF
{ "types": { $domain_types,
    "Subscribe": [{"name":"subscriber","type":"address"},{"name":"planId","type":"uint256"},{"name":"maxCharges","type":"uint32"},{"name":"nonce","type":"uint256"},{"name":"deadline","type":"uint256"}] },
  "primaryType": "Subscribe",
  "domain": {"name": "StandingOrders", "version": "1", "chainId": $CHAIN, "verifyingContract": "$SO"},
  "message": {"subscriber": "$SUB", "planId": "1", "maxCharges": 3, "nonce": "$SO_NONCE", "deadline": "$DEADLINE"} }
EOF

PERMIT_SIG="$(cast wallet sign --data --from-file "$TMP/permit.json" --private-key "$SUB_KEY")"
SUBSCRIBE_SIG="$(cast wallet sign --data --from-file "$TMP/subscribe.json" --private-key "$SUB_KEY")"
R="0x${PERMIT_SIG:2:64}"; S="0x${PERMIT_SIG:66:64}"; V=$((16#${PERMIT_SIG:130:2}))

BEFORE="$(cast balance "$SUB" --rpc-url "$L")"
cast send "$SO" "subscribeWithPermitFor(address,uint256,uint32,uint256,bytes,(uint256,uint256,uint8,bytes32,bytes32))" \
  "$SUB" 1 3 "$DEADLINE" "$SUBSCRIBE_SIG" "(6000000,$DEADLINE,$V,$R,$S)" --private-key "$RELAYER_KEY" --rpc-url "$L" >/dev/null
AFTER="$(cast balance "$SUB" --rpc-url "$L")"

[ "$BEFORE" = "0" ] && [ "$AFTER" = "0" ] || { echo "FAIL: subscriber native balance changed ($BEFORE -> $AFTER)"; exit 1; }
MERCHANT_USDC="$(cast call "$USDC" "balanceOf(address)(uint256)" "$MERCHANT" --rpc-url "$L" | awk '{print $1}')"
[ "$MERCHANT_USDC" = "2000000" ] || { echo "FAIL: merchant USDC is $MERCHANT_USDC"; exit 1; }
echo "OK  subscribeWithPermitFor: subscriber native balance 0 -> 0, merchant received 2.00 USDC"

SO_NONCE="$(cast call "$SO" "nonces(address)(uint256)" "$SUB" --rpc-url "$L" | awk '{print $1}')"
cat > "$TMP/cancel.json" <<EOF
{ "types": { $domain_types,
    "Cancel": [{"name":"subscriber","type":"address"},{"name":"subscriptionId","type":"uint256"},{"name":"nonce","type":"uint256"},{"name":"deadline","type":"uint256"}] },
  "primaryType": "Cancel",
  "domain": {"name": "StandingOrders", "version": "1", "chainId": $CHAIN, "verifyingContract": "$SO"},
  "message": {"subscriber": "$SUB", "subscriptionId": "1", "nonce": "$SO_NONCE", "deadline": "$DEADLINE"} }
EOF
CANCEL_SIG="$(cast wallet sign --data --from-file "$TMP/cancel.json" --private-key "$SUB_KEY")"
cast send "$SO" "cancelFor(address,uint256,uint256,bytes)" "$SUB" 1 "$DEADLINE" "$CANCEL_SIG" --private-key "$RELAYER_KEY" --rpc-url "$L" >/dev/null
ACTIVE="$(cast call "$SO" "subscription(uint256)((address,uint64,uint32,uint64,uint64,uint32,bool))" 1 --rpc-url "$L" | awk -F', ' '{print $NF}' | tr -d ')')"
[ "$ACTIVE" = "false" ] || { echo "FAIL: subscription still active"; exit 1; }
echo "OK  cancelFor: subscription inactive, subscriber native balance still $(cast balance "$SUB" --rpc-url "$L")"
