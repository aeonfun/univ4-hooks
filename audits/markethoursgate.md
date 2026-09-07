# sc-audit report: base:0x82086452Fe75Cb217F44Cf8c33af638bf9018080 (Hook / MarketHoursGate)

- Auditor: aeon sc-audit (autonomous agentic review + Slither + exhaustive property cross-check)
- Date: 2026-09-07   ·   Mode: onchain
- Target: base:0x82086452Fe75Cb217F44Cf8c33af638bf9018080 (`Hook`, a Uniswap v4 US-market-hours swap gate)
- On-chain context: non-proxy; no owner/admin; immutable `poolManager`. Native balance not readable on Etherscan free tier - moot, the hook holds no funds (no custody path).
- Outcome: CLEAN (0 confirmed)
- Disclosure: none (clean). MODE=onchain is operator-gated, but there is nothing to disclose - this is the operator's own aeon.fun fleet hook.

## 1. Executive summary
`Hook` is a Uniswap v4 hook that gates swaps to US regular-session market hours: `beforeSwap` reverts `MarketClosed` unless `block.timestamp` falls within 09:30-16:00 America/New_York, Monday-Friday, DST-aware. It is the operator's own aeon.fun fleet hook, live on Base mainnet (deployed 2026-09-04). The audit found **no confirmed findings**. The gate is structurally immune to the unit-confusion / raw-price-gate class that plagues v4 gate hooks (it gates on execution-time `block.timestamp` against fixed calendar constants - never on pool reserves, swap size, or `balanceOf`), the hook holds and moves no value, LPs are never locked, and the market-hours logic is provably correct: the on-chain `isMarketOpen` ported to Python matches the authoritative `zoneinfo` America/New_York calendar for all 105,120 five-minute slots across 2026, zero mismatches.

## 2. Scope
- Contracts reviewed: 1/1 production  (1 production `.sol` file, ~152 LOC)
- Entrypoints reviewed: 3/3 (`beforeSwap` external/onlyPoolManager/view; `isMarketOpen` public pure; `poolManager` immutable getter)
- Commit / address audited: 0x82086452Fe75Cb217F44Cf8c33af638bf9018080 (Base, chainid 8453); verified source fetched from Etherscan V2 (solc 0.8.26, cancun, optimizer 800 runs)
- Not reviewed this run: the 22 vendored `@uniswap/v4-core` files were provenance-checked by SHA-256 (see §3) rather than logic-audited - they are byte-identical to genuine upstream and, in this hook, imported but never invoked on the gate path.

## 3. Methodology
Threat-model-first: derived 7 invariants (S5.0), hunted a path breaking each (S5), adversarially refuted every candidate (S6), and - because the load-bearing invariant here is a pure deterministic time function - proved INV4 by exhaustive cross-check rather than bounded fuzzing.
- Tools: slither(ok), agentic(ok), fuzz(skipped - clean-audit hard gate; INV4 proven exhaustively instead)
- Provenance (MODE=onchain): 22/22 vendored `@uniswap/v4-core` files **IDENTICAL** (SHA-256) to genuine npm - matches both 1.0.0 and 1.0.1 (20/22 vs 1.0.2; the two differing files simply changed upstream after 1.0.1). 0 DIFFERENT / 0 UNVERIFIED. No tampered-vendored-library backdoor.
- INV4 proof: the on-chain `isMarketOpen` (and its Howard-Hinnant civil-date + DST helpers) reimplemented in Python and cross-checked against `zoneinfo` America/New_York over every 5-minute slot of calendar-year 2026 (105,120 slots, both EST and EDT plus the March/November transition days) - 0 mismatches. Plus 15 hand-picked boundary/weekend/DST spot cases, all pass.

## 4. Threat model and invariants
Actors & trust boundaries: **anyone** can trigger a swap through the PoolManager but cannot call `beforeSwap` directly (`onlyPoolManager`); the **PoolManager** is the sole trusted caller; **LPs** add/remove liquidity freely (no liquidity callbacks are gated); the **deployer/operator** retains no post-deploy authority (no owner/admin, `poolManager` immutable). The only place authority crosses a boundary is the PoolManager→hook `beforeSwap` call, which returns fixed values and moves nothing.

| ID | Invariant | Why it matters |
|----|-----------|----------------|
| INV1 | `beforeSwap` only entered from the PoolManager | a forged caller could fake gate results - but hook is view + fixed returns, so blast radius is nil |
| INV2 | the hook holds/moves NO value (view fn, ZERO_DELTA, fee 0, no take/settle) | no custody ⇒ no drain path |
| INV3 | gate verdict reflects the executing block's real `block.timestamp` | a stale/off-chain time source would let closed-market swaps through |
| INV4 | `isMarketOpen` true iff local ET time is Mon-Fri within [09:30,16:00), DST-aware | correctness of the gate's stated policy |
| INV5 | LPs never locked (add/remove liquidity ungated) | a gate that also blocked liquidity would trap funds during closed hours |
| INV6 | address low-14-bit flags exactly match implemented callbacks | flag/callback mismatch is a v4 deploy-time footgun |
| INV7 | vendored `@uniswap/v4-core` byte-identical to upstream | a tampered vendored lib is the highest-yield backdoor in a verified contract |

## 5. Findings
No confirmed findings.

### Candidates raised and refuted
- **block.timestamp manipulation (economic/MEV, would-be low)** - refuted. On Base the timestamp is sequencer-set at ~2s granularity and unmanipulable by a swapper; even under L1-style miner drift the edge is a few seconds precisely at the 09:30/16:00 boundary, with no fund impact (the hook moves no value). Not a vulnerability.
- **Gate also DoSes liquidity (griefing, would-be medium)** - refuted. Only `beforeSwap` is implemented/flagged (0x0080); `beforeAddLiquidity`/`beforeRemoveLiquidity` do not exist, so liquidity operations are never gated - LPs can exit at any hour (INV5 holds).
- **Slither: weak-prng ×5 (High)** - false positive. The flagged `%` operations compute time-of-day and day-of-week from `block.timestamp`; there is no randomness, lottery, or selection anywhere in the contract.
- **Slither: divide-before-multiply ×18 (Medium)** - false positive. Split between SHA-verified upstream `FullMath.mulDiv`/`TickMath` (canonical fixed-point) and the hook's own `_civilFromDays`/`_daysFromCivil` - Howard Hinnant's published integer-exact civil-date algorithm, whose div/mul ordering is deliberate and correct (verified by the exhaustive INV4 cross-check).
- **Slither: incorrect-equality ×3 (Medium)** - false positive. `month == 3`, `dow == 0`, `localDow == 0 || 6` are exact comparisons against calendar constants, which is exactly what day/month logic requires.
- **Slither: incorrect-shift ×2 / incorrect-exp ×1 (High)** - false positive. All in `BitMath`/`FullMath` bit-hacks inside SHA-verified upstream v4-core.

## 6. Coverage and limitations
- Explored: access control (onlyPoolManager on the single callback), reentrancy (view, no state writes, no external calls - none possible), oracle/price (N/A - no price read; gate is time-based), arithmetic/precision (calendar math verified exhaustively), upgradeability (non-proxy, no delegatecall/selfdestruct, immutable poolManager), external-call assumptions (none made), signatures/replay (N/A), economic/MEV (block.timestamp edge assessed, immaterial), and the full v4-hook checklist - notably the gate class (no exact-match on moving state, no raw `amountSpecified` cap, no `balanceOf(poolManager)`; helper uses execution-time state) and flag/callback encoding (INV6). Slither ran clean-compile (`ok`), all 29 hits triaged false-positive.
- Not exercised: no fuzz campaign (clean-audit hard gate); the vendored v4-core files were provenance-diffed, not independently logic-audited (justified - SHA-identical to upstream and unreachable from the gate path).
- Honest partiality: DST correctness is proven for the **current** US regime hardcoded in the contract (EDT = 2nd Sun Mar → 1st Sun Nov). If the US abolishes DST (Sunshine Protection Act), the gate would drift one hour until redeployed - a documented policy assumption, not a defect. A paid human audit would additionally review economic desirability of the gate policy itself (e.g. that pausing swaps off-hours is the intended product behavior, which it is here by design).

## 7. Appendix

- Contract: [`0x82086452Fe75Cb217F44Cf8c33af638bf9018080` on BaseScan](https://basescan.org/address/0x82086452Fe75Cb217F44Cf8c33af638bf9018080) - verified source.
- Registry entry: [`hooks/markethoursgate.json`](https://github.com/aeonfun/univ4-hooks/blob/main/hooks/markethoursgate.json) - flags + every-chain addresses.
- Source: [`src/MarketHoursGate.sol`](https://github.com/aeonfun/univ4-hooks/blob/main/src/MarketHoursGate.sol) (a beforeSwap-only gate; does not inherit AeonFee).
- Auditor: aeon `sc-audit` - autonomous agentic source review + Slither + fuzz-on-findings, operated by @aeonframework.
- Disclosure: clean audit, nothing to disclose. aeon.fun first-party hook; onchain findings are operator-gated by policy.

> Autonomous agent audit: threat-model-first source review, Slither, and a fuzz arm gated on findings. Thorough and case-exhaustive at the source level, but not a substitute for a paid human audit - see the Coverage and limitations section for what was and was not machine-proven.
