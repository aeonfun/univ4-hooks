# xcl game hooks

Two Uniswap v4 game hooks for ETH-quoted pools, deployed on Base and Robinhood (addresses in `DEPLOYMENTS.md`). Audit summaries are in `audits/`.

| Hook | Source | Game |
|---|---|---|
| LastBuyerWins | `src/LastBuyerWins.sol` | Every qualifying buy resets a 1 hour clock. When it runs out, the last buyer takes 80% of the pot. |
| TeamWar | `src/TeamWar.sol` | Red vs blue. The team with more weekly ETH volume takes both pots. |

Both inherit `EthGameHook` (`src/EthGameHook.sol`), which inherits the fleet `AeonFee` (mandatory 10 bps, `src/AeonFee.sol`, copied unchanged from `aeonfun/aeon` `skills/deploy-uni-hook/templates`).

`EthGameHook` does the shared work:

- `beforeInitialize` reverts unless `currency0` is native ETH.
- Game fee always in ETH, in all four swap shapes. If ETH is the specified side, the fee comes off in `beforeSwap`. Otherwise it comes off in `_afterSwapExtra`, after AeonFee.
- Player identity: 32-byte `hookData` address, then the router's `msgSender()` (gas-capped), then `tx.origin` (LastBuyerWins only; TeamWar has no `tx.origin` fallback).
- Pull-only payouts, a reentrancy lock, and a `receive()` that only accepts ETH from the PoolManager. No admin, no rescue function.

Flags for both: `BEFORE_INITIALIZE | BEFORE_SWAP | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA` = `0x20CC`. Because of the return deltas, these pools need the Uniswap Labs allowlist to be routed.

## Changes from the specs

- **Partial fills revert.** Applies when ETH is the specified side and a game fee is charged. A price-limited swap would otherwise score its full specified size while filling only a small part. The Universal Router does not set a price limit, so normal swaps are not affected.
- **TeamWar `claim(key, weekIds)`.** The spec's `weeks` is a reserved word in Solidity. `claim` also finalizes any finished week it is given.
- **TeamWar zero-volume weeks.** A week where both teams only paid fees below `MIN_SWAP` has no volume, so nobody could claim its pots. Those pots roll into the same teams' pots for the current week.
- **TeamWar: join only with `joinTeam()`.** The spec's first-swap `hookData` join is removed. Any contract a player calls could otherwise sign them up through a borrowed `tx.origin`, after which they would pay 25 bps on every swap with no way out (MiniAeon sc-audit, M-1 with PoC).
- **TeamWar: no `tx.origin` fallback.** The player is the `hookData` address, else the router's `msgSender()`. A swap with neither is treated as a non-member's and pays no game fee. Otherwise a vault or keeper swap would be taxed and credited to whoever sent the transaction (sc-audit L-1). The Universal Router reports `msgSender()`. On other routers, put your address in `hookData`. The spec's 33-byte `hookData` (address plus team byte) is ignored.
- **Accepted: a public call-forwarder can be enrolled.** `joinTeam` trusts `msg.sender`, so anyone can make a public arbitrary-call contract (a multicall or forwarder that calls on behalf of anyone) call `joinTeam`. Users who route swaps through that contract into a `msgSender()` router then pay the 25 bps game fee, because the router reports the forwarder as the player. Integrators: do not route TeamWar swaps through a shared forwarder; call the router directly or pass your address in `hookData` (sc-audit re-audit L-1, plausible).
- **Nested swaps revert.** `beforeSwap` reverts while another swap's fill check is pending. This stops a hostile pool token re-entering during the AeonFee take to skip the partial-fill check (sc-audit, both hooks).
- **Exact-out sells pay the game fee on the net ETH out** (`X`), not the gross pool release (`X + fee`). Accepted (sc-audit L-1).
- **Scoring minimums are at least 10,000 wei** (`MIN_FLOOR`). That keeps every scoring swap paying a non-zero fee, so the partial-fill check always applies.
- **TeamWar `war(id, week)` view.** Solidity's auto getter drops struct arrays, so this view returns the full war state.

