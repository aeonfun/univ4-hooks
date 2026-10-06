# sc-audit summary: ComboBreaker

- Auditor: MiniAeon `sc-audit` (local mode, source-level), 4 passes on 2026-10-06
- Deployed: Base `0xc6aa5B60c7822186d1612ea0653F9FDA645F20cC`, Robinhood `0x85C98FfF5Bee81278b4dE807465a4D86F39F20cc` (source verified on Basescan and Sourcify)
- Source: [`src/vendor/XclGames/src/ComboBreaker.sol`](../src/vendor/XclGames/src/ComboBreaker.sol), on `EthGameHook` + `AeonFee`
- Marketplace: [aeon.fun/hooks](https://www.aeon.fun/hooks?hook=combobreaker)
- Tests at deploy: 133 unit, fuzz and Base-fork tests (real PoolManager and Universal Router V2 / V2.1.2), all passing

- Outcome: **0 open fixable findings, 2 accepted risks** (one graded a plausible medium).

## Shared base (EthGameHook), fixed before deploy

- A nested swap during the AeonFee take could skip the partial-fill check. `beforeSwap` now reverts while a fill check is pending.
- Partial fills on a price-limited swap would score the full specified size. They now revert when a game fee is charged.
- Exact-out sells pay the game fee on the net ETH out, not the gross amount. Accepted (low).

## Fixed before deploy

- **Pass 1:** the spec's breaker forfeit used caller-chosen identity, so a breaker could wipe someone else's share. The forfeit is removed.
- **Pass 2:** a same-block buy-then-break took most of a pot others built. Fixed with weight maturity: a buy shares the pot only once 10 full minutes old, and a streak can break only once its first buy is mature.
- **Pass 3:** a dust opener breaking at minute 11 took every younger buyer's fee. Fixed: buys too new to share get their own fee back at close.
- **Pass 4:** confirmed the refund fix; claims never exceed what the hook holds (1000-run fuzz against an independent model).

## Accepted

- **Pre-positioned weight.** Selling never reduces weight (seller identity can be faked), so a trader can buy, sell back as chips, wait 10 minutes and share a later break. Costs round-trip fees, takes 10 minutes in public, and only pays when the pot is large relative to volume.
- **Breaker-fee pumping (plausible medium).** The breaker fee counts buys, not their size, so a holder ordered just ahead of a breaking sell can add many minimum buys and raise that sell's fee by up to 4.7 percentage points. It needs ordering ahead of a seen transaction, which Base's private mempool makes hard, and the breaker's slippage limit caps the loss. Breakers: set a tight `amountOutMinimum` and check `preview()` before signing.
