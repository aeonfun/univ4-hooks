# sc-audit report: base:0xf7423f48886F86F551B517254d21AF4267732888 (TwigWrapHook / Twigpine Wrap Hook)

- Auditor: MiniAeon sc-audit (autonomous agentic review + Slither + reproducible build + provenance diff)
- Date: 2026-10-04   ·   Mode: onchain   ·   Run: `run_20261004T204938Z_sc-audit_d498dc`
- Target: base:0xf7423f48886F86F551B517254d21AF4267732888 (`TwigWrapHook`, a Uniswap v4 1:1 wrap/unwrap hook for TWIG/GITLAWB)
- On-chain context: non-proxy (EIP-1967 slot `0x0`); no owner, admin, storage, upgrade, pause, `receive` or `fallback`. The hook holds 0 GITLAWB, 0 TWIG, 0 ETH.
- Outcome: CLEAN (0 novel findings; 1 low that Uniswap already documents)
- Disclosure: nothing staged. The one confirmed low matches public Uniswap documentation, and the other six candidates were refuted.

## 1. Executive summary
`TwigWrapHook` makes a fee-0 GITLAWB/TWIG pool wrap and unwrap at exactly 1:1 inside swaps, the same design as Uniswap's WETHHook. It is 57 lines of project code on top of `BaseHook` and `BaseTokenWrapperHook`, both byte-identical to `Uniswap/v4-hooks-public@e4eabe5`. The audit found **no novel findings**. In all four swap cases (wrap or unwrap, exact-in or exact-out) the hook's net currency delta is exactly 0 and the swapper pays and receives exactly the same amount, so any mis-accounting would revert the whole unlock: the failure mode is denial, never extraction. The TWIG wrapper is a bare OpenZeppelin `ERC20Wrapper` and is backed 1:1 to the wei on chain (2,680,198,866.4355 TWIG supply, 2,680,198,866.4355 GITLAWB held). One low, routing-dependent liveness limit was confirmed and is already documented by Uniswap (section 5).

## 2. Scope
- Contracts reviewed: 3/3 production (`src/TwigWrapHook.sol`, `src/vendor/v4-hooks-public/BaseTokenWrapperHook.sol`, `src/vendor/v4-hooks-public/BaseHook.sol`), plus the dependencies on the money path: `TwigWrapper` (`0x6aC18bcf4edE02591d4917452700Ea5eaaEA13c1`) and GITLAWB (`0x5f980DCfC4C0Fa3911554CF5aB288eD0eb13dbA3`, a Doppler `DERC20`).
- Entrypoints reviewed: 10/10 non-view functions (every one an `IHooks` callback behind `onlyPoolManager`) and 6/6 views (all return immutables).
- Address audited: 0xf7423f48886F86F551B517254d21AF4267732888 (Base, chainid 8453); verified source from Etherscan V2 (solc 0.8.26, `via_ir`, optimizer 200 runs, cancun).
- Wiring read from chain: `poolManager` = `0x498581fF718922c3f8e6a244956aF099B2652b2b` (canonical v4 PoolManager on Base), `wrapper` = TWIG, `wrapper.underlying()` = GITLAWB, `wrapZeroForOne` = true. Live pool `0xe7d26ece...96320` (fee 0, tickSpacing 1, `sqrtPriceX96` = 2^96 exactly).

## 3. Methodology
Threat-model-first: invariants derived first, then 7 fresh-context lens hunters (math and units, hostile token, honest user, two-party, unprivileged caller, consumer, wildcard), then 9 fresh-context refuters (a 3-verifier quorum on the only candidate that could have graded high), then a separate known-report check for the single survivor.
- Tools: slither(ok, 12 results: 10 in vendored upstream code, 2 on project code, all triaged), agentic(ok), fuzz(skipped: the confirmation arm runs only for an invariant, arithmetic, economic or access-control survivor; the one survivor is liveness).
- Reproducible build: a local `forge build` with the verified settings gives runtime code byte-for-byte identical to the 4157 bytes on chain after masking the 27 immutable slots. Runtime sha256 `62b01a06cd9e8a9ea1da83e925aa383b1dd3c2fd44557752486177b194c3345d`.
- Provenance: 35/35 vendored files accounted for. Both `v4-hooks-public` files are SHA-256 identical to `e4eabe5` and current `main`; 9 OpenZeppelin files identical to `@openzeppelin/contracts` 5.0.0 to 5.0.2; 22 v4-core files identical to `@uniswap/v4-core` 1.0.0 or 1.0.2; 3 v4-periphery files identical to 1.0.0. `DeltaResolver.sol` differs from tagged releases by two `virtual` keywords and two comments only (an untagged upstream commit; the hook overrides neither function).
- Hook flags: `0xf742...2888 & 0x3FFF = 0x2888` = beforeInitialize | beforeAddLiquidity | beforeSwap | beforeSwapReturnDelta, equal to `getHookPermissions()`.

## 4. Threat model and invariants
Actors and trust boundaries: **anyone** can create a pool with this hook or swap through it via the PoolManager, but cannot call a callback directly (`onlyPoolManager`); the **PoolManager** is the sole trusted caller; **TwigWrapper** mints and burns TWIG and holds the hook's GITLAWB approval (no owner); the **GITLAWB owner** is the Doppler Airlock, a third party with no authority over the hook. Value crosses boundaries only at `poolManager.take`, `wrapper.depositFor`/`withdrawTo`, and the settle back to the PoolManager.

| ID | Invariant | Why it matters |
|----|-----------|----------------|
| INV-1 | the hook's PoolManager deltas net to zero after every `beforeSwap` | otherwise the hook owes the PoolManager (revert) or leaves value for someone else to take |
| INV-2 | wrapped out == underlying in, exactly, both directions | the 1:1 promise; no fee, no rounding |
| INV-3 | the hook never retains GITLAWB or TWIG | it has no sweep, so retained dust would be lost |
| INV-4 | `GITLAWB.balanceOf(wrapper) >= TWIG.totalSupply()` | wrapper solvency; holds to the wei on chain |
| INV-5 | the pool can never hold LP liquidity | pool price can never affect the executed rate |
| INV-6 | every pool using the hook is the {GITLAWB, TWIG} pair at fee 0 | enforced in `_beforeInitialize` |
| INV-7 | address flags equal the permissions the code returns | a mismatch silently drops callbacks or deltas |

## 5. Findings
No novel findings. One confirmed low is already documented publicly.

### TWIG-01 (low, confidence medium, already documented): swap size is bound to the PoolManager's standing inventory
`src/TwigWrapHook.sol:36` and `:47` call `_take` inside `beforeSwap`, before the swapper has settled anything. `PoolManager.take` transfers out of the singleton's physical balance, which is funded by unrelated pools, so a swap of size X reverts unless the PoolManager already holds X of the currency being paid out. At audit time the PoolManager held 844,119,297.57 TWIG against a 2,680,198,866.4355 TWIG supply, so about 68.5% of TWIG cannot be unwrapped in one swap with the default swap-then-settle router plan. Principal is never at risk: `ERC20Wrapper.withdrawTo` is a permissionless, unconditional 1:1 exit, and a router plan that settles before swapping (`[SETTLE(X), SWAP_EXACT_IN_SINGLE(OPEN_DELTA), TAKE_ALL]`) is unaffected. Uniswap's v4 [Custom Accounting guide](https://docs.uniswap.org/contracts/v4/guides/custom-accounting) documents this exact behaviour and the same workarounds, so it was not staged for disclosure.

### Candidates raised and refuted
1. **Decoy pools at an attacker-chosen price.** `_beforeInitialize` ignores `sqrtPriceX96` and does not constrain `tickSpacing`, so anyone can create other pool ids for the pair at any price. Refuted (2 of 3 verifiers; no quorum): the live pool's price is exactly 2^96 and protected by `PoolAlreadyInitialized` (`Pool.sol:101`), v4 keeps no registry of pool keys to enumerate, the quoter executes an honest 1:1 against any decoy, and this is universal v4 behaviour. Same code as the audited upstream.
2. **Mid-swap `sync()` clobbering the PoolManager's synced-currency slot.** Refuted: `DeltaResolver.sol:41-47` is the only `sync(` call site in v4-periphery and runs sync, pay, settle atomically; no canonical router holds a synced slot across a swap, and a victim's settle would credit 0 and revert the unlock.
3. **No rescue path for stray tokens.** Refuted: true that the hook has no sweep, but no protocol path leaves a residue, and pushing tokens into the hook is self-funded (`PoolManager.sol:294` charges `take` to the caller). Live exposure is 0.
4. **GITLAWB's `lockPool` bricking a hook leg.** Refuted: GITLAWB's owner is the verified Doppler Airlock, whose only `lockPool` call (`Airlock.sol:163`) acts on a token created in the same transaction; its only ownership change, `migrate()`, unlocks and hands ownership to a timelock that is `0x...dEaD` for GITLAWB. On chain `pool()` = `0x...dEaD`.
5. **Slither `unused-return` on `depositFor` / `withdrawTo`.** Refuted: both return a literal `true` as their only non-reverting exit (`ERC20Wrapper.sol:62`, `:74`), and the wrapper is an immutable, non-proxy contract.
6. **Wrapped GITLAWB voting power cannot be delegated.** Refuted: true but not a loss; `withdrawTo` is a permissionless 1:1 exit, so voting rights are suspended while wrapped, as with any vault or AMM.

## 6. Coverage and limitations
- Explored: access control, reentrancy, delta accounting in all four swap cases, arithmetic and units, hostile or blocking token behaviour (GITLAWB `DERC20` transfer rules, owner powers), pool initialization, upgradeability (none), external-call assumptions, voting-token side effects, and the v4 flag encoding.
- Not exercised: no fuzz campaign (no survivor in a fuzzable class), no fork PoC (required only for a confirmed critical or high). Vendored upstream files were provenance-diffed, not independently logic-audited.
- Honest partiality: several sub-agent outputs were truncated in the run log, so a few lower-ranked duplicate candidates may not have been recorded individually; every distinct root cause visible was triaged. This is a community-submitted hook; the audit covers the deployed contract at this address only, not the Twigpine website or wrap UI.

## 7. Appendix

- Listed on aeon.fun: [aeon.fun/hooks?hook=twigpine-wrap-hook](https://www.aeon.fun/hooks?hook=twigpine-wrap-hook) - open this hook in the marketplace.
- Contract: [`0xf7423f48886F86F551B517254d21AF4267732888` on BaseScan](https://basescan.org/address/0xf7423f48886F86F551B517254d21AF4267732888) - verified source.
- Registry entry: [`hooks/twigpine-wrap-hook.json`](https://github.com/aeonfun/univ4-hooks/blob/main/hooks/twigpine-wrap-hook.json) - flags + address.
- Submission: [aeonfun/univ4-hooks#20](https://github.com/aeonfun/univ4-hooks/issues/20).
- Upstream base: [Uniswap/v4-hooks-public@e4eabe5](https://github.com/Uniswap/v4-hooks-public/tree/e4eabe526f9b516fff78d98ba781251747f0fd6e/src/base).
- Auditor: MiniAeon `sc-audit` - autonomous agentic source review + Slither + reproducible build, operated by @aeonframework.

> Autonomous agent audit: threat-model-first source review, Slither, and a fuzz arm gated on findings. Thorough at the source level, but not a substitute for a paid human audit - see the Coverage and limitations section for what was and was not machine-proven.
