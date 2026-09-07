# sc-audit report: base:0x9818dDD1102c9606Cd693aC17A7B8B17609480c4 (TailTwins)

- Auditor: aeon sc-audit (autonomous agentic review + Slither + provenance)
- Date: 2026-09-07   ·   Mode: onchain
- Target: base:0x9818dDD1102c9606Cd693aC17A7B8B17609480c4 (TailTwins, on the AeonFee base)
- On-chain context: non-proxy; native balance 0 wei (no custody); poolManager = 0x498581fF718922c3f8E6A244956aF099B2652b2b (canonical Base v4 PoolManager, immutable)
- Outcome: CLEAN (0 confirmed)
- Disclosure: none (clean); MODE=onchain operator-gated regardless - operator's own aeon.fun hook

## 1. Executive summary

TailTwins is a Uniswap v4 hook deployed by the operator's aeon.fun fleet on Base. It implements a `beforeSwap` "last-byte match" gate - a swap is admitted only if the low byte of `|amountSpecified|` is within a circular tolerance of 16 of the pool's live `sqrtPriceX96` low byte - plus the mandatory, non-overridable 10 bps `AeonFee` taken on the unspecified currency in `afterSwap`. This is the third independent pass on this exact CREATE2 address (previously clean 2026-08-20 and 2026-08-24), re-run at explicit operator request; the deployed bytecode is immutable so the source is byte-identical, but all reasoning was re-derived and the on-chain context and vendored-source provenance were re-verified fresh. **The audit is clean: 0 confirmed findings.** The strongest reason: the gate is read-only and can only *revert*, the hook holds and moves no funds of its own, the fee is a compile-time constant on a non-virtual function, and all 19 vendored v4-core files are byte-identical to genuine npm.

## 2. Scope

- Contracts reviewed: 2/2 production (`src/TailTwins.sol`, `src/AeonFee.sol`, ~193 LOC)
- Entrypoints reviewed: 6/6 - `beforeSwap` (onlyPoolManager, view gate) and `afterSwap` (onlyPoolManager, inherited fee) are the two callbacks; `currentSqrtPriceX96`, `requiredTail`, `isAcceptable`, `acceptableAmountAtOrAbove` are pure/view helper reads
- Address audited: 0x9818dDD1102c9606Cd693aC17A7B8B17609480c4 (Base, chainid 8453)
- Not reviewed this run: the 19 vendored `@uniswap/v4-core` library/interface files under `lib/v4-core/src/` - checked for provenance (SHA-256) only, not re-audited as bespoke logic (they are unmodified upstream)

## 3. Methodology

Threat-model-first: derived 8 invariants (S5.0), hunted a path breaking each (S5) against the full 11-class v4-hook checklist, adversarially refuted every candidate (S6). No survivor qualified for the fuzz arm (clean audit → hard gate skip, S6.5).

- Tools: slither(ok), agentic(ok), fuzz(skipped - clean audit)
- Provenance (MODE=onchain): 19/19 vendored `@uniswap/v4-core` files SHA-256 **IDENTICAL** to genuine npm (compared against 1.0.0 / 1.0.1 / 1.0.2, fresh tarballs this run); security-critical `FullMath.sol` and `StateLibrary.sol` both identical. 0 DIFFERENT, 0 UNVERIFIED. No supply-chain tampering.
- On-chain cross-checks (Base public RPC): native balance 0 wei; EIP-1967 impl slot all-zero (non-proxy); `poolManager()` resolves to the canonical Base v4 PoolManager; `AEON_FEE_RECIPIENT` constant == aeon treasury; address flags 0x00C4 exact-match the implemented callbacks.

## 4. Threat model and invariants

Actors and trust boundaries: **anyone** may swap through a pool that installed the hook and fully controls `amountSpecified` / `zeroForOne` / exact-in-vs-out / `hookData`. The **PoolManager** (0x4985…2b2b) is the sole permitted caller of both callbacks (`onlyPoolManager`) and holds the swap lock. The **fee recipient** (0xF1E9…158e) is a compile-time constant. The hook has no owner, admin, pause, or upgrade authority. The only value crossing a boundary is the 10 bps fee, moved by `poolManager.take()` straight to the treasury.

| ID | Invariant | Why it matters |
|----|-----------|----------------|
| INV1 | Every state-changing callback is `onlyPoolManager`; no owner/admin/pause/upgrade surface | Unauthenticated callback = Cork-class fee/logic hijack |
| INV2 | 10 bps fee cannot be lowered, skipped, or redirected | Constants + non-virtual `afterSwap`; redirect = revenue theft |
| INV3 | Fee charged on the correct UNSPECIFIED currency in all 4 direction×exact-in/out cases; exact-output never skips it | Wrong currency/skip = silent fee bypass |
| INV4 | Fee arithmetic never overflows int128/uint256 for realistic deltas | Overflow-revert on every swap bricks the pool |
| INV5 | `beforeSwap` gate is read-only and can ONLY revert; the hook never moves currency itself | A value-moving gate could be manipulated to steal; a pure revert gate cannot |
| INV6 | Pool is never permanently bricked: a passing amount is always constructible and the swapper controls it | Permanently-reverting leg = griefing / DoS |
| INV7 | No reentrancy: only external call is `take()` to a fixed EOA under the PM lock; no mutable hook state | Cross-contract / read-only reentrancy |
| INV8 | Non-upgradeable + provenance-clean: non-proxy, `poolManager` immutable, vendored v4-core byte-identical to npm | Tampered vendored file or upgrade path = invisible backdoor |

## 5. Findings

No confirmed findings.

### Candidates raised and refuted

- **Gate unit-confusion / one-directional brick (v4-checklist, would-be HIGH → refuted).** The checklist flags gates that compare a raw amount to a token-denominated constant, or a skew/reserve gate that is a raw-price-vs-1.0 comparison in disguise (permanently reverting one leg on any non-parity pool). TailTwins is neither: it compares `|amountSpecified| & 0xff` to `sqrtPriceX96 & 0xff` under a circular tolerance - a **dimensionless modular match**, not a magnitude cap and not a reserve/skew comparison. Brute-forced: for every one of the 256 possible price tails there are exactly 33 acceptable amount low-bytes, and the swapper fully controls the low byte of their own amount, so a passing swap is always constructible in **both** directions. No permanent one-directional lock (INV6). Because it is a magnitude-agnostic last-byte test it also has **no sub-18-decimal fail-open** - it can only over-restrict (revert), never silently admit something dangerous (INV5).
- **Manipulable gate → theft (would-be CRITICAL → refuted).** The gate lives entirely in a `view` `beforeSwap` that returns `ZERO_DELTA`; its only effect is a possible revert. TailTwins never calls `poolManager.take`/`settle` or moves any currency itself - all value movement is confined to the inherited, non-virtual `AeonFee.afterSwap`. There is no state a manipulated price could steer into a transfer (INV5).
- **Fee redirect / skip (would-be HIGH → refuted).** `AEON_FEE_RECIPIENT` and `AEON_FEE_BPS` are compile-time constants and `afterSwap` is **not** `virtual`, so a derived hook cannot lower, skip, or redirect the fee. TailTwins does not override `_afterSwapExtra`, so `extra == 0`. The abs-before-guard (`if (unspecifiedAmount < 0) unspecifiedAmount = -unspecifiedAmount;`) is present, so exact-output swaps do not silently skip the fee (INV2/INV3).
- **Wrong fee currency (would-be MEDIUM → refuted).** Independently rebuilt the `(feeCurrency, unspecifiedAmount)` truth table from v4 semantics: exactIn&&zeroForOne→currency1, exactIn&&!zeroForOne→currency0, exactOut&&zeroForOne→currency0, exactOut&&!zeroForOne→currency1 - all four select the correct *unspecified* side (INV3).
- **int128.min / int256.min negation revert (would-be LOW → refuted, non-issue).** `_size(type(int256).min)` and `-unspecifiedAmount` at `type(int128).min` would revert on 0.8.26 checked arithmetic, but both require a swap magnitude ~2^255 / 2^127 - many orders beyond any real ERC20 supply at 18 decimals. Reverts a single swap, unreachable, not exploitable (INV4).
- **`acceptableAmountAtOrAbove` minimality (UX/doc gap → not a candidate).** As noted in the 2026-08-24 pass, the helper targets an exact tail match rather than the true minimal in-tolerance value, so it can suggest a larger amount than strictly required. It is a pure `view` helper with no state effect; every value it returns is safe (0 violations over 1M pairs) and the real gate re-checks independently. Documentation nit, no invariant broken.
- **`unused-return` on `getSlot0` (Slither Medium → FP).** `currentSqrtPriceX96` intentionally destructures only `sqrtPriceX96` from `getSlot0`; the other three fields are unused by design.

## 6. Coverage and limitations

- Explored: access control (both callbacks `onlyPoolManager`; no owner surface), reentrancy (view gate + single trusted `take` under PM lock), oracle/price manipulation (gate reads slot0 but is revert-only, moves no value), arithmetic/precision (fee rounds down, overflow-guarded), upgradeability (non-proxy, immutable poolManager, no delegatecall/selfdestruct), external-call assumptions (`take` to a fixed EOA), economic/MEV (fee fixed and mandatory; gate is a per-swap self-DoS game, no cross-user grief), and the full v4-hook checklist (flag encoding 0x00C4 exact-match, hookData ignored, flash-accounting delta = fee take only, gate unit-confusion class ruled out). Slither hit classes: 10 canonical FullMath/CustomRevert bit-hacks on SHA-verified upstream + 1 intentional partial destructure - all false positives.
- Not exercised: no fuzz campaign (clean audit, hard gate - 0 survivors to prove). The gate/escape/fee logic was instead verified by exhaustive brute force (65,536 distance pairs + 1,024,000 escape-helper pairs + the 4-case fee truth table).
- Honest partiality: a paid human audit would additionally model live pool composition / MEV interactions of the price-tail game under real order flow, and formally verify the v4 flash-accounting delta reconciliation against the PoolManager. Those are behavioral/economic concerns beyond a static source + provenance pass; none change the custody-free, revert-only risk profile.

## 7. Appendix

- Contract: [`0x9818dDD1102c9606Cd693aC17A7B8B17609480c4` on BaseScan](https://basescan.org/address/0x9818dDD1102c9606Cd693aC17A7B8B17609480c4) - verified source.
- Registry entry: [`hooks/tailtwins.json`](https://github.com/aeonfun/univ4-hooks/blob/main/hooks/tailtwins.json) - flags + every-chain addresses.
- Source: [`src/TailTwins.sol`](https://github.com/aeonfun/univ4-hooks/blob/main/src/TailTwins.sol) on the shared [`src/AeonFee.sol`](https://github.com/aeonfun/univ4-hooks/blob/main/src/AeonFee.sol) 10 bps base.
- Auditor: aeon `sc-audit` - autonomous agentic source review + Slither + fuzz-on-findings, operated by @aeonframework.
- Disclosure: clean audit, nothing to disclose. aeon.fun first-party hook; onchain findings are operator-gated by policy.

> Autonomous agent audit: threat-model-first source review, Slither, and a fuzz arm gated on findings. Thorough and case-exhaustive at the source level, but not a substitute for a paid human audit - see the Coverage and limitations section for what was and was not machine-proven.
