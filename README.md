# Standing Orders — recurring USDC payments on Avalanche C-Chain

Standing Orders brings subscriptions to Avalanche. A merchant publishes a plan with a **fixed price** and a **fixed
period**. A subscriber authorises it once with a signature and pays the first period in the same transaction. After
that, each period's payment is pulled on schedule by the merchant, by a keeper bot, or by anyone else.
The contract enforces the protections subscribers expect from a bank standing order:

- the price can never change on existing subscribers;
- at most one charge per period, never early;
- missed periods are never back-charged in bulk;
- each subscription has a hard cap on the number of charges;
- cancel any time, effective immediately.

**New in this Avalanche port: the subscriber needs no AVAX.** The subscriber signs two off-chain messages
(an EIP-2612 permit for USDC and an EIP-712 `Subscribe` message). The merchant, or any relayer, submits them in one
transaction and pays the gas. Cancelling is gasless too (`Cancel` message).

| | |
|---|---|
| **Status** | Experimental. **Unaudited.** Please use small amounts. |
| **Token** | Circle's native USDC on C-Chain: mainnet `0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E`, Fuji `0x5425890298aed601595a70AB815c96711a31Bc65` ([Circle's table](https://developers.circle.com/stablecoins/usdc-contract-addresses)) |
| **Fuji deployment** | [`0x2810b4f331c00f882a30ff5ac664561c9cbf225c`](https://testnet.snowtrace.io/address/0x2810b4f331c00f882a30ff5ac664561c9cbf225c) — gasless demo transactions in [`deployments/fuji-demo.json`](deployments/fuji-demo.json) |
| **Demo video (56 s)** | [`media/standing-orders-avalanche-60s.mp4`](media/standing-orders-avalanche-60s.mp4) — Fuji deployment, gasless subscribe and cancel, tests |
| **Avalanche mainnet** | not deployed yet (planned for milestone 1 of the grant application) |
| **Original (live)** | the same contract family on Arc mainnet, chain 5042: [`0x26b69B3fA2E5d12da11851A80f0c8F66Ff3d0002`](https://explorer.arc.io/address/0x26b69B3fA2E5d12da11851A80f0c8F66Ff3d0002), source verified on Sourcify (exact match) |

## What changed compared with the Arc version

| | Arc version | This port |
|---|---|---|
| Token | Arc's native USDC through its ERC-20 interface (`name "USDC"`) | Circle native USDC on C-Chain (`name "USD Coin"`, `version "2"`), address chosen by chain id in the deploy script |
| EVM target | Prague | **Cancun** — C-Chain runs Cancun opcodes; `eth_call` probes of PUSH0, MCOPY and TSTORE succeeded on mainnet and Fuji on 1 Oct 2026, and the newer `CLZ` opcode is not available yet |
| Who pays gas | subscriber (in USDC, as Arc's gas token) | subscriber **or the merchant/relayer**, in AVAX |
| Subscribe | `subscribe`, `subscribeWithPermit` | the same, plus `subscribeFor` and `subscribeWithPermitFor` (relayed) |
| Cancel | `cancel` | `cancel`, plus `cancelFor` (relayed) |
| Replay protection | n/a | EIP-712 domain (chain id + contract), per-subscriber `nonces`, `deadline`, low-s signatures only |

Everything else — schedule logic, caps, batching, events, views — is unchanged, and the 23 original tests pass
unchanged against the port.

## How the gasless flow works

```
subscriber (USDC only)            merchant / relayer (has AVAX)                StandingOrders            USDC
        |  sign Permit(…)  ─────────────►|                                         |                       |
        |  sign Subscribe(…) ───────────►|  subscribeWithPermitFor(…, sig, permit) |                       |
        |                                |────────────────────────────────────────►| verify Subscribe sig  |
        |                                |                                         |  (nonce, deadline)    |
        |                                |                                         |── permit(owner=sub) ──►|
        |                                |                                         |── transferFrom(sub→merchant)►|
```

- The relayer can **submit or withhold** a signed message. It cannot change it: `subscriber`, `planId`,
  `maxCharges`, `nonce` and `deadline` are all inside the signature, so is the chain id and this contract's address.
- A signature works exactly once (`nonces[subscriber]` is consumed) and only before its `deadline`.
- The permit is wrapped in `try/catch`: if anyone front-runs the permit signature, the allowance is already set
  and the subscription still succeeds.
- To stop the money flow without any gas, the subscriber can also sign a permit with `value = 0`; anyone can submit it.

### Why EIP-712 signatures inside the contract, not ERC-2771

A trusted forwarder changes the meaning of `msg.sender` for the entire contract and adds a second contract that
must be trusted and audited (and ERC-2771 combined with multicall has had a known sender-spoofing class of bugs). Here only two
functions need a relayed identity, so each verifies one typed signature itself. The contract stays dependency-free
and has one small, testable surface.

### What to sign (verified)

Domain of the contract: `{ name: "StandingOrders", version: "1", chainId, verifyingContract }`.

```json
{
  "primaryType": "Subscribe",
  "types": { "Subscribe": [
    {"name":"subscriber","type":"address"}, {"name":"planId","type":"uint256"},
    {"name":"maxCharges","type":"uint32"},  {"name":"nonce","type":"uint256"},
    {"name":"deadline","type":"uint256"} ] },
  "message": { "subscriber": "0x…", "planId": "1", "maxCharges": 12, "nonce": "<nonces(subscriber)>", "deadline": "<unix>" }
}
```

`Cancel` is `{ subscriber, subscriptionId, nonce, deadline }`. The permit is the token's standard EIP-2612 `Permit`
with the **token's** domain `{ name: "USD Coin", version: "2", chainId, verifyingContract: <USDC> }`, `spender` =
this contract. Both JSON shapes are checked end to end by `scripts/typed-data-check.sh`, which signs them with
`cast wallet sign --data` (an EIP-712 implementation independent of the contract and of Foundry) and submits them
to a local node with a subscriber that holds no native balance.

## Contract interface

```solidity
createPlan(name, price, period)                                   // merchant; terms are immutable
subscribe(planId, maxCharges)                                     // after a regular approve
subscribeWithPermit(planId, maxCharges, allowance, deadline, v, r, s)           // 1 tx, subscriber pays gas
subscribeFor(subscriber, planId, maxCharges, deadline, signature)               // relayed, allowance exists
subscribeWithPermitFor(subscriber, planId, maxCharges, deadline, signature, permit) // relayed, fully gasless
cancel(id) / cancelFor(subscriber, id, deadline, signature)       // subscriber or merchant / relayed
chargeDue(uint256[] ids) / charge(id)                             // permissionless; pays the merchant
dueSubscriptionsOfPlan(planId, offset, limit)                     // view a keeper uses to find due ids
setPlanActive(planId, bool)                                       // merchant pauses/resumes a plan
nonces(address) / DOMAIN_SEPARATOR()                              // for wallets and relayers
```

Contract: [`src/StandingOrders.sol`](src/StandingOrders.sol). No owner, no fees, no upgradeability, no payable
functions. The contract never holds USDC or AVAX.

## Tests

```bash
git clone --recursive <repo> && cd standing-orders-avalanche
forge test                                                 # 51 unit + fuzz tests (4 fork tests are skipped without a fork)
forge test --match-contract AvalancheFork --fork-url https://api.avax-test.network/ext/bc/C/rpc   # Fuji, real Circle test USDC
forge test --match-contract AvalancheFork --fork-url https://api.avax.network/ext/bc/C/rpc        # mainnet fork, read-only, nothing is sent
./scripts/typed-data-check.sh                              # independent EIP-712 signer vs the contract, on a local node
```

- `test/StandingOrders.t.sol` — the 23 original tests: schedule, caps, permit, front-running, batch failures, pause.
- `test/Gasless.t.sol` — 28 tests for the relayed flow: the subscriber never holds AVAX; every signed field is bound
  (plan, cap, subscriber, deadline); replays, expired, wrong key, other contract, other chain id, malleable and
  malformed signatures; cross-message replay (Cancel used as Subscribe); permit front-running; shared nonce;
  full lifecycle; fuzzing of corrupted signatures and random signers.
- `test/AvalancheFork.t.sol` — runs against Circle's **real** USDC on a fork of Fuji or C-Chain mainnet: the
  permit domain the signer uses matches the token, the whole gasless lifecycle works with the real token, and a
  subscriber blocklisted by Circle does not block a batch.

The relayed code paths were also mutation-tested by hand: 15 deliberate breakages (no nonce increment, no deadline
check, no low-s check, no signer check, a field dropped from the signed hash, wrong typehash, domain without chain id
or contract, permit not wrapped in try/catch, …) — 14 are caught by the suite. The one survivor is a redundant
guard: `address(0)` as subscriber is already rejected earlier by the strict ECDSA recovery.

## Costs

Gas measured on a fork with the real USDC (mainnet fork, local execution, 1 Oct 2026). USD figures use the
`eth_gasPrice` of about 5 gwei seen on C-Chain that day and AVAX at about $11 (CoinPaprika); they move with both.

| Action | Gas | Cost at 5 gwei, AVAX $11 |
|---|---|---|
| Deploy `StandingOrders` | ≈ 2.73 M (`eth_estimateGas` on mainnet and Fuji) | ≈ $0.15 |
| `createPlan` | ≈ 159.5 k | ≈ $0.009 |
| `subscribeWithPermitFor` (first period included), paid by the merchant | ≈ 351.6 k | ≈ $0.019 |
| `chargeDue` with one due subscription (first call, cold storage) | ≈ 78 k | ≈ $0.004 |
| `cancelFor`, paid by the merchant | ≈ 48.2 k | ≈ $0.003 |

C-Chain produced blocks about once per second when measured, so a merchant can unlock access on the first receipt.

## Deploy

```bash
cp .env.example .env                       # test key goes into .env, never commit it
source .env
# Fuji (testnet): needs a few test AVAX for gas
forge script script/Deploy.s.sol:Deploy --rpc-url fuji --private-key $PRIVATE_KEY --broadcast
# Mainnet additionally needs ALLOW_MAINNET=true, so it cannot happen by accident
```

The deploy script chooses the USDC address by chain id from Circle's table and checks the token's `name`, `version`
and `decimals` before deploying. It refuses any other chain.

End-to-end demo on Fuji with Circle's test USDC (get test USDC from <https://faucet.circle.com>, subscriber needs no AVAX):

```bash
export STANDING_ORDERS=<deployed address>
forge script script/DemoGasless.s.sol:DemoGasless --sig "plan()"            --rpc-url fuji --private-key $PRIVATE_KEY --broadcast
forge script script/DemoGasless.s.sol:DemoGasless --sig "subscribe(uint256)" 1 --rpc-url fuji --private-key $PRIVATE_KEY --broadcast
# after 60 s
forge script script/DemoGasless.s.sol:DemoGasless --sig "charge(uint256)" 1 --gas-limit 500000 --rpc-url fuji --private-key $PRIVATE_KEY --broadcast
forge script script/DemoGasless.s.sol:DemoGasless --sig "cancel(uint256)" 1    --rpc-url fuji --private-key $PRIVATE_KEY --broadcast
```

Everything above in one command (checks balances, deploys, runs the demo, writes `deployments/*.json`): `./scripts/fuji-run-all.sh`.

Keeper: `STANDING_ORDERS=<addr> PLAN_IDS="1" RPC_URL=<rpc> PRIVATE_KEY=<keeper key> ./scripts/keeper.sh --interval 60`.

## Security notes and limitations

- **Unaudited prototype.** Use small amounts, and only sign caps you are comfortable with.
- **EOA signatures only.** Relayed actions use `ecrecover`. Smart-contract wallets can use `approve` + `subscribe`
  with their own gas (EIP-1271 support is a possible follow-up).
- **A relayer can delay but not forge.** It may refuse to submit a signed message. Signatures carry a `deadline`; wallets
  should set it to minutes. A subscriber who wants out can always send a signed `Cancel` or a zero-value permit to
  any other relayer, or call `cancel` / `approve(contract, 0)` with their own gas.
- **Pull payments rely on allowances.** Revoking the USDC allowance stops every charge immediately.
- **A subscription that reached its cap stays "active" until cancelled**, which blocks subscribing to the same plan
  again; cancel it first (gasless via `cancelFor`).
- **USDC is a centrally issued token.** Circle can pause or blocklist addresses; a failed pull is reported as
  `ChargeFailed` and never blocks a batch.
- **No refunds.** Cancelling stops future charges; the current period is not refunded on-chain.
- **Keepers are not paid by the protocol.** The merchant runs the keeper, or pays one off-chain.

## Project layout

```
src/StandingOrders.sol          contract
test/StandingOrders.t.sol       original tests (schedule, caps, permit, batch failures)
test/Gasless.t.sol              relayed flow: subscribeFor, subscribeWithPermitFor, cancelFor
test/AvalancheFork.t.sol        real Circle USDC on a Fuji / C-Chain fork
test/mocks/MockUSDC.sol         local-only token mimicking Circle's FiatToken (permit domain "USD Coin" / "2")
script/Deploy.s.sol             Fuji / C-Chain deployment, token chosen by chain id
script/DeployLocal.s.sol        anvil deployment with a mock USDC
script/DemoGasless.s.sol        Fuji demo: plan → gasless subscribe → charge → gasless cancel
scripts/keeper.sh               cron-friendly keeper (Foundry cast)
scripts/typed-data-check.sh     independent EIP-712 signer vs the contract
```

## License

MIT.
