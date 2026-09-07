# sc-audit report: base:0xa12bf4fc954b37cbe7acc2fa652328071f8b00c4 (CapGate)

- Auditor: aeon sc-audit (autonomous agentic review + Slither + fuzz)
- Date: 2026-09-06 (re-confirmed 2026-09-07 via dedup; bytecode immutable, source unchanged)   ·   Mode: onchain
- Target: 0xa12bF4fC954B37cbe7Acc2fA652328071F8b00c4 (CapGate - Uniswap v4 hook)
- On-chain context: non-proxy; compiler v0.8.26+commit.8a97fa7a, cancun; flags 0x00C4 (BEFORE_SWAP + AFTER_SWAP + AFTER_SWAP_RETURNS_DELTA) - exact match to the implemented callbacks; beforeSwap returns ZERO_DELTA so no BEFORE_SWAP_RETURNS_DELTA bit is set, afterSwap returns the fee delta so AFTER_SWAP_RETURNS_DELTA is set; fee recipient 0xF1E958db7D1e4C074377946018Ad645db4FB158e (matches operator treasury of record); no custody in the hook.
- Outcome: CLEAN (0 confirmed)
- Disclosure: none (clean); MODE=onchain operator-gated regardless - operator's own aeon.fun Base hook.

## 1. Executive summary
CapGate is a Uniswap v4 hook that rejects any swap larger than a per-side size cap - Uniswap v4 hook (per-side size cap: reject swaps > 5% of the specified currency's virtual reserve + mandatory 10bps AeonFee). It inherits the mandatory, non-redirectable 10 bps `AeonFee` on the swap's unspecified currency. This audit re-fetched the verified source, ran the full 11-class v4-hook checklist, SHA-256-diffed every vendored dependency, and read the live on-chain constants. Verdict: **clean, 0 confirmed**. The key point: the cap is dimensionally consistent - it compares the swap size to the virtual reserve of the *same* currency the amount is denominated in, so it is the corrected form of the "raw-token-cap" class that silently failed open on sub-18-decimal tokens.

## 2. Scope
- Contracts reviewed: 2/2 (2 production .sol files, ~204 LOC) - src/CapGate.sol, src/AeonFee.sol
- Entrypoints reviewed: 5/5 (beforeSwap(view,onlyPoolManager), afterSwap(onlyPoolManager) + view getters reserves, maxTradeSize, _reserves(internal))
- Address audited: 0xa12bF4fC954B37cbe7Acc2fA652328071F8b00c4 (Base, chainid 8453); deployed bytecode is immutable
- Not reviewed this run: the 20 vendored `@uniswap/v4-core` files are treated as dependencies - provenance-checked by SHA-256 (below) rather than re-audited (canonical upstream).

## 3. Methodology
Threat-model-first: derived 8 invariants (S5.0), hunted a path breaking each (S5), and adversarially refuted each candidate class (S6). No survivor qualified for the fuzz arm (0 confirmed -> hard gate).
- Tools: slither(ok - forge build succeeded (22 files, solc 0.8.26, remapping @uniswap/v4-core/=src/lib/v4-core/); 11 results, ALL false positives (10 in vendored v4-core FullMath/CustomRevert = canonical Bloemen mulDiv bit-hacks on files proven SHA-256-identical to upstream; 1 = CapGate._reserves intentionally destructuring only sqrtPriceX96 from getSlot0)), agentic(ok), fuzz(skipped (clean-audit hard gate - 0 survivors))
- Provenance (MODE=onchain): 20/20 IDENTICAL to npm @uniswap/v4-core 1.0.1 - every vendored file byte-matches upstream. Security-critical StateLibrary (price/liquidity reads the cap depends on) and FullMath (the cap arithmetic) both IDENTICAL.
- Fee-recipient check: AEON_FEE_RECIPIENT constant == operator treasury 0xF1E958...B158e - no redirected-fee backdoor

## 4. Threat model and invariants
Actors and trust boundaries: swappers (anyone) trade through pools adopting the hook, subject to the per-side size cap + 10 bps fee. The canonical Base PoolManager is the sole authorized caller of both callbacks (`onlyPoolManager`). The fee recipient is a fixed treasury EOA. The hook holds no custody. All 8 modeled invariants hold; the verifications:

- CapGate is a per-side SIZE cap: beforeSwap (view) reverts TradeTooLarge when the swap's |amountSpecified| exceeds MAX_TRADE_BPS (500 = 5%) of the pool's virtual reserve of the SAME currency the amount is denominated in. This is the corrected sibling of the old raw-token-cap CapGate (MAX_TRADE=100e18) - the header comment documents that the raw cap 'silently did nothing on any pool whose specified token had <18 decimals'.
- INV3 (dimensional consistency) VERIFIED: specifiedIsZero = (params.zeroForOne == exactIn) where exactIn = amountSpecified<0. Checked all 4 (direction x exact-in/out) cases against the comment table - correct in every case. reserve is picked as b0 (currency0 units) or b1 (currency1 units) to MATCH the specified currency, so `size > cap` compares like units. The cap therefore binds symmetrically in both directions and both exact-in/out, and does NOT fail open on sub-18-decimal tokens. This is exactly the unit-confusion class the hook-checklist flags - CapGate is on the correct side of it.
- INV4 (never fully bricked) VERIFIED: reserve==0 (uninitialized / no in-range liquidity) returns ZERO_DELTA (open); reserve>0 gives cap = reserve/20 > 0 for any realistic pool, so swaps up to 5% always pass. Degenerate edge: virtual reserve in 1..19 wei -> cap floors to 0 -> all non-zero swaps blocked, but that is a dust/dead pool reachable only by an LP draining their OWN liquidity to near-zero (no external griefing path, no funds at risk) - a hardening observation, not a finding.
- INV2/INV5/INV6 (AeonFee) VERIFIED: fee currency = unspecified side selected via ((amountSpecified<0)==zeroForOne)?currency1:currency0 (all 4 cases checked correct); fee = floor(|unspecified|*10/10000) taken via poolManager.take() to the fixed constant recipient. afterSwap is NON-virtual and CapGate does NOT override _afterSwapExtra (default returns 0), so the fee cannot be lowered/skipped/redirected. int128.min hardened (widen to int256 before negate; require feeAmount<=int128.max). Returned feeDelta == amount take()n, no settlement mismatch. This AeonFee base is functionally identical to the clean 2026-09-06 HeavierHand audit.
- INV1/INV7 (access / reentrancy) VERIFIED: both callbacks carry onlyPoolManager; the two getters (reserves, maxTradeSize) are permissionless view with no state change. The only external call is poolManager.take() to a fixed EOA treasury (no callback) inside the PM swap lock; beforeSwap is view. No state to corrupt (all params are constants/immutable) - no reentrancy or read-only-reentrancy vector.
- Hook-checklist (11 classes) all clear: access-control (onlyPoolManager present, no Cork-class gap); hookData ignored, PoolKey supplied by trusted PM; flash-accounting single matching take (no CELO double-settle); rounding favors the stricter cap / standard fee floor; permission-bit vs address-flag exact match 0x00C4; dynamic-fee override returns 0 (only relevant if a pool operator pairs it with a dynamic-fee pool - a pairing choice, not a hook flaw); JIT-liquidity could raise one's own cap but is self-defeating with no drain; tick/price manipulation only loosens a size cap (no drain); unit-confusion FIXED (the design point); DoS/economic covered by INV4/INV5.
- Non-findings (design-intent / not disclosable): (a) dust-pool cap=0 edge (no external path, no funds); (b) beforeSwap dynamic-fee override of 0 (deployment pairing choice, matches HeavierHand).

## 5. Findings
No confirmed findings. 0 candidates raised, 0 promoted. Each v4-hook checklist class was checked and refuted at the source (see the verifications above).

## 6. Coverage and limitations
- Explored: access control, reentrancy, oracle/price manipulation, arithmetic/precision, upgradeability (none), external-call assumptions, economic/MEV, and the full 11-class v4-hook checklist (permission-bit encoding, flash-accounting delta/settlement, gate unit-confusion, tick/price manipulation).
- Not exercised: no fuzz campaign (clean-audit hard gate - 0 survivors). Slither ran (ok) with all 11 results confirmed false positives.
- Honest partiality: a paid human audit would add a live forge/echidna harness proving the cap binds symmetrically and the fee-currency correctness with a negative control. The reasoning here is source-level and case-exhaustive but not machine-proven by a fuzz campaign this run.

## 7. Appendix

- Contract: [`0xa12bF4fC954B37cbe7Acc2fA652328071F8b00c4` on BaseScan](https://basescan.org/address/0xa12bF4fC954B37cbe7Acc2fA652328071F8b00c4) - verified source.
- Registry entry: [`hooks/capgate.json`](https://github.com/aeonfun/univ4-hooks/blob/main/hooks/capgate.json) - flags + every-chain addresses.
- Source: [`src/CapGate.sol`](https://github.com/aeonfun/univ4-hooks/blob/main/src/CapGate.sol) on the shared [`src/AeonFee.sol`](https://github.com/aeonfun/univ4-hooks/blob/main/src/AeonFee.sol) 10 bps base.
- Auditor: aeon `sc-audit` - autonomous agentic source review + Slither + fuzz-on-findings, operated by @aeonframework.
- Disclosure: clean audit, nothing to disclose. aeon.fun first-party hook; onchain findings are operator-gated by policy.

> Autonomous agent audit: threat-model-first source review, Slither, and a fuzz arm gated on findings. Thorough and case-exhaustive at the source level, but not a substitute for a paid human audit - see the Coverage and limitations section for what was and was not machine-proven.
