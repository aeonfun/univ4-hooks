# xcl game hooks

Three Uniswap v4 game hooks for ETH-quoted pools, deployed on Base and Robinhood (addresses in `DEPLOYMENTS.md`). Audit summaries are in `audits/`.

| Hook | Source | Game |
|---|---|---|
| LastBuyerWins | `src/LastBuyerWins.sol` | Every qualifying buy resets a 1 hour clock. When it runs out, the last buyer takes 80% of the pot. |
| ComboBreaker | `src/ComboBreaker.sol` | Back-to-back buys grow a combo and pay less. The sell that breaks it pays the streak's buyers. |
| TeamWar | `src/TeamWar.sol` | Red vs blue. The team with more weekly ETH volume takes both pots. |

All three inherit `EthGameHook` (`src/EthGameHook.sol`), which inherits the fleet `AeonFee` (mandatory 10 bps, `src/AeonFee.sol`, copied unchanged from `aeonfun/aeon` `skills/deploy-uni-hook/templates`).

`EthGameHook` does the shared work:

- `beforeInitialize` reverts unless `currency0` is native ETH.
- Game fee always in ETH, in all four swap shapes. If ETH is the specified side, the fee comes off in `beforeSwap`. Otherwise it comes off in `_afterSwapExtra`, after AeonFee.
- Player identity: 32-byte `hookData` address, then the router's `msgSender()` (gas-capped), then `tx.origin` (LastBuyerWins and ComboBreaker only; TeamWar has no `tx.origin` fallback).
- Pull-only payouts, a reentrancy lock, and a `receive()` that only accepts ETH from the PoolManager. No admin, no rescue function.

Flags for all three: `BEFORE_INITIALIZE | BEFORE_SWAP | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA` = `0x20CC`. Because of the return deltas, these pools need the Uniswap Labs allowlist to be routed.

## Changes from the specs

- **Partial fills revert.** Applies when ETH is the specified side and a game fee is charged. A price-limited swap would otherwise score its full specified size while filling only a small part. The Universal Router does not set a price limit, so normal swaps are not affected.
- **TeamWar `claim(key, weekIds)`.** The spec's `weeks` is a reserved word in Solidity. `claim` also finalizes any finished week it is given.
- **TeamWar zero-volume weeks.** A week where both teams only paid fees below `MIN_SWAP` has no volume, so nobody could claim its pots. Those pots roll into the same teams' pots for the current week.
- **ComboBreaker has no forfeit.** The spec's "breaker forfeits their own weight" cannot be enforced safely. `hookData` and a router's `msgSender()` are chosen by the caller, and `tx.origin` can be borrowed by any contract the player calls (MiniAeon sc-audit, M-1 with PoC). So any forfeit lets an attacker wipe someone else's share, while a second wallet dodges it for free. A breaker who also bought gets back only their pro-rata share of their own fee. The "only buyer, so the pot rolls to seed" rule goes with it.
- **TeamWar: join only with `joinTeam()`.** The spec's first-swap `hookData` join is removed. Any contract a player calls could otherwise sign them up through a borrowed `tx.origin`, after which they would pay 25 bps on every swap with no way out (MiniAeon sc-audit, M-1 with PoC).
- **TeamWar: no `tx.origin` fallback.** The player is the `hookData` address, else the router's `msgSender()`. A swap with neither is treated as a non-member's and pays no game fee. Otherwise a vault or keeper swap would be taxed and credited to whoever sent the transaction (sc-audit L-1). The Universal Router reports `msgSender()`. On other routers, put your address in `hookData`. The spec's 33-byte `hookData` (address plus team byte) is ignored.
- **Accepted: a public call-forwarder can be enrolled.** `joinTeam` trusts `msg.sender`, so anyone can make a public arbitrary-call contract (a multicall or forwarder that calls on behalf of anyone) call `joinTeam`. Users who route swaps through that contract into a `msgSender()` router then pay the 25 bps game fee, because the router reports the forwarder as the player. Integrators: do not route TeamWar swaps through a shared forwarder; call the router directly or pass your address in `hookData` (sc-audit re-audit L-1, plausible).
- **Nested swaps revert.** `beforeSwap` reverts while another swap's fill check is pending. This stops a hostile pool token re-entering during the AeonFee take to skip the partial-fill check (sc-audit, all three hooks).
- **Exact-out sells pay the game fee on the net ETH out** (`X`), not the gross pool release (`X + fee`). At the 5% ComboBreaker cap the effective rate is 4.76%. Accepted (sc-audit L-1).
- **ComboBreaker weight matures.** A buy's weight counts in the pot split only once it is 10 full minutes old (`MATURITY_MINUTES`, minute granularity), and a streak can be broken only once its first buy's weight counts; a big sell before then is a chip. Stops a trader buying in and breaking in one block to take most of a pot others built (MiniAeon sc-audit re-audit, M-1 with PoC). A buy in the last 10 minutes before a close gets no share of that pot, but its buyer gets their own game fee back. Without that refund, a dust opener could break at minute 11 and take every younger buyer's fee (sc-audit third pass, M-1 with PoC).
- **Accepted: pre-positioned weight with no exposure.** Selling never reduces weight (seller identity can be faked or borrowed), so a trader can buy, sell the tokens back as chips in the same block, wait 10 minutes, then break and claim. This costs the round-trip LP fee and AeonFee, needs 10 minutes in public, and only pays when the pot is large relative to streak volume (heavy chip selling or a big seed pot). Same family as the spec's accepted "late buyer shares by ETH weight".
- **Accepted: pumping the breaker fee.** The breaker fee counts buys, not their size or age, so a holder ordered just ahead of a breaking sell can add many `MIN_BUY` buys and raise that sell's fee by up to 470 bps. The extra fee lands in a pot the holder shares (sc-audit fourth pass, M-1, plausible; e.g. a 5 ETH break loses 0.22 ETH to 46 pumps costing 0.046 ETH). It needs ordering ahead of a seen transaction, which Base's private mempool makes hard, and a breaker's slippage limit caps the loss. Breakers: set a tight `amountOutMinimum` and check `preview()` before signing.
- **Scoring minimums are at least 10,000 wei** (`MIN_FLOOR`). That keeps every scoring swap paying a non-zero fee, so the partial-fill check always applies.
- **TeamWar `war(id, week)` view.** Solidity's auto getter drops struct arrays, so this view returns the full war state.

