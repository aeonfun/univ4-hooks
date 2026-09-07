# sc-audit report: base:0x752B180116f5110dCBEa9564a43ACBEF82ebc080 (Hook / DailyWindowGate)

- Auditor: aeon sc-audit (autonomous agentic review + Slither + fuzz)
- Date: 2026-09-07   ·   Mode: onchain
- Target: base:0x752B180116f5110dCBEa9564a43ACBEF82ebc080 (contract name `Hook`, "DailyWindowGate")
- On-chain context: non-proxy; single immutable `poolManager` = `0x498581ff718922c3f8e6a244956af099b2652b2b` (canonical Base Uniswap v4 PoolManager); native balance **0 ETH**; **no token custody** (funds at risk: 0)
- Outcome: **CLEAN (0 confirmed)**
- Disclosure: none (clean). MODE=onchain is operator-gated but there is nothing to stage.

## 1. Executive summary
`Hook` is a freeform single-callback Uniswap v4 hook that enforces a **daily 10-minute UTC trading window**: a swap clears only while `block.timestamp % 86400 ∈ [00:00:00, 00:10:00)`, and reverts every other second of the day. It is one of the operator's own aeon.fun Base hooks, deployed 2026-09-04 by `deploy-uni-hook` (distinct from the AeonFee fleet - this one is a pure time gate with flag set `0x0080`, BEFORE_SWAP only). The hook holds no funds, takes no custody, has no owner/admin/upgrade path, and never gates liquidity provision. Verified source matches deployed bytecode (Etherscan V2); all 22 vendored `@uniswap/v4-core` files are byte-identical to the genuine npm 1.0.1 release. Every modeled invariant holds; the single production-code Slither hit (`weak-prng` on the intentional time-clock) is a false positive. **Verdict: clean.**

## 2. Scope
- Contracts reviewed: **1/1** (production `src/Hook.sol`, ~65 LOC of body) + 22 vendored `@uniswap/v4-core` dependency files (provenance-verified, not re-audited as they are unmodified upstream)
- Entrypoints reviewed: **6/6** - `beforeSwap` (the only state-touching, attacker-reachable entrypoint), `isTradingOpen(uint256)` (pure), and the four auto-generated public getters (`poolManager`, `DAY`, `WINDOW_OPEN`, `WINDOW_CLOSE`)
- Address audited: `0x752B180116f5110dCBEa9564a43ACBEF82ebc080` (Base, chainid 8453)
- Not reviewed this run: none omitted from the production surface. Vendored v4-core libraries were provenance-diffed rather than line-audited (unmodified upstream, and none but `PoolIdLibrary.toId` and the `ZERO_DELTA` constant actually execute in this hook's paths).

## 3. Methodology
Threat-model-first: derived 7 invariants (S5.0), hunted a path breaking each (S5) against the full 11-class v4-hook checklist, adversarially refuted candidates (S6). No survivor qualified for the fuzz arm (S6.5 hard gate: 0 confirmed → no fuzz).
- Tools: slither(**ok**), agentic(**ok**), fuzz(**skipped** - clean-audit hard gate)
- Provenance (MODE=onchain): **22/22 vendored `@uniswap/v4-core` files SHA-256 IDENTICAL to npm 1.0.1** (0 DIFFERENT, 0 UNVERIFIED). Diffing against 1.0.2 shows exactly 2 files differ (`IHooks.sol`, `IPoolManager.sol`), which simply confirms the pin at 1.0.1. Deployed source == bytecode via Etherscan V2 verification.
- Build: `forge build` succeeded (solc 0.8.26, cancun, v4-core remapping) → Slither reached a genuine `SLITHER=ok` (not compile-fail).

## 4. Threat model and invariants
Actors and trust boundaries: anyone can swap through a pool that installs this hook (indirectly reaching `beforeSwap`); the canonical Base v4 PoolManager is the **sole** direct caller of `beforeSwap` (enforced by `onlyPoolManager` + immutable PM address); LPs may add/remove liquidity at any time (no liquidity callbacks are implemented, so those paths never reach the hook). No owner, admin, keeper, or upgrade authority exists. No value ever crosses into the hook (zero delta, zero fee, no take/settle).

| ID | Invariant | Why it matters |
|----|-----------|----------------|
| INV1 | `beforeSwap` callable only by the canonical PoolManager (immutable `poolManager`) | spoofed caller could bypass intent / emit fake events |
| INV2 | `beforeSwap` returns `IHooks.beforeSwap.selector` | wrong selector bricks every swap on the pool |
| INV3 | `beforeSwap` returns ZERO `BeforeSwapDelta` and 0 fee override; hook never `take()`/`settle()`s | any nonzero delta or custody path = fund manipulation |
| INV4 | liquidity add/remove is never gated (only flag `0x0080` set) | LP lock-in = fund-lock griefing |
| INV5 | a swap clears iff `(block.timestamp % 86400) ∈ [0,600)`, evaluated at execution | the gate's whole purpose; must be direction/token-agnostic and drift-free |
| INV6 | address low-14-bits (`0xc080 & 0x3FFF = 0x0080`) equals the implemented callback set (beforeSwap only) | flag/callback mismatch = uncalled callback or spurious revert |
| INV7 | a closed-window swap reverts only that tx; pool state, next-window swaps, and liquidity are unaffected | no permanent brick |

## 5. Findings
No confirmed findings.

### Candidates raised and refuted
- **[would-be LOW] `weak-prng` on `block.timestamp % DAY` (`src/Hook.sol:93`, Slither).** Refuted: `block.timestamp` is used here as a **UTC wall-clock**, not as a randomness/entropy source - the result feeds a time-window comparison, not a lottery/selection. Sequencer/validator timestamp influence on an OP-stack L2 is bounded to a few seconds and can at most shift a swap by seconds across the window boundary; it cannot drain funds (none held), seize authority (none exists), or brick the pool (LPs ungated; a revert affects only the current tx). This is the correct, idiomatic pattern for a time gate and is documented in the source. Not a vulnerability.
- **[would-be design-note] Swaps revert ~99.3% of the day.** Refuted as by-design: a daily 10-minute window is the hook's entire specified function, not a DoS. Liquidity is ungated by construction (no liquidity callbacks), so no LP can ever be locked; closed-window reverts are transient and self-healing at the next window.
- **Vendored-library Slither hits (15).** All in `@uniswap/v4-core` bit-hack libraries - `BitMath` incorrect-shift (×2), `FullMath` incorrect-exp (×1, the canonical `(3*denominator)^2` XOR-as-intended pattern), and `FullMath`/`TickMath`/`CustomRevert` divide-before-multiply (×12). Refuted by provenance: every one of these files is SHA-256 identical to the genuine npm 1.0.1 release; these are long-standing, well-understood false positives on canonical Uniswap math. None execute in this hook's paths anyway (only `PoolIdLibrary.toId` for the event and the `ZERO_DELTA` constant are reached).

## 6. Coverage and limitations
- Explored: access control (`onlyPoolManager` + immutable canonical PM - INV1); selector integrity (INV2); flash-accounting / custody (returns `ZERO_DELTA` + 0 fee, no settle/sync/take/clear, no BEFORE_SWAP_RETURNS_DELTA flag - INV3); LP liveness (only `0x0080` flag, no liquidity callbacks - INV4); gate correctness and **unit-confusion** (this is a pure *time* gate - no `amountSpecified` cap, no reserve/skew comparison, no `balanceOf(poolManager)` - so it is inherently direction- and token-agnostic and immune to the amount/reserve unit-confusion class that has bitten other gates - INV5); permission-bit vs address-flag encoding (`0xc080 & 0x3FFF == 0x0080` matches the single implemented callback - INV6); reentrancy (no external calls in `beforeSwap`, only an event emit); dynamic fees (returns 0 without OVERRIDE flag - no override); no permanent brick (INV7). Full v4-hook checklist applied; provenance diff performed first.
- Slither hit classes: 16 total, **all false positives** - 15 vendored-library math bit-hacks (SHA-verified upstream) + 1 `weak-prng` on the intentional time-clock.
- Not exercised: fuzz arm skipped per the S6.5 hard gate (0 confirmed findings - nothing to prove). The `account/balance` Etherscan module is free-tier-gated for Base; native balance was confirmed **0 ETH** via a public Base RPC (`eth_getBalance`), consistent with a no-custody gate hook.
- Honest partiality: this is a genuinely minimal, self-contained contract (one gated callback, no state mutation beyond an event, no funds), so automated agentic + static review covers it essentially completely. A paid human audit would add little beyond confirming the same reasoning; the main residual assumption a human would restate is the operational one that the pool this hook is attached to is intended to be swap-restricted to a 10-minute daily window (a product decision, not a flaw).

## 7. Appendix

- Contract: [`0x752B180116f5110dCBEa9564a43ACBEF82ebc080` on BaseScan](https://basescan.org/address/0x752B180116f5110dCBEa9564a43ACBEF82ebc080) - verified source.
- Registry entry: [`hooks/dailywindowgate.json`](https://github.com/aeonfun/univ4-hooks/blob/main/hooks/dailywindowgate.json) - flags + every-chain addresses.
- Source: [`src/DailyWindowGate.sol`](https://github.com/aeonfun/univ4-hooks/blob/main/src/DailyWindowGate.sol) (a beforeSwap-only gate; does not inherit AeonFee).
- Auditor: aeon `sc-audit` - autonomous agentic source review + Slither + fuzz-on-findings, operated by @aeonframework.
- Disclosure: clean audit, nothing to disclose. aeon.fun first-party hook; onchain findings are operator-gated by policy.

> Autonomous agent audit: threat-model-first source review, Slither, and a fuzz arm gated on findings. Thorough and case-exhaustive at the source level, but not a substitute for a paid human audit - see the Coverage and limitations section for what was and was not machine-proven.
