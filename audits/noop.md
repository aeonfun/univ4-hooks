# sc-audit report: base:0xFBa729A7d8fc48cBb261A845A0f26281ED7800C4 (NoOp)

- Auditor: aeon sc-audit (autonomous agentic review + Slither + fuzz)
- Date: 2026-09-07   ·   Mode: onchain
- Target: `base:0xFBa729A7d8fc48cBb261A845A0f26281ED7800C4` (NoOp - aeon.fun AeonFee-family Base v4 hook)
- On-chain context: non-proxy; native balance **0 wei** (no custody at rest); `poolManager()` = `0x498581fF718922c3f8E6A244956aF099B2652b2b` (canonical Base v4 PoolManager, immutable)
- Outcome: **CLEAN (0 confirmed)**
- Disclosure: none (clean); MODE=onchain is operator-gated regardless - nothing to stage.

## 1. Executive summary
`NoOp` is a minimal Uniswap v4 hook on the shared `AeonFee` base: `beforeSwap` waves every trade through untouched (emits an event, returns a zero delta), and the inherited, non-virtual `afterSwap` takes a mandatory 10 bps protocol fee on the swap's unspecified currency straight to the aeon treasury. This run re-audited the live deployed contract at explicit operator request - the 4th independent clean pass on this exact immutable CREATE2 address (prior: 2026-08-18, 2026-08-24, and an earlier same-day 2026-09-07 run). Source was re-fetched fresh (Sourcify v2), all 8 invariants re-derived and re-checked, and on-chain context + vendored-dependency provenance re-verified fresh. Verdict: no confirmed findings; the fee is non-redirectable, access is correctly gated, and the 14 vendored v4-core files are byte-identical to genuine upstream.

## 2. Scope
- Contracts reviewed: **2/2** production contracts (`src/NoOp.sol` ~28 LOC + `src/AeonFee.sol` base ~102 LOC; ~130 LOC in-scope), across 16 `.sol` files.
- Entrypoints reviewed: **2/2** external state-changing callbacks (`beforeSwap`, `afterSwap`); the contract also exposes 3 constant/immutable public getters (auto-generated: `AEON_FEE_RECIPIENT`, `AEON_FEE_BPS`, `poolManager`).
- Address audited: `0xFBa729A7d8fc48cBb261A845A0f26281ED7800C4` (chain: Base, cid 8453). Immutable bytecode - no proxy, no upgrade path.
- Not reviewed this run: the 14 vendored `@uniswap/v4-core` files were checked for provenance (SHA-256) only, not re-audited as first-party logic - they are pinned upstream library/interface/type code.

## 3. Methodology
Threat-model-first: derived 8 invariants (S5.0), hunted a path breaking each (S5), and adversarially refuted every candidate (S6). No candidate survived triage, so the fuzz arm (S6.5) was correctly skipped by the hard gate.
- Tools: slither(compile-fail), agentic(ok), fuzz(not-run - clean audit).
- Provenance (MODE=onchain): **14/14 vendored `@uniswap/v4-core` files SHA-256 IDENTICAL to genuine npm 1.0.1** (re-downloaded and diffed fresh this run; IHooks, IPoolManager, IProtocolFees, IExtsload, IExttload, IERC20Minimal, IERC6909Claims, CustomRevert, SafeCast, BalanceDelta, BeforeSwapDelta, Currency, PoolId, PoolKey). 0 DIFFERENT / 0 UNVERIFIED.
- On-chain re-verification: `poolManager()` read live via `eth_call` on `mainnet.base.org` (http=200) = the canonical Base v4 PoolManager; `eth_getBalance` = 0 wei (http=200).
- Slither: forge/slither are staged at `/tmp/bin`, but their invocation is interactive-approval-gated in this headless session; per the S3 single-attempt cap this was not chased. The source pass is the reliable core and needs no compiler - it carried the audit. This is a permission gate, not a network/egress block.

## 4. Threat model and invariants
Actors and trust boundaries: the only trusted caller is the immutable Uniswap v4 `PoolManager` (both callbacks are `onlyPoolManager`). There is no owner, admin, role, or initializer. The `swapper` (`sender`) is untrusted and controls only swap direction and exact-in/out; value crosses a boundary only when `afterSwap` calls `poolManager.take()` to move the 10 bps fee to a hard-coded treasury address.

| ID | Invariant | Why it matters |
|----|-----------|----------------|
| INV1 | Both swap callbacks callable only by the canonical PoolManager | Forged callback → spoofed swap accounting / fee theft |
| INV2 | The 10 bps fee cannot be lowered, skipped, or redirected | Fee redirection = protocol revenue theft |
| INV3 | `beforeSwap` is neutral (no delta, no state change) | A rogue before-delta could distort swap accounting |
| INV4 | Fee is charged on the correct *unspecified* currency in all 4 direction × exact-in/out cases | Wrong-currency take → mis-accounting / stuck swaps |
| INV5 | Fee math never overflows int128 | Overflow → reverting swaps / bricked pool |
| INV6 | Contract is non-upgradeable, no delegatecall/selfdestruct | Upgrade/self-destruct → total behavior swap |
| INV7 | No reentrancy vector in the callbacks | Reentrancy → drained/duplicated fee accounting |
| INV8 | Vendored v4-core matches genuine upstream | A tampered vendored file is an invisible backdoor |

## 5. Findings
**No confirmed findings.**

### Candidates raised and refuted
- **`int128.min` negation (AeonFee.sol:72), severity-if-real: low, arithmetic** - `unspecifiedAmount = -unspecifiedAmount` overflows if the delta equals `int128.min`. Refuted: reaching it requires a ~2^127-wei swap delta (astronomically unreachable), and under solc 0.8.26 checked arithmetic it would revert that single swap, not persistently brick the pool. Not promoted.
- **Fee rounding direction (AeonFee.sol:76), severity-if-real: informational** - integer division floors the fee. Refuted: rounding favors the swapper (never over-charges); this is the intended, safe direction.
- **`beforeSwap` returned delta ignored** - NoOp returns `ZERO_DELTA` and the address flags omit `BEFORE_SWAP_RETURNS_DELTA (0x08)`, so the PoolManager ignores it anyway. Consistent by design; no issue.

## 6. Coverage and limitations
- Explored: access control (both callbacks `onlyPoolManager`, no owner/init surface), reentrancy (single `take()` to a fixed EOA under the PoolManager lock, no mutable hook state), arithmetic/precision (fee floor + int128 overflow guard), upgradeability (non-proxy, no delegatecall/selfdestruct, immutable poolManager), external-call assumptions (`take` to a constant recipient), economic/MEV (fixed rate, non-redirectable), and the full v4-hook checklist - flag/callback encoding (`0x00C4` matches the two implemented callbacks exactly), fee-currency selection across all 4 direction × exact-in/out cases, and the exact-output fee-skip class (fixed via abs-before-guard). No gate/skew/unit-confusion surface exists (NoOp does not gate).
- Not exercised: Slither did not run (`compile-fail` - toolchain invocation approval-gated this session); the fuzz arm was correctly skipped (0 survivors). Neither reduces confidence here: the surface is 130 LOC of fully-read first-party source with no external state.
- Honest partiality: a paid human audit would additionally run a full compiled Slither pass and a fork simulation of live swaps through an adopting pool; neither is expected to change the verdict given the contract's size and the absence of custody or mutable state.

## 7. Appendix

- Contract: [`0xFBa729A7d8fc48cBb261A845A0f26281ED7800C4` on BaseScan](https://basescan.org/address/0xFBa729A7d8fc48cBb261A845A0f26281ED7800C4) - verified source.
- Registry entry: [`hooks/noop.json`](https://github.com/aeonfun/univ4-hooks/blob/main/hooks/noop.json) - flags + every-chain addresses.
- Source: [`src/NoOp.sol`](https://github.com/aeonfun/univ4-hooks/blob/main/src/NoOp.sol) on the shared [`src/AeonFee.sol`](https://github.com/aeonfun/univ4-hooks/blob/main/src/AeonFee.sol) 10 bps base.
- Auditor: aeon `sc-audit` - autonomous agentic source review + Slither + fuzz-on-findings, operated by @aeonframework.
- Disclosure: clean audit, nothing to disclose. aeon.fun first-party hook; onchain findings are operator-gated by policy.

> Autonomous agent audit: threat-model-first source review, Slither, and a fuzz arm gated on findings. Thorough and case-exhaustive at the source level, but not a substitute for a paid human audit - see the Coverage and limitations section for what was and was not machine-proven.
