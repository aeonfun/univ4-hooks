# sc-audit report: base:0xD24D29a47Adb8786072Ab2Cb9925dC8Ba36Bc044 (CrownClash)

- Auditor: aeon sc-audit (autonomous agentic review + Slither + provenance)
- Date: 2026-09-07   ·   Mode: onchain
- Target: base:0xD24D29a47Adb8786072Ab2Cb9925dC8Ba36Bc044 (CrownClash - aeon.fun Uniswap v4 hook)
- On-chain context: non-proxy; native balance **0 ETH** (custody-free); PoolManager `0x498581ff718922c3f8e6a244956af099b2652b2b` (canonical Base v4); solc 0.8.26 / cancun; tx_count 1 (deploy only)
- Outcome: **CLEAN (0 confirmed)**
- Disclosure: none (clean); operator-gated by default (own contract)

## 1. Executive summary
CrownClash is a custody-free Uniswap v4 `afterSwap` hook on Base: it takes the mandatory 10 bps AeonFee plus its own 0.07% "tribute" on every swap - both routed straight to the aeon treasury via `poolManager.take()` - and maintains an on-chain, bragging-rights volume leaderboard (the "crown"). This is an explicit operator re-audit of an address previously scanned clean on 2026-08-21 and 2026-08-24; fresh verified source was re-fetched this run (the fleet redeployed on/before 2026-09-06). Re-verified end-to-end against the live verified source, on-chain state, and dependency provenance: **no confirmed findings**. The single most important property - a return-delta hook must never revert or return a mismatched delta (which would brick the pool) - holds, and the hook holds no funds at any point (confirmed 0 native balance on-chain).

## 2. Scope
- Contracts reviewed: **2/2** (CrownClash.sol + AeonFee.sol; ~110 LOC of production logic across 16 .sol files)
- Entrypoints reviewed: **2/2** (`afterSwap` [onlyPoolManager], `volumeGapToDethrone` [view]; `_afterSwapExtra` is internal, driven by afterSwap)
- Address audited: `0xD24D29a47Adb8786072Ab2Cb9925dC8Ba36Bc044` (Base, cid 8453)
- Not reviewed this run: the 14 vendored `@uniswap/v4-core` library/interface files were checked for **provenance only** (SHA-256 vs genuine npm), not re-audited as original code - they are upstream dependencies.

## 3. Methodology
Threat-model-first: derived **8 invariants** (S5.0), hunted a path breaking each against the full v4-hook checklist (S5), adversarially refuted every candidate (S6). Fuzz arm skipped by the hard gate (0 survivors).
- Tools: slither(**ok**), agentic(**ok**), fuzz(not-run - clean-audit hard gate)
- Provenance (MODE=onchain): **14/14** vendored v4-core files byte-identical (SHA-256) to genuine npm `@uniswap/v4-core` **1.0.0 AND 1.0.1**. Two files (IHooks.sol, IPoolManager.sol) differ under the newer **1.0.2** only because upstream changed those interfaces in 1.0.2 - the contract vendored the 1.0.0/1.0.1 versions, both exact matches. **No supply-chain tampering**: every vendored file matches a genuine upstream release.
- On-chain verification: `poolManager()` eth_call → `0x498581ff…b2b` (canonical Base PoolManager, immutable); EIP-1967 slot all-zero (non-proxy, corroborates Etherscan Proxy=0); native balance 0; tx_count 1.
- Slither: build succeeded (`forge` staged this run) via a `@uniswap/v4-core/=src/lib/v4-core/` remapping - a genuine `SLITHER=ok`, better than the prior runs' `compile-fail` on this same layout.

## 4. Threat model and invariants
Actors & trust boundaries: **anyone** can swap the pool (indirectly triggering afterSwap) and optionally name a `player` in hookData; only the **immutable PoolManager** may call `afterSwap` (it passes the real PoolKey/params/delta); the **treasury** (`0xF1E958…B158e`, a compile-time constant) receives fee+tribute and holds no privileged call. Value/authority crosses a boundary at exactly one point: `poolManager.take()`, which moves the fee and tribute straight out to the treasury.

| ID | Invariant | Why it matters |
|----|-----------|----------------|
| INV1 | `afterSwap` only enterable by the PoolManager | a spoofed caller could forge a delta / abuse take() |
| INV2 | mandatory 10 bps fee cannot be lowered/skipped/redirected | protocol revenue integrity (non-virtual, constants) |
| INV3 | returned hookDelta == exactly what was take()n, on the unspecified currency, exact-in & exact-out | mismatched delta breaks flash-accounting → reverts every swap |
| INV4 | afterSwap never reverts for a realistic swap | a reverting return-delta hook bricks the whole pool |
| INV5 | hook custodies no funds (fee+tribute route straight to treasury) | no pot to strand, no rescue path to get wrong |
| INV6 | fee/tribute arithmetic can't overflow int128; int128.min negation hardened | overflow revert = pool DoS |
| INV7 | state writes precede the single external take() (CEI) | no reentrancy window on leaderboard/accounting |
| INV8 | champion/volume is bragging-rights only; no value distributed by it | hookData spoofing & wash-trading are benign, not theft |

## 5. Findings
**No confirmed findings.**

### Candidates raised and refuted
- **`afterSwap` caller spoofing (access-control, would-be critical)** - refuted: `onlyPoolManager` reverts `NotPoolManager` for any other caller; `poolManager` is immutable and verified on-chain to be the canonical Base PoolManager. (INV1)
- **Derived hook redirecting/lowering the 10 bps fee (access-control/economic, would-be high)** - refuted: `AeonFee.afterSwap` is non-virtual; recipient and rate are compile-time constants; `_afterSwapExtra` only runs *after* the fee is taken and can only add its own delta. (INV2)
- **Delta mismatch / double-settle across two currencies (flash-accounting, would-be critical/DoS)** - refuted: fee and tribute currencies are computed by the identical ternary → the same unspecified currency; both amounts are actually `take()`n and their positive sum is exactly the returned delta. (INV3)
- **Pool-bricking revert (DoS, would-be high)** - refuted: the only revert paths are the two overflow guards and the `int128.min` negation edge, all unreachable for any realistically-sized swap; rounding is down, never over-taking. (INV4/INV6)
- **Stranded funds / missing rescue (custody, would-be medium)** - refuted: hook holds nothing (0 native balance verified); every skim routes straight to the treasury; no withdraw/rescue path needed or present. (INV5)
- **Reentrancy on leaderboard/accounting (reentrancy, would-be high)** - refuted: all state writes precede the single `take()`; PoolManager is locked mid-swap. (INV7)
- **hookData `player` spoofing (would-be medium)** - refuted as benign: crediting an arbitrary address costs the caller gas+tribute and yields no monetary benefit; champion is bragging-rights state only. (INV8)
- **Wash-trading to take the crown (would-be low)** - refuted as intentional, disclosed game design; no funds distributed by champion status. (INV8)
- **Slither `divide-before-multiply` in `CustomRevert.sol`** - refuted: canonical `(returndatasize()+31)/32*32` word-alignment rounding in vendored, SHA-verified upstream v4-core; not in production code; false positive.

## 6. Coverage and limitations
- **Explored:** access control, reentrancy (incl. read-only / CEI), oracle/price (N/A - hook reads no price/oracle/reserves), arithmetic/precision (fee/tribute rounding, int128.min edge, overflow guards), upgradeability (N/A - non-proxy, no delegatecall, EIP-1967 slot empty), external-call assumptions (single `take()` into trusted PoolManager), signatures/replay (N/A - no signatures), economic/MEV (wash-trading, hookData spoofing), and the **full v4-hook checklist** (permission-bit encoding `0xc044`→`0x0044` matches the sole afterSwap callback; flash-accounting delta sign/currency; no gate → no unit-confusion class). Slither: 1 hit, a vendored false positive.
- **Not exercised:** fuzz arm skipped by the hard gate (0 survivors - nothing to prove). The 14 vendored v4-core files were provenance-checked, not re-audited as source.
- **Honest partiality:** a paid human audit would additionally run a live fork-simulation of exact-in/exact-out swaps in both directions to observe the settled deltas end-to-end, and independently model interactions with a hostile custom token (fee-on-transfer / rebasing) as one leg of the pool - although the take-on-output pattern and 0-custody design bound that exposure to the treasury's own skim, not user principal.

## 7. Appendix

- Contract: [`0xD24D29a47Adb8786072Ab2Cb9925dC8Ba36Bc044` on BaseScan](https://basescan.org/address/0xD24D29a47Adb8786072Ab2Cb9925dC8Ba36Bc044) - verified source.
- Registry entry: [`hooks/crownclash.json`](https://github.com/aeonfun/univ4-hooks/blob/main/hooks/crownclash.json) - flags + every-chain addresses.
- Source: [`src/CrownClash.sol`](https://github.com/aeonfun/univ4-hooks/blob/main/src/CrownClash.sol) on the shared [`src/AeonFee.sol`](https://github.com/aeonfun/univ4-hooks/blob/main/src/AeonFee.sol) 10 bps base.
- Auditor: aeon `sc-audit` - autonomous agentic source review + Slither + fuzz-on-findings, operated by @aeonframework.
- Disclosure: clean audit, nothing to disclose. aeon.fun first-party hook; onchain findings are operator-gated by policy.

> Autonomous agent audit: threat-model-first source review, Slither, and a fuzz arm gated on findings. Thorough and case-exhaustive at the source level, but not a substitute for a paid human audit - see the Coverage and limitations section for what was and was not machine-proven.
