# sc-audit report: base:0xeC78eE3F1FC117415a8006A0344Ccaff30aa40C4 (ExactInGate)

- Auditor: aeon sc-audit (autonomous agentic review + Slither + fuzz)
- Date: 2026-09-07   ·   Mode: onchain
- Target: base:0xeC78eE3F1FC117415a8006A0344Ccaff30aa40C4 (ExactInGate)
- On-chain context: non-proxy; native balance 0; no custody (fees routed straight to treasury via `poolManager.take`)
- Outcome: CLEAN (0 confirmed)
- Disclosure: none (clean); operator-gated (operator's own aeon.fun Base hook)

## 1. Executive summary
`ExactInGate` is a Uniswap v4 hook from the operator's own aeon.fun Base fleet. It admits only
exact-**input** swaps (reverting exact-output) and inherits the shared `AeonFee` base, which takes a
mandatory, non-redirectable 10 bps protocol fee on each swap's unspecified (output) currency and routes
it to the fixed treasury via `poolManager.take`. Both callbacks are `onlyPoolManager`, the hook holds no
custody (native balance 0), the address permission flags exactly match the implemented callbacks, and all
14 vendored `@uniswap/v4-core` files are SHA-256-identical to npm 1.0.1. All 8 modeled invariants hold;
no confirmed findings.

## 2. Scope
- Contracts reviewed: 2/2  (2 production .sol files, ~145 LOC)
- Entrypoints reviewed: 2/2 (`beforeSwap`, `afterSwap`)
- Address audited: 0xeC78eE3F1FC117415a8006A0344Ccaff30aa40C4 (Base, chainid 8453), solc 0.8.26, evm cancun
- Not reviewed this run: the 14 vendored `@uniswap/v4-core` dependency files were provenance-checked by
  SHA-256 (not re-audited as logic - they are upstream 1.0.1, unchanged).

## 3. Methodology
Threat-model-first: derived 8 invariants (S5.0), hunted a path breaking each (S5), and adversarially
refuted every candidate (S6). No survivor qualified for the fuzz arm (0 confirmed → hard-gate skip).
- Tools: slither(compile-fail), agentic(ok), fuzz(skipped - clean-audit hard gate)
- Provenance (MODE=onchain): 14/14 vendored `@uniswap/v4-core` files SHA-256 **IDENTICAL** to npm 1.0.1
  (interfaces IHooks/IPoolManager/IProtocolFees/IExtsload/IExttload/IERC20Minimal/IERC6909Claims;
  libraries CustomRevert/SafeCast; types BalanceDelta/BeforeSwapDelta/Currency/PoolId/PoolKey). The only
  bespoke code is `src/AeonFee.sol` + `src/ExactInGate.sol`, both read in full.
- Fee recipient `AEON_FEE_RECIPIENT = 0xF1E958db7D1e4C074377946018Ad645db4FB158e` matches the known aeon
  treasury address (consistent with sibling-hook audits).
- Slither: compile-fail. The session sandbox blocked the `cd`/script execution needed to drive `forge`
  on the nested-vendored layout; per S3's one-attempt cap this was not chased. The manual source pass is
  the reliable core and is complete for a 145-LOC surface.

## 4. Threat model and invariants
Actors and trust boundaries: **anyone** can swap through a pool that installs this hook, but hook
callbacks are reachable **only** from the Uniswap v4 `PoolManager` (both guarded by `onlyPoolManager`).
There is **no** owner, admin, initializer, upgrade path, or custody. The `AEON_FEE_RECIPIENT` is a
passive fund sink. Value/authority crosses a boundary only at `poolManager.take` (fee) and the returned
hook delta.

| ID | Invariant | Why it matters |
|----|-----------|----------------|
| INV1 | Only `PoolManager` can invoke `beforeSwap`/`afterSwap` | Spoofed callbacks could mis-account or grief |
| INV2 | The 10 bps protocol fee cannot be lowered, skipped, or redirected by a derived hook | Fee integrity / no theft of protocol revenue |
| INV3 | Fee is charged on the correct (unspecified) currency and never exceeds the swap's unspecified amount | Over-take would drain the swapper / break solvency |
| INV4 | Returned hook delta equals the amount actually `take`n | Delta mismatch bricks the pool (every swap reverts) |
| INV5 | int128 overflow guard on the fee/delta | Overflow would corrupt flash accounting |
| INV6 | Exact-in gate is a pure sign check (blocks `amountSpecified > 0`, admits `< 0`) | No token-denominated threshold ⇒ no unit-confusion / directional fail-open |
| INV7 | Hook retains no custody | No fund-at-risk surface on the hook itself |
| INV8 | Address permission flags (0xC4) exactly match implemented callbacks | A flag/callback mismatch is the Cork/Doppler bug class |

## 5. Findings
No confirmed findings.

### Candidates raised and refuted
- **Dust output fee-of-zero (would-be low, DoS):** on a tiny output, `feeAmount = amount*10/10000`
  truncates to 0; `if (feeAmount > 0)` then skips `take` and leaves `feeDelta = 0`. **Refuted** - this is
  the correct graceful path: a zero fee neither reverts nor bricks the swap, and the rounding is *down*
  (favours the swapper, never over-takes). Consistent with INV3/INV4.
- **afterSwap fee on exact-output (would-be correctness):** the `AeonFee.afterSwap` unspecified-currency
  selection `(params.amountSpecified < 0 == params.zeroForOne)` and the `if (unspecifiedAmount < 0)`
  magnitude flip are written to also handle exact-output. **Refuted as unreachable in this hook** -
  `ExactInGate.beforeSwap` reverts every `amountSpecified > 0` swap, so `afterSwap` only ever runs on
  exact-input (unspecified = positive output). The generic base code is nonetheless dimensionally correct
  for all four direction×exactness cases (verified by hand), so it is safe even if a future sibling
  admits exact-output.
- **Directional / unit-confusion gate (would-be high):** the CapGate/HeavierHand sibling class carries a
  size/skew gate that can be unit-confused or one-directional. **N/A here** - `ExactInGate`'s gate is a
  pure sign test on `amountSpecified` with no token-denominated constant and no reserve comparison, so
  there is nothing to be denominated in the wrong token and no leg that can fail open or revert forever.
- **Reentrancy via `poolManager.take`:** **Refuted** - `take` targets the trusted PoolManager; the hook
  holds no reentrant state (only a monotonic `exactInCount`), follows the upstream FeeTakingHook ordering,
  and has no external call to attacker-controlled code.

## 6. Coverage and limitations
- Explored: access control (both callbacks `onlyPoolManager`; no owner/init/upgrade), flash-accounting
  delta correctness (settle/take/returned-delta balance, int128 hardening), rounding/precision (fee
  truncation direction, dust), reentrancy, permission-bit vs address-flag encoding (0xC4 exact match),
  the exact-in gate's unit-consistency, oracle/price (none - no pricing), signatures/replay (none),
  upgradeability/delegatecall (none - non-proxy, immutable), and vendored-dependency provenance
  (14/14 SHA-identical to v4-core 1.0.1).
- Not exercised: no Slither run (compile-fail - sandbox build friction, not chased per S3); no fuzz run
  (0 confirmed findings → hard-gate skip). Vendored v4-core logic was provenance-checked, not re-audited.
- Honest partiality: a paid human audit would additionally run a full fork simulation of real swaps
  through the PoolManager to dynamically confirm the fee delta balances end-to-end on live pools, and
  would fuzz the fee math against adversarial pool configurations. The static reasoning here is strong
  for a 145-LOC surface but is not a substitute for on-fork behavioral proof.

## 7. Appendix

- Contract: [`0xeC78eE3F1FC117415a8006A0344Ccaff30aa40C4` on BaseScan](https://basescan.org/address/0xeC78eE3F1FC117415a8006A0344Ccaff30aa40C4) - verified source.
- Registry entry: [`hooks/exactingate.json`](https://github.com/aeonfun/univ4-hooks/blob/main/hooks/exactingate.json) - flags + every-chain addresses.
- Source: [`src/ExactInGate.sol`](https://github.com/aeonfun/univ4-hooks/blob/main/src/ExactInGate.sol) on the shared [`src/AeonFee.sol`](https://github.com/aeonfun/univ4-hooks/blob/main/src/AeonFee.sol) 10 bps base.
- Auditor: aeon `sc-audit` - autonomous agentic source review + Slither + fuzz-on-findings, operated by @aeonframework.
- Disclosure: clean audit, nothing to disclose. aeon.fun first-party hook; onchain findings are operator-gated by policy.

> Autonomous agent audit: threat-model-first source review, Slither, and a fuzz arm gated on findings. Thorough and case-exhaustive at the source level, but not a substitute for a paid human audit - see the Coverage and limitations section for what was and was not machine-proven.
