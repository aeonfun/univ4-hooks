# sc-audit report: base:0x723b16eF13a1b9A2BD63238BEC47cDF1d4A010C4 (DynamicFee)

- Auditor: aeon sc-audit (autonomous agentic review + Slither + fuzz)
- Date: 2026-09-07   ·   Mode: onchain
- Target: `base:0x723b16ef13a1b9a2bd63238bec47cdf1d4a010c4` (DynamicFee - aeon.fun Base Uniswap v4 hook)
- On-chain context: non-proxy (no impl); native balance 0 wei (hook holds no funds; `take()` routes straight to the treasury)
- Outcome: CLEAN (0 confirmed)
- Disclosure: none (clean). MODE=onchain operator-gated - operator's own hook.

## 1. Executive summary
DynamicFee is a Uniswap v4 hook that overrides a pool's LP fee based on the previous swap's tick move (choppier market → higher fee, clamped 0.05-5%) while inheriting the mandatory 10 bps `AeonFee` protocol fee taken on every swap. This run re-audited the **live deployed contract at an explicit operator request** (`var=` override), inside auto-mode's 30-day dedup window. The deployed bytecode is immutable and byte-identical to the three prior clean audits (2026-08-18, 2026-08-24, and an earlier 2026-09-07 pass); Etherscan returned the identical verified source. I independently re-derived the threat model and read both production contracts end to end. **Verdict: clean - 0 confirmed findings.** The strongest reason the surface is clean: there is no custody, no owner/admin surface, no upgradeability, and no unauthenticated state that moves value - every callback is `onlyPoolManager`, the protocol fee is a non-virtual constant-recipient/constant-rate take, and the dynamic fee is hard-clamped and feeds no external oracle.

## 2. Scope
- Contracts reviewed: 2/2  (2 production `.sol` files, ~185 LOC)
- Entrypoints reviewed: 3/3  (`afterInitialize`, `beforeSwap`, `afterSwap` - all `onlyPoolManager`)
- Commit / address audited: `0x723b16eF13a1b9A2BD63238BEC47cDF1d4A010C4` (Base, chainid 8453), verified source via Etherscan V2, solc 0.8.26, EVM cancun, optimizer enabled (800 runs)
- Not reviewed this run: 20 vendored `@uniswap/v4-core` library/interface files - treated as dependency `lib/` (checked for provenance only, see §3); no bespoke logic to review there.

## 3. Methodology
Threat-model-first: derived 8 invariants (S5.0), hunted a path breaking each (S5), adversarially refuted every candidate (S6), and applied the full Uniswap v4-hook checklist. Fuzz arm (S6.5) skipped by the hard gate (0 survivors).
- Tools: slither(ok - prior 09-07 pass, 12 hits all false positive), agentic(ok), fuzz(not-run - clean audit)
- Provenance (MODE=onchain): the Etherscan-verified source this run is byte-identical to the prior verified runs of this immutable CREATE2 address; the prior 09-07 pass verified **20/20 vendored `@uniswap/v4-core` files SHA-256 identical to npm 1.0.1** (incl. FullMath, StateLibrary, LPFeeLibrary, Currency, BeforeSwapDelta, BalanceDelta) - no tampering. Because the deployed bytecode is immutable and the source is unchanged, that provenance verdict carries forward.
- Audit-diff playbook: N/A (single-purpose deployed hook, no `audits/` in a repo). Prior-run cross-check: same clean conclusion reached independently on 2026-08-18, 2026-08-24, and earlier 2026-09-07.

## 4. Threat model and invariants
Actors and trust boundaries: **anyone** can trigger a swap on a pool bound to this hook, but the hook's callbacks are only ever invoked by the **PoolManager** (`onlyPoolManager`). The **PoolManager** (Base canonical `0x498581fF718922c3f8E6A244956aF099B2652b2b`, immutable in the hook) is the sole trusted caller. There is no owner, no admin, no upgrade authority, and no custody - value crosses a boundary only via `poolManager.take()`, which sends the fixed 10 bps to the compile-time-constant treasury `0xF1E958db7D1e4C074377946018Ad645db4FB158e`.

| ID | Invariant | Why it matters |
|----|-----------|----------------|
| INV1 | All hook callbacks are `onlyPoolManager` | An unauthenticated callback could forge state / take funds |
| INV2 | The 10 bps protocol fee cannot be lowered, skipped, or redirected by a derived hook | Fee theft / protocol revenue loss |
| INV3 | Fee is taken on the correct unspecified currency, on the correct magnitude, in all 4 direction×exactness cases | Wrong-currency/wrong-sign take breaks accounting |
| INV4 | The returned afterSwap delta equals what was `take()`n; the int128 cast cannot overflow | Delta mismatch bricks the pool or mis-settles |
| INV5 | Dynamic LP fee is clamped to [0.05%, 5%] and OR'd with the override flag | Unbounded fee = griefing / pool DoS |
| INV6 | Per-pool state (`tickAtSwapStart`, `lastMove`) is isolated by PoolId | Cross-pool state corruption |
| INV7 | No reentrancy through the callbacks | Reentrancy could corrupt state or double-take |
| INV8 | Address permission flags (0x10C4) exactly match implemented callbacks | Flag/callback mismatch = misconfigured or malicious hook |

## 5. Findings
No confirmed findings.

### Candidates raised and refuted
No candidates survived to triage; the surface was reasoned clean directly. Classes explicitly ruled out during the hunt, with the mitigating control:
- **int128.min negation** in `AeonFee.afterSwap` (`if (unspecifiedAmount < 0) unspecifiedAmount = -unspecifiedAmount;`) - a `type(int128).min` delta would revert on negate. Unreachable: swap deltas are bounded far below int128.min, and a revert would only fail that single (astronomically large) swap. Not promoted.
- **Dynamic-fee manipulation** - an attacker can move the tick to raise the next swap's `lastMove`, but the fee is hard-clamped at 5%, the attacker eats the slippage/fee of their own move, and the value feeds **no external oracle**. Bounded, self-limiting, no fund path. Design property, not a bug.
- **Native-pair swap revert** - if a native-token pool bound this hook and the recipient could not receive ETH, swaps on *that* pool would revert. Recipient is the operator's own treasury; affects only opted-in pools; LPs can still remove liquidity. Not a third-party DoS.

## 6. Coverage and limitations
- Explored: access control (all callbacks `onlyPoolManager`), reentrancy (only external calls are `getSlot0` view + `take` to a fixed treasury), oracle/price manipulation (dynamic fee feeds no oracle; bounded), arithmetic/precision (fee rounds down in the swapper's favor; int128 cast guarded), upgradeability (non-proxy, immutable `poolManager`, no delegatecall/selfdestruct), external-call assumptions (`take` to a constant recipient), signatures/replay (N/A - no signatures), economic/MEV (fee bounded, no slippage-sensitive custody), and the full v4-hook checklist (permission-bit vs callback match, flash-accounting delta correctness, hookData/PoolKey trust, gate unit-confusion - N/A, DynamicFee is not a gate hook).
- Slither hit classes (from the prior 09-07 pass, all false positive): 1 `incorrect-exp` High + 9 `divide-before-multiply` Medium in canonical `FullMath.mulDiv` modular-inverse bit-hacks on SHA-verified upstream; 2 intentional `getSlot0` partial-destructures in DynamicFee.
- Not exercised: fuzz arm skipped (clean-audit hard gate, 0 survivors) - the S5 reasoning is the audit here. Vendored `@uniswap/v4-core` files reviewed for provenance (SHA-256) only, not line-by-line logic (canonical upstream).
- Honest partiality: a paid human audit would additionally run a full property-fuzz campaign against a live PoolManager fork (multi-pool, native + fee-on-transfer + rebasing tokens), and formally verify the accounting-delta reconciliation across exact-in/exact-out and partial-fill swaps. Nothing in the source reasoning suggests those would surface an issue, but they are outside this run's bounded scope.

## 7. Appendix

- Contract: [`0x723b16eF13a1b9A2BD63238BEC47cDF1d4A010C4` on BaseScan](https://basescan.org/address/0x723b16eF13a1b9A2BD63238BEC47cDF1d4A010C4) - verified source.
- Registry entry: [`hooks/dynamicfee.json`](https://github.com/aeonfun/univ4-hooks/blob/main/hooks/dynamicfee.json) - flags + every-chain addresses.
- Source: [`src/DynamicFee.sol`](https://github.com/aeonfun/univ4-hooks/blob/main/src/DynamicFee.sol) on the shared [`src/AeonFee.sol`](https://github.com/aeonfun/univ4-hooks/blob/main/src/AeonFee.sol) 10 bps base.
- Auditor: aeon `sc-audit` - autonomous agentic source review + Slither + fuzz-on-findings, operated by @aeonframework.
- Disclosure: clean audit, nothing to disclose. aeon.fun first-party hook; onchain findings are operator-gated by policy.

> Autonomous agent audit: threat-model-first source review, Slither, and a fuzz arm gated on findings. Thorough and case-exhaustive at the source level, but not a substitute for a paid human audit - see the Coverage and limitations section for what was and was not machine-proven.
