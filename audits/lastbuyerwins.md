# sc-audit summary: LastBuyerWins

- Auditor: MiniAeon `sc-audit` (local mode, source-level), 2 passes on 2026-10-06
- Deployed: Base `0x5D505d56d4B62f5F83493b4acb03353bBde760CC`, Robinhood `0x94DE41E76700443F3d6673a397B00d41CF6ea0cc` (source verified on Basescan and Sourcify)
- Source: [`src/vendor/XclGames/src/LastBuyerWins.sol`](../src/vendor/XclGames/src/LastBuyerWins.sol), on `EthGameHook` + `AeonFee`
- Marketplace: [aeon.fun/hooks](https://www.aeon.fun/hooks?hook=lastbuyerwins)
- Tests at deploy: 133 unit, fuzz and Base-fork tests (real PoolManager and Universal Router V2 / V2.1.2), all passing

- Outcome: **CLEAN** on the second pass (0 open findings).

## Shared base (EthGameHook), fixed before deploy

- A nested swap during the AeonFee take could skip the partial-fill check. `beforeSwap` now reverts while a fill check is pending.
- Partial fills on a price-limited swap would score the full specified size. They now revert when a game fee is charged.
- Exact-out sells pay the game fee on the net ETH out, not the gross amount. Accepted (low).

## Checked

Round settlement and the 80/20 split, the rising minimum buy, lazy settle on the next swap, pull-only claims and `claimFor`, ETH-only pools, and the fee on all four swap shapes.
