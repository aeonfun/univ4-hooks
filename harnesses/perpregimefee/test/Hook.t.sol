// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// FREEFORM behavioral test. In freeform mode the deploy-uni-hook skill rewrites the
// AEON:ASSERT region with `test_*` functions that assert the hook's SPECIFIC
// intended behavior (a swap that should revert reverts; a state getter returns the
// right value; a fee is skimmed; etc.). hook-deploy.sh runs
//   forge test --fork-url <chain> --match-contract HookBehaviorTest
// as a GATE before it will simulate or broadcast. A failing (or non-compiling) test
// blocks the deploy (DEPLOY_HOOK_TEST_FAILED). This proves the hook does what the
// prompt asked, not just that it does not revert.
//
// setUp() below is fixed scaffolding: it forks the target chain, mines + deploys the
// generated Hook with its auto-derived flags, opens a fresh pool AT 1:1, and adds deep
// liquidity. The generator MUST NOT edit setUp() or the helpers — only AEON:ASSERT.
// For any gate whose decision depends on price or reserve balance, DO NOT rely on the
// 1:1 pool alone: call _freshPoolAt(<non-1:1 sqrtPriceX96>) inside a test to repoint
// the pool off parity, then assert both legs. A price/balance/skew gate looks correct
// at 1:1 no matter how it is written, so testing only there proves nothing.

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {MockERC20} from "../src/MockERC20.sol";
import {Hook} from "../src/Hook.sol";

contract HookBehaviorTest is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager internal pm;
    Hook internal hook;
    PoolKey internal key;
    PoolModifyLiquidityTest internal lpRouter;
    PoolSwapTest internal swapRouter;
    MockERC20 internal tA;
    MockERC20 internal tB;
    uint24 internal poolFee;
    address internal oracle = address(0xBEEF);

    function setUp() public {
        pm = IPoolManager(vm.envAddress("POOL_MANAGER"));
        uint160 flags = uint160(vm.envUint("HOOK_FLAGS"));
        string memory pf = vm.envOr("HOOK_POOL_FEE", string("3000"));
        poolFee =
            keccak256(bytes(pf)) == keccak256("dynamic") ? LPFeeLibrary.DYNAMIC_FEE_FLAG : uint24(vm.parseUint(pf));

        // tokens
        tA = new MockERC20("Hook Test A", "HTA");
        tB = new MockERC20("Hook Test B", "HTB");
        tA.mint(address(this), 1e30);
        tB.mint(address(this), 1e30);
        (Currency c0, Currency c1) = address(tA) < address(tB)
            ? (Currency.wrap(address(tA)), Currency.wrap(address(tB)))
            : (Currency.wrap(address(tB)), Currency.wrap(address(tA)));

        // mine + deploy the generated hook at an address carrying its flag bits.
        // Mine with THIS contract as the CREATE2 deployer so `new Hook{salt}` matches.
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), flags, type(Hook).creationCode, abi.encode(pm, oracle));
        hook = new Hook{salt: salt}(pm, oracle);
        require(address(hook) == expected, "hook addr mismatch");
        require(uint160(address(hook)) & Hooks.ALL_HOOK_MASK == flags, "flag bits wrong");

        // pool at 1:1 + deep full-range liquidity so multi-1e18 swaps do not run dry
        key = PoolKey({currency0: c0, currency1: c1, fee: poolFee, tickSpacing: 60, hooks: IHooks(address(hook))});
        pm.initialize(key, 79228162514264337593543950336);

        lpRouter = new PoolModifyLiquidityTest(pm);
        swapRouter = new PoolSwapTest(pm);
        tA.approve(address(lpRouter), type(uint256).max);
        tB.approve(address(lpRouter), type(uint256).max);
        tA.approve(address(swapRouter), type(uint256).max);
        tB.approve(address(swapRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 1e23,
                salt: bytes32(0)
            }),
            ""
        );
    }

    /// @dev Run one swap. amountSpecified < 0 = exact-input of that size.
    function _swap(bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        return swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Assert a swap reverts AND the hook's own error is the cause. v4 wraps a
    /// hook revert in CustomRevert.WrappedError, so we scan the revert bytes for the
    /// hook error's 4-byte selector rather than matching the outer wrapper.
    /// Use for negative cases: _expectSwapRevert(true, -6e18, Hook.SomeError.selector).
    function _expectSwapRevert(bool zeroForOne, int256 amountSpecified, bytes4 hookErrorSelector) internal {
        try swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            revert("expected swap to revert but it succeeded");
        } catch (bytes memory err) {
            assertTrue(_containsSelector(err, hookErrorSelector), "reverted with the wrong error");
        }
    }

    function _containsSelector(bytes memory data, bytes4 sel) internal pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i = 0; i + 4 <= data.length; i++) {
            if (data[i] == sel[0] && data[i + 1] == sel[1] && data[i + 2] == sel[2] && data[i + 3] == sel[3]) {
                return true;
            }
        }
        return false;
    }

    /// @dev Repoint the test pool to a SECOND pool on the same hook, started at an
    /// arbitrary price, so `_swap` / `_expectSwapRevert` and any reserve/skew getter
    /// run OFF parity. Fresh tokens give it a distinct pool id (reusing the same
    /// tokens+fee+hook would collide with setUp's 1:1 pool). Initializing the new pool
    /// also fires the hook's afterInitialize on it, so a correctly price-anchored gate
    /// snapshots THIS pool's price as its reference. Any gate whose decision depends on
    /// price or reserve balance MUST be asserted through this helper, not only at 1:1.
    /// Pick a MODERATE off-parity price (e.g. 4.0) — the bug surfaces at any price
    /// outside the band, and extreme prices can exceed the minted token headroom.
    /// price 2.0  -> 112045541949572279837463876096
    /// price 4.0  -> 158456325028528675187087900672
    /// price 0.25 ->  39614081257132168796771975168
    function _freshPoolAt(uint160 sqrtPriceX96) internal {
        tA = new MockERC20("Hook Test A2", "HTA2");
        tB = new MockERC20("Hook Test B2", "HTB2");
        tA.mint(address(this), 1e33);
        tB.mint(address(this), 1e33);
        (Currency c0, Currency c1) = address(tA) < address(tB)
            ? (Currency.wrap(address(tA)), Currency.wrap(address(tB)))
            : (Currency.wrap(address(tB)), Currency.wrap(address(tA)));
        key = PoolKey({currency0: c0, currency1: c1, fee: poolFee, tickSpacing: 60, hooks: IHooks(address(hook))});
        pm.initialize(key, sqrtPriceX96);
        tA.approve(address(lpRouter), type(uint256).max);
        tB.approve(address(lpRouter), type(uint256).max);
        tA.approve(address(swapRouter), type(uint256).max);
        tB.approve(address(swapRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 1e23,
                salt: bytes32(0)
            }),
            ""
        );
    }

    /// @dev Combined balance of the AeonFee recipient across the pool's two tokens.
    function _aeonFeeBalance() internal view returns (uint256) {
        address r = hook.AEON_FEE_RECIPIENT();
        return tA.balanceOf(r) + tB.balanceOf(r);
    }

    // --- FIXED invariant (do NOT edit or remove): every aeon hook inherits AeonFee, so
    // the mandatory 10 bps protocol fee must be wired and the address must carry the
    // return-delta flag. This is swap-independent, so it holds even for revert-gate hooks
    // that reject a vanilla swap. hook-deploy.sh also refuses any Hook that is not
    // `is AeonFee`, and afterSwap is non-virtual - so the fee cannot be removed.
    function test_aeonProtocolFeeWired() public view {
        assertEq(hook.AEON_FEE_RECIPIENT(), 0xF1E958db7D1e4C074377946018Ad645db4FB158e, "wrong AeonFee recipient");
        assertEq(hook.AEON_FEE_BPS(), 10, "wrong AeonFee bps");
        assertTrue(
            uint160(address(hook)) & Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG != 0,
            "hook address missing afterSwapReturnsDelta flag"
        );
    }

    // --- AEON:ASSERT START (freeform: replace with behavioral tests for the prompt) ---
    function _assertRegimeFee(Hook.Regime newRegime, uint24 expectedFee) internal {
        vm.prank(oracle);
        hook.updateRegime(newRegime);

        vm.prank(address(pm));
        (bytes4 selector,, uint24 encodedFee) = hook.beforeSwap(
            address(swapRouter),
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );

        assertEq(selector, IHooks.beforeSwap.selector, "wrong beforeSwap selector");
        assertEq(hook.currentFee(), expectedFee, "wrong regime fee getter");
        assertEq(encodedFee, expectedFee | LPFeeLibrary.OVERRIDE_FEE_FLAG, "wrong dynamic-fee override");
        _swap(true, -1e15);
    }

    function test_defaultRegimeIsNeutral() public view {
        assertEq(hook.oracle(), oracle, "wrong oracle");
        assertTrue(hook.oracle() != address(this), "oracle must differ from deployer");
        assertEq(uint256(hook.currentRegime()), uint256(Hook.Regime.NEUTRAL), "default regime is not NEUTRAL");
        assertEq(hook.currentFee(), 3000, "default fee is not 0.30%");
    }

    function test_riskOnApplies1000FeeAndAllowsSwap() public {
        _assertRegimeFee(Hook.Regime.RISK_ON, 1000);
    }

    function test_neutralApplies3000FeeAndAllowsSwap() public {
        _assertRegimeFee(Hook.Regime.NEUTRAL, 3000);
    }

    function test_riskOffApplies10000FeeAndAllowsSwap() public {
        _assertRegimeFee(Hook.Regime.RISK_OFF, 10000);
    }

    function test_onlyOracleCanUpdateRegime() public {
        address nonOracle = address(0xCAFE);
        vm.startPrank(nonOracle);
        vm.expectRevert(Hook.OnlyOracle.selector);
        hook.updateRegime(Hook.Regime.RISK_OFF);
        vm.stopPrank();

        assertEq(uint256(hook.currentRegime()), uint256(Hook.Regime.NEUTRAL), "unauthorized update changed regime");
    }

    function test_aeonFeeTakenOnExactInAndExactOut() public {
        uint256 b0 = _aeonFeeBalance();
        _swap(true, -1e18); // exact-in
        uint256 b1 = _aeonFeeBalance();
        assertGt(b1, b0, "AeonFee not taken on exact-in");
        _swap(false, 1e15); // exact-out
        assertGt(_aeonFeeBalance(), b1, "AeonFee not taken on exact-out");
    }

    /// @dev Combined balance of the operator's extra-fee recipient across the pool's two tokens.
    function _extraFeeBalance() internal view returns (uint256) {
        address r = hook.EXTRA_FEE_RECIPIENT();
        return tA.balanceOf(r) + tB.balanceOf(r);
    }

    function test_extraFeeWiredToOperator() public view {
        assertEq(hook.EXTRA_FEE_RECIPIENT(), 0x805073311cB90854029Df7De4b25211F7a18cd7a, "wrong extra-fee recipient");
        assertEq(hook.EXTRA_FEE_BPS(), 10, "wrong extra-fee bps");
    }

    function test_extraFeeTakenOnExactInAndExactOut() public {
        uint256 e0 = _extraFeeBalance();
        _swap(true, -1e18); // exact-in
        uint256 e1 = _extraFeeBalance();
        assertGt(e1, e0, "extra fee not taken on exact-in");
        _swap(false, 1e15); // exact-out
        assertGt(_extraFeeBalance(), e1, "extra fee not taken on exact-out");
    }

    /// @dev The operator fee must be ADDITIVE on top of the mandatory protocol fee, and each
    /// exactly 10 bps of the SAME unspecified magnitude. Both are magnitude * 10 / 10_000 of
    /// the identical base delta, so the two recipients must receive byte-identical, non-zero
    /// amounts on any swap. A plain assertGt would still pass if the operator fee compounded
    /// off the post-protocol-fee amount, used a different bps, or cannibalised the protocol
    /// fee's delta; assertEq here pins stacking + rate parity swap-size-independently.
    function test_operatorFeeStacksEqualToProtocolFee() public {
        uint256 aeon0 = _aeonFeeBalance();
        uint256 op0 = _extraFeeBalance();
        _swap(true, -1e18);
        uint256 aeonTaken = _aeonFeeBalance() - aeon0;
        uint256 opTaken = _extraFeeBalance() - op0;
        assertGt(aeonTaken, 0, "protocol fee not taken");
        assertGt(opTaken, 0, "operator fee not taken");
        assertEq(opTaken, aeonTaken, "operator fee must equal the 10 bps protocol fee (additive, same base)");
    }

    /// @dev The other fee tests only swap into currency1 (the `true` branch of the
    /// unspecified-currency selection). Exercise the currency0 (`false`) branch too: a
    /// oneForZero exact-in pays out currency0, so a currency-selection regression on that leg
    /// cannot hide behind the currency1 cases. Both fees must still land.
    function test_feesTakenOnCurrency0Leg() public {
        uint256 aeon0 = _aeonFeeBalance();
        uint256 op0 = _extraFeeBalance();
        _swap(false, -1e18); // oneForZero exact-in -> unspecified = currency0
        assertGt(_aeonFeeBalance() - aeon0, 0, "protocol fee not taken on currency0 leg");
        assertGt(_extraFeeBalance() - op0, 0, "operator fee not taken on currency0 leg");
    }
    // --- AEON:ASSERT END ---
}
