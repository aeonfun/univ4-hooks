# sc-audit summary: TeamWar

- Auditor: MiniAeon `sc-audit` (local mode, source-level), 2 passes on 2026-10-06
- Deployed: Base `0x8DfA52588d4423e96a93E6923BdE3240af6320cC`, Robinhood `0x9C657d8637E98b9299Be6e4e23d52fD2713aA0Cc` (source verified on Basescan and Sourcify)
- Source: [`src/vendor/XclGames/src/TeamWar.sol`](../src/vendor/XclGames/src/TeamWar.sol), on `EthGameHook` + `AeonFee`
- Marketplace: [aeon.fun/hooks](https://www.aeon.fun/hooks?hook=teamwar)
- Tests at deploy: 133 unit, fuzz and Base-fork tests (real PoolManager and Universal Router V2 / V2.1.2), all passing

- Outcome: **0 open findings, 1 accepted low.**

## Shared base (EthGameHook), fixed before deploy

- A nested swap during the AeonFee take could skip the partial-fill check. `beforeSwap` now reverts while a fill check is pending.
- Partial fills on a price-limited swap would score the full specified size. They now revert when a game fee is charged.
- Exact-out sells pay the game fee on the net ETH out, not the gross amount. Accepted (low).

## Fixed before deploy

- Joining through a first swap's `hookData` let any contract a player called sign them up via `tx.origin`, after which every swap paid 25 bps. Joining is now only via `joinTeam()`.
- A `tx.origin` fallback taxed vault and keeper swaps and credited whoever sent the transaction. Removed: the player is the `hookData` address, else the router's `msgSender()`, else nobody (no fee).

## Accepted

- **Public forwarders can be enrolled (low).** `joinTeam` trusts `msg.sender`, so anyone can make a shared multicall or forwarder join a team; users routing through that forwarder into a `msgSender()` router then pay the game fee. Integrators should call the router directly or pass their address in `hookData`.
