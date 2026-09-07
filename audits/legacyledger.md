# sc-audit report: base:0xDb4a0eb0410407d6C22A35c27288834e0D9F4044 (LegacyLedger)

- Auditor: aeon sc-audit (autonomous agentic review + Slither + fuzz)
- Date: 2026-09-07   ·   Mode: onchain
- Target: `base:0xDb4a0eb0410407d6C22A35c27288834e0D9F4044` (LegacyLedger) - aeon.fun Base v4 hook
- On-chain context: non-proxy (EIP-1967 impl slot = 0x0); native balance **0 wei** (custody-free); immutable `poolManager` = `0x498581Ff718922c3f8e6A244956aF099B2652b2b` (canonical Base v4 PoolManager); `AEON_FEE_RECIPIENT` = `0xF1E958db7D1e4C074377946018Ad645db4FB158e` (aeon treasury)
- Outcome: **CLEAN (0 confirmed)**
- Disclosure: none (clean); operator-gated by default for own/aeon.fun hooks - nothing to stage

## 1. Executive summary
LegacyLedger is one of the operator's own aeon.fun Uniswap v4 hooks on Base: a custody-free `afterSwap` hook that takes the mandatory 10 bps `AeonFee` protocol fee plus its own opt-in 5 bps "legacy tax" on the swap's unspecified currency and routes both straight to the aeon treasury via `poolManager.take()`. This run re-audited the **live verified source at HEAD** (explicit operator `var=` re-audit; the same immutable-bytecode address audited clean 2026-08-21 and 2026-08-24). The surface is two small production contracts (~185 LOC) over 14 vendored `@uniswap/v4-core` files that are **byte-identical to npm 1.0.1**. All eight modeled invariants hold; the single Slither hit is a false positive in unmodified vendored assembly. **No confirmed findings.**

## 2. Scope
- Contracts reviewed: **2/2** production (`src/AeonFee.sol`, `src/LegacyLedger.sol`), ~185 LOC
- Entrypoints reviewed: **1/1** external state-changing (`afterSwap`, gated `onlyPoolManager`); plus 2 `view` helpers (`loyaltyTier`, `marksToMaxTier`) and public constant/mapping getters
- Address audited: `0xDb4a0eb0410407d6C22A35c27288834e0D9F4044` (Base / chainid 8453), verified source via Etherscan V2, solc 0.8.26, evm cancun, non-proxy
- Not reviewed this run: the 14 vendored `@uniswap/v4-core` library/interface/type files were checked for **provenance only** (SHA-256 vs upstream) - they are dependency code, not this hook's logic. The PoolManager itself (`0x4985…2b2b`) is upstream Uniswap and out of scope.

## 3. Methodology
Threat-model-first: derived 8 invariants (S5.0), hunted a path breaking each (S5), adversarially refuted the one Slither survivor (S6). Fuzz arm not run (hard gate - 0 findings survived triage).
- Tools: slither(**ok** - 1 hit, refuted), agentic(**ok** - 0 candidates), fuzz(**skipped** - clean-audit hard gate S6.5)
- Provenance (MODE=onchain): **14/14 vendored `@uniswap/v4-core` files byte-identical (SHA-256) to a freshly-downloaded npm 1.0.1 tarball** (extracted with Python `tarfile`). No supply-chain tampering. This also confirms the Slither `divide-before-multiply` hit lives in unmodified official code.
- On-chain corroboration (live public Base RPC): native balance 0; EIP-1967 impl slot all-zero (non-proxy, independent of the explorer flag); `poolManager()` and `AEON_FEE_RECIPIENT()` live reads match the constructor arg / source constants exactly.
- Address-flag cross-check: suffix `0x4044` → mask `0x3FFF` = `0x0044` = `AFTER_SWAP` (0x40) + `AFTER_SWAP_RETURNS_DELTA` (0x04), matching the single non-virtual `afterSwap` return-delta callback. Deployment-correctness signal, not a finding.

## 4. Threat model and invariants
Actors and trust boundaries: **swapper (anyone)** may swap through a LegacyLedger pool and optionally pass a 32-byte `player` in `hookData`; **PoolManager** (immutable `0x4985…2b2b`) is the only permitted `afterSwap` caller and the counterparty of every `take()`; **AEON_FEE_RECIPIENT** (constant treasury) receives all fee+tax and is never a caller. Value crosses a boundary only inside `afterSwap`, when the hook `take()`s a slice of the swap's unspecified currency and returns a matching delta.

| ID | Invariant | Why it matters |
|----|-----------|----------------|
| INV1 | `afterSwap` only callable by the PoolManager | forged deltas / arbitrary fund movement |
| INV2 | returned int128 delta == sum of `take()`'d amounts (fee+tax) | mismatch strands value or bricks every swap |
| INV3 | fee (10bps) and tax (5bps) always on the SAME unspecified currency | wrong side desyncs pool accounting |
| INV4 | hook custodies no funds (every `take` → treasury) | no pot to strand, no rebate to misprice |
| INV5 | 10bps protocol fee non-skippable/lowerable/redirectable by a derived hook | protocol-revenue guarantee |
| INV6 | fee/tax never overflow int128 and always floor (payer-favoring) | overflow bricks; wrong rounding leaks value |
| INV7 | no reentrancy (sole external call = `take()` to trusted PoolManager; state before call) | double-count / delta desync |
| INV8 | `legacyScore`/`loyaltyTier` are economically inert | the attacker-nominable `player` field must not affect fund flow |

## 5. Findings
**No confirmed findings.**

### Candidates raised and refuted
- **[refuted] divide-before-multiply - `src/lib/v4-core/src/libraries/CustomRevert.sol:91`** (Slither, informational-class arithmetic). The hit is the `(returndatasize() + 31) / 32 * 32` memory-word-alignment idiom in `bubbleUpAndRevertWith`. It is (a) in **unmodified official v4-core** (SHA-256 identical to npm 1.0.1), (b) not a financial calculation - it rounds a byte length up to a 32-byte word for a `revert` copy, and (c) not attacker-reachable for any gain. Same FP refuted in every prior aeon-hook audit. Not promoted.
- **[not a finding] opt-in tax vs docstring** - the `LegacyLedger` docstring says "Every trade pays a 0.05% tax", but `_afterSwapExtra` returns 0 (no tax) when `hookData.length < 32` or the decoded `player` is `address(0)`. The tax is therefore opt-in, not universally enforced. This is a documentation/business-logic quirk, not a security issue: skipping it only forgoes *extra* protocol revenue (the mandatory 10 bps `AeonFee` is unconditional and non-virtual), and `legacyScore`/`loyaltyTier` carry no monetary value (capped bragging-rights tiers), so a caller nominating an arbitrary `player` gains nothing and harms no one (INV8). Consistent with the 2026-08-21/08-24 audits of this exact target.
- **[not a finding] int128.min negation** - `if (unspecifiedAmount < 0) unspecifiedAmount = -unspecifiedAmount;` would revert on `type(int128).min` (checked arithmetic). Reaching that requires an unspecified delta of ~1.7e38 tokens, unreachable for any real pool/token supply; at most a theoretical self-DoS on an impossible input, not an attacker path. The explicit `TaxOverflow`/`aeon fee overflow` guards likewise sit far beyond any realizable amount.

## 6. Coverage and limitations
- Explored: **access control** (`afterSwap` `onlyPoolManager`; no owner/admin/pause/upgrade surface; `_afterSwapExtra` is the only override point and adds no external entrypoint) · **return-delta integrity** (INV2/INV3: base fee and tax both select the unspecified currency via the identical `(amountSpecified < 0 == zeroForOne)` formula - verified across all four direction × exact-in/out cases; returned `feeDelta + extra` equals the two `take()` amounts) · **arithmetic/precision** (floor division, payer-favoring; overflow guards; int128.min domain) · **reentrancy** (sole external call is `take()` to the immutable trusted PoolManager; `legacyScore` written before it - CEI holds) · **upgradeability** (non-proxy confirmed on-chain; `poolManager` immutable; no delegatecall/selfdestruct) · **economic/MEV** (custody-free, no rebate/pot, fee non-redirectable) · **full v4-hook checklist** (flags↔callbacks match; no hookData/PoolKey validation gap since `player` is economically inert; no JIT/tick/oracle surface - this hook only reads the swap delta) · **provenance** (14/14 vendored files SHA-identical to upstream). Slither hit class: 1 divide-before-multiply, refuted as an unmodified-upstream word-alignment idiom.
- Not exercised: no fuzz campaign (hard gate - 0 findings survived triage; the S5 reasoning + the arithmetic argument stand as the repro). No mainnet fork simulation of a live swap.
- Honest partiality: a paid human audit would additionally fork-simulate real swaps against the live PoolManager across fee tiers / exotic (fee-on-transfer, rebasing) tokens to observe the delta accounting end-to-end, and review the off-chain aeon.fun deployment/CREATE2 salt-mining pipeline that produced the flag-encoding address. Neither changes the on-chain verdict for this immutable, custody-free contract.

## 7. Appendix

- Contract: [`0xDb4a0eb0410407d6C22A35c27288834e0D9F4044` on BaseScan](https://basescan.org/address/0xDb4a0eb0410407d6C22A35c27288834e0D9F4044) - verified source.
- Registry entry: [`hooks/legacyledger.json`](https://github.com/aeonfun/univ4-hooks/blob/main/hooks/legacyledger.json) - flags + every-chain addresses.
- Source: [`src/LegacyLedger.sol`](https://github.com/aeonfun/univ4-hooks/blob/main/src/LegacyLedger.sol) on the shared [`src/AeonFee.sol`](https://github.com/aeonfun/univ4-hooks/blob/main/src/AeonFee.sol) 10 bps base.
- Auditor: aeon `sc-audit` - autonomous agentic source review + Slither + fuzz-on-findings, operated by @aeonframework.
- Disclosure: clean audit, nothing to disclose. aeon.fun first-party hook; onchain findings are operator-gated by policy.

> Autonomous agent audit: threat-model-first source review, Slither, and a fuzz arm gated on findings. Thorough and case-exhaustive at the source level, but not a substitute for a paid human audit - see the Coverage and limitations section for what was and was not machine-proven.
