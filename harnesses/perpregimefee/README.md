# perpregimefee — behavioral test harness

the fork-based forge suite for the **PerpRegimeFee** hook, listed in
[`hooks/perpregimefee.json`](../../hooks/perpregimefee.json).

- base: [`0x190D7F16f9385026cb243BD78F1181427d4Cc0C4`](https://basescan.org/address/0x190D7F16f9385026cb243BD78F1181427d4Cc0C4)
- elysium: [`0x1dF778Efb0116CCCfA92c613703D4F3A66BC00C4`](https://elysium.kinetiq.xyz/explorer/address/0x1dF778Efb0116CCCfA92c613703D4F3A66BC00C4)

## why it lives here and not under `test/`

the registry root vendors only a minimal `@uniswap/v4-core` subset, and root ci runs
`forge build` over `src/` + `test/`. this suite pulls `forge-std`, `@uniswap/v4-periphery`
(`HookMiner`) and the `v4-core` swap-test helpers, none of which the root vendors — so it
can't sit under the root `test/` without breaking `forge build`. it's kept in
`harnesses/` (outside the root build paths) as a self-contained foundry project, so it
runs on its own and never touches root ci or `validate.py`.

`src/Hook.sol` and `src/AeonFee.sol` here are byte-identical to the deployed, verified
source (same `solc 0.8.26` / `via_ir` / 800-run profile in `foundry.toml`).

## run it

```bash
cd harnesses/perpregimefee
# fetch the pinned deps into lib/ (versions in dependencies.lock)
git clone --depth 1 https://github.com/foundry-rs/forge-std          lib/forge-std
git clone         https://github.com/Uniswap/v4-core                 lib/v4-core     && git -C lib/v4-core     checkout 59d3ecf
git clone         https://github.com/Uniswap/v4-periphery            lib/v4-periphery && git -C lib/v4-periphery checkout c6e4754

# run on a mainnet fork (base shown; elysium works the same with its pm + rpc)
POOL_MANAGER=0x498581ff718922c3f8e6a244956af099b2652b2b \
HOOK_FLAGS=196 HOOK_POOL_FEE=dynamic \
  forge test --fork-url https://mainnet.base.org --match-contract HookBehaviorTest -vv
```

`HOOK_FLAGS=196` is `0xC4` (`beforeSwap` + `afterSwap` + `afterSwapReturnsDelta`).

## what it asserts — 11 tests, all green

- `test_aeonProtocolFeeWired` — the mandatory 10 bps `AeonFee` recipient + bps + return-delta flag.
- `test_defaultRegimeIsNeutral` — ships at neutral (0.30%), oracle wired.
- `test_riskOn/neutral/riskOff…` — `beforeSwap` overrides the lp fee to 0.10% / 0.30% / 1.00% per regime and the swap clears.
- `test_onlyOracleCanUpdateRegime` — a non-oracle caller reverts `OnlyOracle`.
- `test_aeonFeeTakenOnExactInAndExactOut` / `test_extraFeeTakenOnExactInAndExactOut` — both fees land on exact-in and exact-out.
- `test_extraFeeWiredToOperator` — the 10 bps operator fee recipient + bps.

two regression tests added on top of the original nine:

- `test_operatorFeeStacksEqualToProtocolFee` — asserts the operator take **equals** the protocol take exactly (both are 10 bps of the same unspecified magnitude), so the operator fee is provably additive at the right rate, not compounded or cannibalising the protocol fee. a plain "balance went up" check would miss a wrong bps.
- `test_feesTakenOnCurrency0Leg` — a oneForZero exact-in exercises the `currency0` branch of the unspecified-currency selection, which the other fee tests never hit.

## independent verification (2026-11-10)

- base ↔ elysium runtime bytecode is identical except the 4 inline copies of the per-chain `PoolManager` immutable — same logic, same metadata.
- live getters on both chains: `AEON_FEE_RECIPIENT=0xF1E958db…`, `AEON_FEE_BPS=10`, `EXTRA_FEE_RECIPIENT=0x8050…`, `EXTRA_FEE_BPS=10`, regime neutral, `currentFee=3000`.
- `afterSwap` is non-virtual in `AeonFee`, and `Hook.sol` doesn't declare it — the protocol fee can't be overridden, lowered, or redirected by the subclass.
- not a formal third-party security audit; elysium source is explorer-verified, base is not yet.
