# sc-audit report: base:0x5e48f905661D75501CA756eDB3403dA98F0400C4 (BlockEcho)

- Auditor: aeon sc-audit (autonomous agentic review + Slither + provenance)
- Date: 2026-09-07   ·   Mode: onchain
- Target: base:0x5e48f905661D75501CA756eDB3403dA98F0400C4 (BlockEcho - aeon.fun Uniswap v4 hook)
- On-chain context: non-proxy; native balance 0 wei (no custody at rest); poolManager = 0x498581fF718922c3f8e6A244956aF099B2652b2b (canonical Uniswap v4 PoolManager on Base, genuine/immutable)
- Outcome: CLEAN (0 confirmed)
- Disclosure: none (clean); operator-gated regardless (operator's own hook). Ledger row + coverage manifest written.

## 1. Executive summary
BlockEcho is a stateless Uniswap v4 gate hook built on aeon's shared `AeonFee` base. Its gimmick: a swap only clears `beforeSwap` if the absolute swap amount's last two decimal digits echo the current block number's last two digits, within a circular tolerance of 2 (`ECHO_MODULUS = 100`, `ECHO_WINDOW = 2`). `afterSwap` (inherited, non-virtual) takes the mandatory 10 bps protocol fee on the unspecified currency and routes it to the fixed treasury. This is the third independent audit of this exact deployed address (previously clean 2026-08-19 and 2026-08-24); it was re-run at the operator's explicit `var=` request inside the 30-day dedup window. The deployed bytecode is immutable, so the source is byte-identical to prior runs, but reasoning was re-derived independently and on-chain context + provenance were re-verified fresh. Verdict: clean - no path breaks any modeled invariant; the gate is a liveness gimmick on the swapper's own amount with no custody, no admin surface, and no fund-loss vector.

## 2. Scope
- Contracts reviewed: 2/2 (BlockEcho.sol + AeonFee.sol, ~191 LOC production)
- Entrypoints reviewed: 6/6 - 2 state-changing hook callbacks (`beforeSwap`, `afterSwap`, both `onlyPoolManager`) + 4 public `view` quote helpers (`requiredSuffix`, `isAcceptable`, `acceptableAmountAtOrAbove`, `blocksUntilAcceptable`)
- Address audited: 0x5e48f905661D75501CA756eDB3403dA98F0400C4 (Base, chainid 8453); bytecode 1992 bytes, immutable (non-proxy)
- Not reviewed this run: 14 vendored `@uniswap/v4-core` files (checked for provenance only, not re-audited - they are byte-identical to upstream 1.0.1). No admin/owner/pause/upgrade/init function exists to review - the hook has none.

## 3. Methodology
Threat-model-first: derived 8 invariants (S5.0), hunted a path breaking each (S5) across the full v4-hook checklist, adversarially refuted the two raised edge cases (S6). Fuzz arm not run (hard gate - 0 survivors).
- Tools: slither(ok - 2 hits, both false positives), agentic(ok), fuzz(not-run - clean-audit hard gate)
- Provenance (onchain): 14/14 vendored `@uniswap/v4-core` files SHA-256-IDENTICAL to genuine npm 1.0.1 (and cross-checked against 1.0.0); no supply-chain tampering. `AEON_FEE_RECIPIENT` = 0xF1E958db7D1e4C074377946018Ad645db4FB158e (aeon treasury); `poolManager` re-derived via Base RPC `eth_call` resolves to the canonical Base v4 PoolManager.
- Address-flag check: low-14-bit suffix `0x00C4` = BEFORE_SWAP + AFTER_SWAP + AFTER_SWAP_RETURNS_DELTA, an exact match to the two implemented callbacks; BEFORE_SWAP_RETURNS_DELTA (0x08) correctly unset since `beforeSwap` returns `ZERO_DELTA`.

## 4. Threat model and invariants
Actors: **anyone** (a swapper, routed in by the PoolManager; governs only whether their own amount clears the gate); **PoolManager** (the sole caller allowed past `onlyPoolManager`); **AEON_FEE_RECIPIENT** (immutable treasury that receives the 10 bps fee). Value/authority crosses a boundary at exactly two points - `afterSwap`'s `poolManager.take()` of the fee, and `beforeSwap`'s accept/reject decision.

| ID | Invariant | Why it matters |
|----|-----------|----------------|
| INV1 | `beforeSwap`/`afterSwap` callable only by the PoolManager | spoofed calls could fake gate/fee accounting |
| INV2 | 10 bps fee rate + recipient immutable and non-redirectable | fee theft / protocol revenue loss |
| INV3 | fee charged on the correct unspecified currency even on exact-output swaps | silent fee-skip / wrong-token charge |
| INV4 | gate never permanently bricks or one-directionally locks the pool | permanent DoS |
| INV5 | no swapper can grief another swapper's swap via the gate | griefing |
| INV6 | returned `afterSwap` delta equals what `poolManager.take` removed | delta mismatch drains/bricks the pool |
| INV7 | no reentrancy / state-corruption surface | accounting corruption |
| INV8 | address permission flags (0x00C4) exactly match implemented callbacks | flag mismatch mis-wires calls / fail-open |

All eight hold - see §5/§6.

## 5. Findings
No confirmed findings.

### Candidates raised and refuted
- **[none promoted]** `int128.min` / `int256.min` negation in `_size`/`AeonFee` - under solc 0.8.26 checked arithmetic, negating the minimum value reverts. This would revert only a single absurd-magnitude swap (~1.7e38+), unreachable in any real pool; not exploitable, not a DoS of legitimate flow. Refuted.
- **[none promoted]** `acceptableAmountAtOrAbove(target)` can overflow-revert when `target` is within ~100 of `uint256.max` - a `view` quote helper called with a nonsensical argument (no swap amount is near 2^256). DoS-on-nonsense-input only, off any value path. Refuted.
- **Slither: divide-before-multiply** in `CustomRevert.bubbleUpAndRevertWith` - the canonical `(returndatasize()+31)/32*32` round-up-to-word assembly idiom, inside a SHA-verified-identical upstream v4-core file. False positive.
- **Slither: incorrect-equality** `candidate == 0` in `acceptableAmountAtOrAbove` - the strict equality is precisely the intended wrap-guard (bump a zero candidate to `ECHO_MODULUS`) in a read-only helper. False positive.

## 6. Coverage and limitations
- Explored: **access control** (both callbacks `onlyPoolManager`; the Cork-$12M missing-guard class - present and correct; no owner/init/upgrade surface); **fee direction** (all 4 zeroForOne × exact-in/out cases re-derived - unspecified currency selected correctly every time; `abs` applied before the `>0` guard so exact-output is never fee-skipped); **gate logic / unit-confusion** (the echo is a modular match on the swapper's own amount, not a token-denominated cap nor a price/skew gate - the raw-price-vs-1.0 and sub-18-decimal fail-open classes do not apply; binds symmetrically across both tokens and both directions); **rounding** (fee floors down, never over-charges; `require(feeAmount <= int128.max)` before the cast); **reentrancy** (`beforeSwap` view; `afterSwap` single trusted `take()` with no subsequent mutation, no `_afterSwapExtra` override); **flash-accounting** (returned delta == taken amount); **liveness/DoS** (echo gate admits some amount at every block within window, both directions; view helpers hand callers a clearing amount → no permanent brick); **MEV/griefing** (stateless, so no cross-swap interference; `block.number` is not attacker-chosen). Provenance verified by SHA-256 diff against genuine npm.
- Not exercised: fuzz arm intentionally skipped (clean-audit hard gate, S6.5). The 14 vendored v4-core files were provenance-checked, not re-audited.
- Honest partiality: a paid human audit would additionally add on-chain fork simulation of live swaps across pool configurations and an economic model of the fee interaction with pool fee tiers. Given the trivial, stateless, custody-free surface and immutable bytecode already twice-audited clean, residual risk is very low.

## 7. Appendix

- Contract: [`0x5e48f905661D75501CA756eDB3403dA98F0400C4` on BaseScan](https://basescan.org/address/0x5e48f905661D75501CA756eDB3403dA98F0400C4) - verified source.
- Registry entry: [`hooks/blockecho.json`](https://github.com/aeonfun/univ4-hooks/blob/main/hooks/blockecho.json) - flags + every-chain addresses.
- Source: [`src/BlockEcho.sol`](https://github.com/aeonfun/univ4-hooks/blob/main/src/BlockEcho.sol) on the shared [`src/AeonFee.sol`](https://github.com/aeonfun/univ4-hooks/blob/main/src/AeonFee.sol) 10 bps base.
- Auditor: aeon `sc-audit` - autonomous agentic source review + Slither + fuzz-on-findings, operated by @aeonframework.
- Disclosure: clean audit, nothing to disclose. aeon.fun first-party hook; onchain findings are operator-gated by policy.

> Autonomous agent audit: threat-model-first source review, Slither, and a fuzz arm gated on findings. Thorough and case-exhaustive at the source level, but not a substitute for a paid human audit - see the Coverage and limitations section for what was and was not machine-proven.
