// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Self-contained (no forge-std): minimal cheatcode interface + require-based asserts.
import {AeonFee} from "../src/AeonFee.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

interface Vm {
    function prank(address) external;
    function expectRevert() external;
}

/// @dev Minimal PoolManager stand-in: records the last take() so the test can
/// assert the exact fee the hook pulled. Only take() is exercised by AeonFee.afterSwap.
contract MockPM {
    Currency public lastCurrency;
    address public lastTo;
    uint256 public lastAmount;
    uint256 public takeCount;

    function take(Currency currency, address to, uint256 amount) external {
        lastCurrency = currency;
        lastTo = to;
        lastAmount = amount;
        takeCount++;
    }
}

/// @dev Concrete AeonFee with no extra post-swap logic (default _afterSwapExtra = 0).
contract TestHook is AeonFee {
    constructor(IPoolManager _pm) AeonFee(_pm) {}
}

contract AeonFeeTest {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    MockPM pm;
    TestHook hook;
    address constant RECIPIENT = 0xF1E958db7D1e4C074377946018Ad645db4FB158e;

    Currency c0 = Currency.wrap(address(0xA0));
    Currency c1 = Currency.wrap(address(0xB1));

    function setUp() public {
        pm = new MockPM();
        hook = new TestHook(IPoolManager(address(pm)));
    }

    function _eq(uint256 a, uint256 b, string memory m) internal pure {
        require(a == b, m);
    }

    function _key() internal view returns (PoolKey memory) {
        return PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(address(hook))});
    }

    function _params(bool zeroForOne, int256 amountSpecified)
        internal
        pure
        returns (IPoolManager.SwapParams memory)
    {
        return IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: 0});
    }

    function _callAfterSwap(IPoolManager.SwapParams memory p, BalanceDelta delta) internal {
        vm.prank(address(pm)); // satisfy onlyPoolManager
        hook.afterSwap(address(this), _key(), p, delta, "");
    }

    // exact-INPUT zeroForOne: unspecified = currency1 output (positive delta.amount1()).
    // Fee = 10 bps of that magnitude, taken on currency1, routed to the fixed recipient.
    function test_exactInput_takesFeeOnOutput() public {
        int128 output = 1_000_000;
        _callAfterSwap(_params(true, -500), toBalanceDelta(int128(-500), output));
        _eq(pm.takeCount(), 1, "fee taken once");
        require(Currency.unwrap(pm.lastCurrency()) == Currency.unwrap(c1), "fee on unspecified (c1)");
        _eq(pm.lastAmount(), uint256(uint128(output)) * 10 / 10_000, "10 bps of output");
        require(pm.lastTo() == RECIPIENT, "routed to fixed recipient");
    }

    // exact-OUTPUT zeroForOne: unspecified = currency1 INPUT (negative delta.amount1()).
    // Fee owed on the magnitude of the negative side -- the exact-output path the redeploy fixed.
    function test_exactOutput_takesFeeOnNegativeSide() public {
        // exact-output zeroForOne: specified = output (currency1), unspecified = input (currency0).
        // Condition (amountSpecified<0)==zeroForOne is false here -> selects currency0/amount0.
        int128 input = -2_000_000; // token0 owed by swapper (negative), on amount0
        _callAfterSwap(_params(true, 1_000), toBalanceDelta(input, int128(1_000)));
        _eq(pm.takeCount(), 1, "fee taken on exact-output too");
        require(Currency.unwrap(pm.lastCurrency()) == Currency.unwrap(c0), "fee on unspecified input (c0)");
        _eq(pm.lastAmount(), uint256(uint128(-input)) * 10 / 10_000, "10 bps of |input|");
    }

    // THE FIX: an unspecified delta of type(int128).min must NOT brick the swap.
    // Pre-fix `-unspecifiedAmount` on int128.min reverts (checked-arithmetic overflow);
    // post-fix the int256 widen computes the magnitude and the swap proceeds.
    function test_int128Min_doesNotRevert() public {
        int128 minVal = type(int128).min; // -2^127
        _callAfterSwap(_params(true, -1), toBalanceDelta(int128(0), minVal));
        _eq(pm.takeCount(), 1, "swap proceeded, fee taken");
        uint256 magnitude = uint256(1) << 127; // |type(int128).min| = 2^127
        _eq(pm.lastAmount(), magnitude * 10 / 10_000, "fee = 10 bps of 2^127");
    }

    // Sub-threshold: output < 1000 units floors the fee to 0 -> no take() (revenue note #2).
    function test_subThreshold_floorsToZero() public {
        _callAfterSwap(_params(true, -1), toBalanceDelta(int128(-1), int128(999)));
        _eq(pm.takeCount(), 0, "no fee below 1000 units (documents the floor-to-zero leak)");
    }

    // Negative control: the exact operation the fix removed (`-int128.min`) DOES revert under
    // 0.8 checked arithmetic -- proving the int256-widen change is load-bearing, not cosmetic.
    function negate(int128 x) external pure returns (int128) {
        return -x;
    }

    function test_provesOldNegationWouldRevert() public {
        (bool ok,) = address(this).call(abi.encodeWithSelector(this.negate.selector, type(int128).min));
        require(!ok, "negating int128.min must revert -- the pre-fix code path");
    }
}

// ---------------------------------------------------------------------------
// The int128.min class recurs in CrownClash + LegacyLedger's own skim path
// (their own copy of the negation, not covered by the AeonFee fix). These
// prove afterSwap survives a settled delta of type(int128).min once a player opts in.
// ---------------------------------------------------------------------------

import {CrownClash} from "../src/CrownClash.sol";
import {LegacyLedger} from "../src/LegacyLedger.sol";

contract SkimHooksTest {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    MockPM pm;
    Currency c0 = Currency.wrap(address(0xA0));
    Currency c1 = Currency.wrap(address(0xB1));

    function setUp() public {
        pm = new MockPM();
    }

    function _key(address hook) internal view returns (PoolKey memory) {
        return PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 60, hooks: IHooks(hook)});
    }

    function _params() internal pure returns (IPoolManager.SwapParams memory) {
        return IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});
    }

    // player opted in (32-byte hookData) + unspecified delta = int128.min -> must not revert.
    function test_crownClash_int128Min_skimDoesNotRevert() public {
        CrownClash hook = new CrownClash(IPoolManager(address(pm)));
        bytes memory hookData = abi.encode(address(0xBEEF));
        vm.prank(address(pm));
        hook.afterSwap(address(this), _key(address(hook)), _params(), toBalanceDelta(int128(0), type(int128).min), hookData);
        require(pm.takeCount() == 2, "base fee + tribute both taken, no revert");
    }

    function test_legacyLedger_int128Min_skimDoesNotRevert() public {
        LegacyLedger hook = new LegacyLedger(IPoolManager(address(pm)));
        bytes memory hookData = abi.encode(address(0xBEEF));
        vm.prank(address(pm));
        hook.afterSwap(address(this), _key(address(hook)), _params(), toBalanceDelta(int128(0), type(int128).min), hookData);
        require(pm.takeCount() == 2, "base fee + tax both taken, no revert");
    }
}
