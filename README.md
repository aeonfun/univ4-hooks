# univ4-hooks

The aeon.fun Uniswap v4 hook fleet: 10 hooks that all inherit a mandatory 10 bps
protocol fee (`AeonFee`), deployed on Base (8453), Robinhood Chain (4663),
Ethereum (1), and Monad (143).

## Hooks

| Hook | What it does |
|------|--------------|
| AeonFee | Base: mandatory non-virtual 10 bps fee on the unspecified currency, routed to a fixed treasury. Inherited by all 10. |
| DynamicFee | Higher LP fee when the market is choppy, eased when calm (one-swap lag). |
| NoOp | Passthrough; only the base fee applies. |
| HeavierHand | Only admits swaps paying in the heavier side; inverts past a skew cap. Virtual reserves via StateLibrary. |
| BlockEcho | Swap size must echo the block number's trailing digits (within a window). |
| TailTwins | Swap size low byte must match the live price low byte (within tolerance). |
| TotalizerTrap | Blocks swaps that would land the pool's running total on a multiple of 11. |
| CrownClash | 0.07% tribute + on-chain volume leaderboard. Custody-free (routes straight to treasury). |
| LegacyLedger | 0.05% tax + on-chain loyalty tiers. Custody-free. |
| ExactInGate | Admits exact-input swaps only; blocks exact-output. |
| CapGate | Rejects swaps above a fixed size cap. |

## AeonFee base

Every hook inherits `AeonFee`, which takes 10 bps of each swap's unspecified
(output) currency and routes it to a fixed treasury via `poolManager.take()`.
The recipient and rate are compile-time constants and `afterSwap` is not virtual,
so a derived hook cannot lower, skip, or redirect the protocol fee. A hook layers
its own post-swap logic through `_afterSwapExtra`, which runs after the fee is
taken (effective fee = max(hook's own fee, 10 bps)).

## Build and test

```
forge build
forge test
```

`lib/v4-core` is the vendored v4-core source the contracts build against (kept
in-tree so the build matches the deployed bytecode). Unit tests are self-contained
(no forge-std). The mainnet-fork gates in `test/fork/` need an RPC, e.g.:

```
forge test --fork-url <eth-mainnet-rpc> --match-path test/fork/ForkDeploy.t.sol -vv
```

## Live addresses

See `DEPLOYMENTS.md`.
