# sc-audit report: base:0xa7a62422d13c7648ca53ad91e9268ac4bfc6c0c4 (TotalizerTrap)

- Auditor: aeon sc-audit (autonomous agentic review + Slither + provenance)
- Date: 2026-09-07   ·   Mode: onchain
- Target: base:0xA7a62422d13C7648cA53ad91E9268ac4bFC6C0c4 (TotalizerTrap)
- On-chain context: non-proxy (EIP-1967 impl slot empty); native balance 0; 2,348 bytes deployed; solc 0.8.26 / cancun; hook flags 0x00C4 (BEFORE_SWAP + AFTER_SWAP + AFTER_SWAP_RETURNS_DELTA); fee recipient 0xF1E958…B158e (aeon treasury); no owner/admin, no upgrade path.
- Outcome: CLEAN (0 confirmed)
- Disclosure: none (clean); operator-gated (operator's own aeon.fun Base fleet hook).

## 1. Executive summary
TotalizerTrap is a Uniswap v4 hook in the aeon.fun Base fleet: a novelty "trap" gate layered on the mandatory-fee `AeonFee` base. Its `beforeSwap` keeps a per-pool cumulative-size odometer and reverts any swap that would land that odometer on a multiple of 11; otherwise it advances the odometer and lets the swap through untouched. The fee half is the previously-audited, non-virtual, int128.min-hardened `AeonFee` (fixed 10 bps on the unspecified currency, routed straight to a compile-time-constant treasury). This run modeled 8 invariants and hunted a path breaking each; none broke. The single most important takeaway: the trap can never *permanently* brick a pool - at any odometer value at most 1 swap size in 11 is forbidden, and any swapper clears it by adjusting size by one unit (the contract even exposes `acceptableAmountAtOrAbove`/`trippingAmount` for exactly that). No custody, no privileged functions, vendored v4-core 14/14 SHA-identical to upstream 1.0.1.

## 2. Scope
- Contracts reviewed: 2/2 (TotalizerTrap.sol ~71 LOC, AeonFee.sol ~102 LOC; ~173 LOC production)
- Entrypoints reviewed: 2/2 state-changing external (`beforeSwap`, `afterSwap`); 4 view helpers (`cumulativeTotal`, `wouldTrip`, `trippingAmount`, `acceptableAmountAtOrAbove`) also read.
- Address audited: 0xA7a62422d13C7648cA53ad91E9268ac4bFC6C0c4 (Base, chainid 8453)
- Not reviewed as bespoke logic this run: 14 vendored `@uniswap/v4-core` files (interfaces/types/libraries) - instead provenance-verified byte-for-byte against upstream (see §3). No dependency `lib/` deep-logic review needed since they are unmodified upstream.

## 3. Methodology
Threat-model-first: derived 8 invariants (S5.0), hunted a path breaking each (S5), adversarially refuted every candidate (S6). Fuzz not run (S6.5 hard gate: 0 confirmed survivors).
- Tools: slither(ok), agentic(ok), fuzz(skipped - clean-audit hard gate)
- Provenance (MODE=onchain): **14/14 vendored `@uniswap/v4-core` files SHA-256 IDENTICAL to npm 1.0.1** (IHooks, IPoolManager, IProtocolFees, IExtsload, IExttload, IERC20Minimal, IERC6909Claims, CustomRevert, SafeCast, BalanceDelta, BeforeSwapDelta, Currency, PoolId, PoolKey). Zero DIFFERENT, zero UNVERIFIED - the highest-yield backdoor class (an altered line hidden inside a "just OpenZeppelin/Uniswap" file) is ruled out. The only bespoke code is TotalizerTrap.sol + AeonFee.sol.
- Fee recipient cross-check: `AEON_FEE_RECIPIENT` == 0xF1E958db7D1e4C074377946018Ad645db4FB158e, the same aeon treasury verified on every prior fleet audit.
- Prior coverage: this exact address was audited clean 2026-08-20 and 2026-08-24; today is an operator-directed re-audit via explicit `var` override.

## 4. Threat model and invariants
Actors and trust boundaries: **anyone** may swap through the PoolManager and freely choose `amountSpecified`; the **PoolManager** (immutable, set once in the constructor) is the sole authorized caller of both hook callbacks; the **fee recipient** is a fixed compile-time constant. There is **no owner/admin and no upgrade path** - the contract exposes zero privileged functions. The one place authority/value crosses a boundary is `AeonFee.afterSwap` → `poolManager.take(feeCurrency, RECIPIENT, feeAmount)`.

| ID | Invariant | Why it matters |
|----|-----------|----------------|
| INV1 | Only PoolManager can invoke beforeSwap/afterSwap | unauthenticated callback could move the ledger / corrupt the odometer |
| INV2 | The 10 bps fee cannot be lowered, skipped, or redirected | protocol-revenue integrity (afterSwap non-virtual; recipient+rate constants) |
| INV3 | The hook custodies no funds; every take() routes to the fixed recipient | no drainable balance |
| INV4 | Fee arithmetic never overflows / casts unsafely | a bad int128 delta reverts every swap and bricks the pool |
| INV5 | The trap can never *permanently* brick a pool (≤1-in-11 sizes forbidden; always clearable) | irreversible pool lock = fund freeze / griefing |
| INV6 | Odometer state cannot be driven into a permanently-locking value | state corruption → DoS |
| INV7 | No reentrancy path corrupts the odometer or double-takes the fee | accounting break |
| INV8 | beforeSwap returns ZERO_DELTA + 0 fee-override → never alters swap amounts / LP fee | flash-accounting delta integrity |

## 5. Findings
No confirmed findings.

### Candidates raised and refuted
- **[C1 · info · economic/MEV] Front-running the shared odometer to force a victim swap to revert.** The trap residue `totalOf[id] % 11` is shared mutable state, so an attacker can front-run a swap to shift it and make a victim's pending swap trip. *Refuted as a vulnerability:* this is the intended behavior of a "trap" gate, causes no fund loss, and the victim simply resubmits with a size adjusted by 1 (10 of 11 sizes always pass; `acceptableAmountAtOrAbove` computes the clearing size). The attacker pays gas + the 10 bps fee on every grief swap, and all v4 swaps are inherently front-runnable regardless. Not disclosable (INV5/INV6 hold - no permanent lock).
- **[C2 · info · arithmetic] `_size` negates `amountSpecified`; `type(int256).min` would overflow.** *Refuted:* a swap of magnitude ~2^255 is unreachable against any real pool/liquidity, and the checked-arithmetic negation reverts safely (no fund loss, no bad state) rather than misbehaving.
- **[C3 · info · design] Mixed-unit odometer.** `size` is `|amountSpecified|` in whichever currency the swap specified, so `totalOf` sums token0-denominated and token1-denominated magnitudes together. *Refuted:* a cosmetic quirk of a gimmick metric; no fund-safety invariant depends on the odometer being unit-consistent, and the gate (mod 11) is arbitrary by design.
- **[C4 · info · arithmetic] uint256 odometer overflow bricking a pool.** *Refuted:* reaching 2^256 cumulative size is impossible in any realistic timeframe; a hypothetical overflow reverts (checked math) rather than corrupting state.
- **[C5 · info · logic] Zero-size swap trips (0 % 11 == 0 at genesis).** *Refuted:* the PoolManager rejects zero-amount swaps upstream, so `size == 0` is not reachable through `beforeSwap`.
- **[C6 · medium(slither) · arithmetic] divide-before-multiply in CustomRevert.bubbleUpAndRevertWith.** *Refuted:* the flagged `mul(div(add(returndatasize(),31),32),32)` is the canonical round-up-to-word-boundary assembly idiom in vendored v4-core `CustomRevert.sol`, which is SHA-256 identical to upstream 1.0.1. False positive.

AeonFee fee-currency selection was re-derived across all four direction × exact-in/out cases and is dimensionally correct on every case (matches upstream FeeTakingHook): the fee is charged on the unspecified currency, magnitude taken before the guard so exact-output swaps are not silently skipped, `feeAmount ≤ int128.max` require guards the cast, and `afterSwap` is non-virtual so no derived hook can override it (INV2 holds).

## 6. Coverage and limitations
- Explored: access control (INV1 - both callbacks `onlyPoolManager`), reentrancy (INV7 - no state mutation after the external take; only-PoolManager gate + v4 lock), oracle/price (N/A - no price reads), arithmetic/precision (fee math + odometer, INV4/C2/C4), upgradeability/delegatecall (N/A - non-proxy, no delegatecall, immutable poolManager), external-call assumptions (single trusted `poolManager.take`), signatures/replay (N/A - no signatures), economic/MEV (C1 trap-griefing), and the full v4-hook checklist: permission-bit-vs-address-flag encoding (0x00C4 matches the implemented beforeSwap+afterSwap+returns-delta callbacks exactly), flash-accounting deltas (beforeSwap returns ZERO_DELTA; afterSwap returns feeDelta+extra with extra=0 for this hook and take() balancing the delta), gate unit-confusion (the gate is a pure modulus on an accumulator, NOT a token-denominated cap, so the sub-18-decimal fail-open and one-directional-price-gate classes do not apply), and DoS/economic (INV5/INV6).
- Slither: ok - 1 hit (divide-before-multiply in vendored CustomRevert.sol), a false positive on SHA-verified upstream.
- Not exercised: no fuzz campaign (hard gate - 0 confirmed survivors; the S5 reasoning is the audit and there was no invariant break to machine-prove). Vendored v4-core files were provenance-verified, not logic-re-audited (they are unmodified upstream and out of scope for bespoke review).
- Honest partiality: a paid human audit would additionally run a live fork simulation of real swaps against a deployed pool to confirm the fee `take()` settles cleanly under the PoolManager lock end-to-end, and would fuzz the odometer/fee interaction across many pools - this run relied on source reasoning plus the identical prior-fleet audits that already fork-simulated the AeonFee base.

## 7. Appendix

- Listed on aeon.fun: [aeon.fun/hooks?hook=totalizertrap](https://www.aeon.fun/hooks?hook=totalizertrap) - open this hook in the marketplace.
- Contract: [`0xA7a62422d13C7648cA53ad91E9268ac4bFC6C0c4` on BaseScan](https://basescan.org/address/0xA7a62422d13C7648cA53ad91E9268ac4bFC6C0c4) - verified source.
- Registry entry: [`hooks/totalizertrap.json`](https://github.com/aeonfun/univ4-hooks/blob/main/hooks/totalizertrap.json) - flags + every-chain addresses.
- Source: [`src/TotalizerTrap.sol`](https://github.com/aeonfun/univ4-hooks/blob/main/src/TotalizerTrap.sol) on the shared [`src/AeonFee.sol`](https://github.com/aeonfun/univ4-hooks/blob/main/src/AeonFee.sol) 10 bps base.
- Auditor: aeon `sc-audit` - autonomous agentic source review + Slither + fuzz-on-findings, operated by @aeonframework.
- Disclosure: clean audit, nothing to disclose. aeon.fun first-party hook; onchain findings are operator-gated by policy.

> Autonomous agent audit: threat-model-first source review, Slither, and a fuzz arm gated on findings. Thorough and case-exhaustive at the source level, but not a substitute for a paid human audit - see the Coverage and limitations section for what was and was not machine-proven.
