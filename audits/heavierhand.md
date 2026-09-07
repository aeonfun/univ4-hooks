# sc-audit report: base:0x69072454d019c4167007c070ee49cf06c8ac50c4 (HeavierHand)

- Auditor: aeon sc-audit (autonomous agentic review + Slither + fuzz)
- Date: 2026-09-07   ·   Mode: onchain
- Target: base:0x69072454d019C4167007C070Ee49CF06c8aC50C4 (HeavierHand - Uniswap v4 hook)
- On-chain context: non-proxy (EIP-1967 slot = 0x0); poolManager = 0x498581fF…652b2b (canonical Base v4 PM); native balance 0 wei (no custody in the hook)
- Outcome: CLEAN (0 confirmed)
- Disclosure: none (clean); MODE=onchain operator-gated regardless - operator's own aeon.fun Base hook.

## 1. Executive summary
HeavierHand is a Uniswap v4 hook that keeps a pool within a ±10% band of the sqrt price it was initialized at: inside the band a swap must pay in the side the pool has grown *heavier* on relative to that reference, and past the cap the gate inverts so only the rebalancing leg is admitted (the pool can never be shut). It inherits a mandatory, non-redirectable 10 bps protocol fee (`AeonFee`) taken on the swap's unspecified currency. This run - a second explicit operator re-audit today (also clean 2026-09-06) - re-fetched the verified source, re-ran the full v4-hook checklist, re-diffed all vendored dependencies, and re-read the live on-chain constants. Verdict: **clean, 0 confirmed**. The single most important takeaway is that the gate anchors to the pool's *own* opening price (the `AFTER_INITIALIZE`-captured reference), so it is symmetric for any pair/decimals/starting price - this is the corrected form of the "raw-price-vs-1.0" gate class that has historically bricked one swap direction on off-parity pools.

## 2. Scope
- Contracts reviewed: 2/2 (2 production .sol files, ~299 LOC)
- Entrypoints reviewed: 10/10 (3 state-changing callbacks + 7 view getters)
- Address audited: 0x69072454d019C4167007C070Ee49CF06c8aC50C4 (Base, chainid 8453); deployed bytecode is immutable
- Not reviewed this run: the 20 vendored `@uniswap/v4-core` files are treated as dependencies - provenance-checked by SHA-256 (below) rather than re-audited (they are canonical upstream).

## 3. Methodology
Threat-model-first: derived 8 invariants (S5.0), hunted a path breaking each (S5), and adversarially refuted each candidate class (S6). No survivor qualified for the fuzz arm (0 confirmed → hard gate).
- Tools: slither(compile-fail), agentic(ok), fuzz(skipped - clean-audit gate)
- Provenance (MODE=onchain): **20/20 vendored @uniswap/v4-core files SHA-256 IDENTICAL** to genuine npm tarballs (1.0.1 pin; IHooks/IPoolManager also match 1.0.0). StateLibrary.sol and FullMath.sol both identical. No supply-chain tampering. Live `AEON_FEE_RECIPIENT()` (eth_call) == treasury 0xF1E958…B158e; `poolManager()` == canonical Base v4 PM; `AEON_FEE_BPS()` == 10.
- Slither compile-fail cause: `forge build` and `solc` are permission-gated by the runner permission layer this session (not a network/sandbox block and not a code build error). The source pins exact `pragma solidity 0.8.26`. Per the S3 hard cap, one best-effort attempt was made and not chased - the source pass is the reliable core, and this matches the 09-06 HeavierHand result.

## 4. Threat model and invariants
Actors and trust boundaries: swappers (anyone) trade through pools that adopt the hook, subject to the directional gate + 10 bps fee. The canonical Base PoolManager (0x498581fF…652b2b) is the sole authorized caller of all three callbacks (`onlyPoolManager`). The fee recipient is a fixed treasury EOA (no callback surface). The pool creator sets the gate's reference sqrt price exactly once at initialize. The hook holds no custody (native balance 0).

| ID | Invariant | Why it matters |
|----|-----------|----------------|
| INV1 | afterInitialize/beforeSwap/afterSwap callable only by the PoolManager | Cork-class $12M bug = missing onlyPoolManager |
| INV2 | referenceSqrtPriceX96[id] is write-once (afterInitialize only) | a mutable reference re-anchors the gate / griefs the pool |
| INV3 | the gate never rejects BOTH directions at any reachable price | a two-way revert bricks the pool and locks LP funds |
| INV4 | the band/gate math never overflows or reverts spuriously | a gate-path overflow revert is a pool-shutting DoS |
| INV5 | 10 bps fee charged on the correct unspecified currency, never skipped | wrong currency / skip = fee evasion or accounting break |
| INV6 | fee cannot be lowered, skipped, or redirected by a derived hook | protocol-fee integrity |
| INV7 | no reentrancy through the hook callbacks | cross-contract / read-only reentrancy corrupts accounting |
| INV8 | declared permission flags (address low-14-bit) match implemented callbacks | flag/callback mismatch breaks PM ↔ hook contract |

## 5. Findings
No confirmed findings.

### Candidates raised and refuted
No candidate reached even provisional status this run; each vulnerability class was checked and refuted at the source:
- **Access control (would-be CRITICAL, Cork-class):** refuted - all three callbacks carry `onlyPoolManager`; no owner/admin/upgrade surface exists.
- **One-directional gate / unit-confusion (would-be HIGH, economic/DoS):** refuted - the gate compares current vs the pool's *own* `afterInitialize` reference sqrt price (not an implicit 1.0), so it is symmetric for any pair; INV3 case analysis shows at least one leg is always admitted.
- **Band-math overflow (would-be HIGH, arithmetic/DoS):** refuted - `_beyondCap` uses `FullMath.mulDiv` on sqrt prices and never squares; the squared-ratio math is confined to informational getters/revert payloads off the gate path.
- **Fee skip / redirect (would-be HIGH, economic):** refuted - magnitude taken before the guard (no exact-output skip), afterSwap non-virtual, constant recipient/bps, `_afterSwapExtra`==0, int128.min-hardened.
- **Reentrancy (would-be HIGH):** refuted - the only external call is `take()` to a codeless EOA inside the PM swap lock; beforeSwap is view.

## 6. Coverage and limitations
- Explored: access control, reentrancy (single/cross-fn/cross-contract/read-only), oracle/price manipulation, arithmetic/precision (rounding direction, int128.min, no-squaring band math), upgradeability/delegatecall (none present), external-call assumptions, signatures/replay (N/A - no signatures), economic/MEV, and the full v4-hook checklist (permission-bit vs callback encoding, flash-accounting delta sign/settlement, gate unit-confusion, tick-crossing/price manipulation). All clean.
- Not exercised: no fuzz campaign (clean-audit hard gate - 0 survivors); `slither=compile-fail` (forge/solc permission-gated this session, so no static-analyzer cross-check ran - the S5 source reasoning stands alone this run, as on 09-06).
- Honest partiality: a paid human audit would additionally add a live forge/echidna harness proving INV3 (never-shut) and INV5 (fee-currency correctness) with a negative control, and would fuzz tick-crossing behavior under adversarial multi-swap sequences. The reasoning here is source-level and case-exhaustive but not machine-proven this run.

## 7. Appendix

- Listed on aeon.fun: [aeon.fun/hooks?hook=heavierhand](https://www.aeon.fun/hooks?hook=heavierhand) - open this hook in the marketplace.
- Contract: [`0x69072454d019C4167007C070Ee49CF06c8aC50C4` on BaseScan](https://basescan.org/address/0x69072454d019C4167007C070Ee49CF06c8aC50C4) - verified source.
- Registry entry: [`hooks/heavierhand.json`](https://github.com/aeonfun/univ4-hooks/blob/main/hooks/heavierhand.json) - flags + every-chain addresses.
- Source: [`src/HeavierHand.sol`](https://github.com/aeonfun/univ4-hooks/blob/main/src/HeavierHand.sol) on the shared [`src/AeonFee.sol`](https://github.com/aeonfun/univ4-hooks/blob/main/src/AeonFee.sol) 10 bps base.
- Auditor: aeon `sc-audit` - autonomous agentic source review + Slither + fuzz-on-findings, operated by @aeonframework.
- Disclosure: clean audit, nothing to disclose. aeon.fun first-party hook; onchain findings are operator-gated by policy.

> Autonomous agent audit: threat-model-first source review, Slither, and a fuzz arm gated on findings. Thorough and case-exhaustive at the source level, but not a substitute for a paid human audit - see the Coverage and limitations section for what was and was not machine-proven.
