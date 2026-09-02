// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// HeavierHand - regenerated on the AeonFee base.
// "Only lets you sell whichever token the pool holds more of." Inside a MAX_SKEW_BPS band a
// swap must pay in the heavier (or equal) currency; past the cap a release valve inverts so
// only the rebalancing leg is admitted (the pool can never be shut). Mandatory 10 bps AeonFee
// inherited. Flags: BEFORE_SWAP + AFTER_SWAP + returns-delta = 0xC4.

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {AeonFee} from "./AeonFee.sol";

contract HeavierHand is AeonFee {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;
    /// @notice How far out of balance the pool may walk before the gate inverts (10%).
    uint256 public constant MAX_SKEW_BPS = 1_000;

    uint8 public constant DIR_EITHER = 0;
    uint8 public constant DIR_ZERO_FOR_ONE = 1;
    uint8 public constant DIR_ONE_FOR_ZERO = 2;

    /// @notice Inside the band: the swap must pay in the heavier (or equal) currency.
    error MustSellHeavierSide(bool zeroForOne, uint256 balance0, uint256 balance1);
    /// @notice Past the skew cap: only the leg paying in the LIGHT currency is admitted.
    error MustRebalanceBeyondSkewCap(bool zeroForOne, uint256 balance0, uint256 balance1, uint256 skewBpsNow);

    constructor(IPoolManager _pm) AeonFee(_pm) {}

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (uint256 b0, uint256 b1) = _reserves(key);
        bool paysHeavySide = params.zeroForOne ? b0 >= b1 : b1 >= b0;

        if (_beyondCap(b0, b1)) {
            if (paysHeavySide) revert MustRebalanceBeyondSkewCap(params.zeroForOne, b0, b1, _skewBps(b0, b1));
        } else if (!paysHeavySide) {
            revert MustSellHeavierSide(params.zeroForOne, b0, b1);
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function reserves(PoolKey calldata key) external view returns (uint256 balance0, uint256 balance1) {
        return _reserves(key);
    }

    function imbalance(PoolKey calldata key) external view returns (uint256) {
        (uint256 b0, uint256 b1) = _reserves(key);
        return b0 >= b1 ? b0 - b1 : b1 - b0;
    }

    function skewBps(PoolKey calldata key) external view returns (uint256) {
        (uint256 b0, uint256 b1) = _reserves(key);
        return _skewBps(b0, b1);
    }

    function isBeyondSkewCap(PoolKey calldata key) external view returns (bool) {
        (uint256 b0, uint256 b1) = _reserves(key);
        return _beyondCap(b0, b1);
    }

    /// @notice Which leg the gate admits right now. Never "neither".
    function allowedDirection(PoolKey calldata key) external view returns (uint8) {
        (uint256 b0, uint256 b1) = _reserves(key);
        if (b0 == b1) return DIR_EITHER;
        bool heavyIsZero = b0 > b1;
        if (_beyondCap(b0, b1)) return heavyIsZero ? DIR_ONE_FOR_ZERO : DIR_ZERO_FOR_ONE;
        return heavyIsZero ? DIR_ZERO_FOR_ONE : DIR_ONE_FOR_ZERO;
    }

    /// @notice Quote the gate for one direction without submitting a swap.
    function isAllowed(PoolKey calldata key, bool zeroForOne) external view returns (bool) {
        (uint256 b0, uint256 b1) = _reserves(key);
        bool paysHeavySide = zeroForOne ? b0 >= b1 : b1 >= b0;
        return _beyondCap(b0, b1) ? !paysHeavySide : paysHeavySide;
    }

    /// @notice The currency the pool currently holds more of (currency0 on a tie).
    function heavierCurrency(PoolKey calldata key) external view returns (Currency) {
        (uint256 b0, uint256 b1) = _reserves(key);
        return b1 > b0 ? key.currency1 : key.currency0;
    }

    /// @notice This pool's VIRTUAL reserves at the current price, derived from its own slot0
    /// price and active liquidity via StateLibrary. NOT `balanceOf(poolManager)`, which returns
    /// the v4 SINGLETON's global inventory across every pool - movable by any unrelated pool
    /// sharing a currency, and writable in the same unlock frame via a free flash-accounting
    /// loan. Virtual reserves move only when a real swap moves THIS pool's price.
    function _reserves(PoolKey calldata key) internal view returns (uint256 b0, uint256 b1) {
        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        if (sqrtPriceX96 == 0) return (0, 0);
        uint128 liquidity = poolManager.getLiquidity(id);
        if (liquidity == 0) return (0, 0);
        // amount0 = L * 2^96 / sqrtP ; amount1 = L * sqrtP / 2^96
        b0 = FullMath.mulDiv(uint256(liquidity), FixedPoint96.Q96, sqrtPriceX96);
        b1 = FullMath.mulDiv(uint256(liquidity), sqrtPriceX96, FixedPoint96.Q96);
    }

    function _skewBps(uint256 b0, uint256 b1) internal pure returns (uint256) {
        (uint256 hi, uint256 lo) = b0 >= b1 ? (b0, b1) : (b1, b0);
        if (lo == 0) return hi == 0 ? 0 : type(uint256).max;
        uint256 d = hi - lo;
        if (d > type(uint256).max / BPS) return type(uint256).max;
        return d * BPS / lo;
    }

    function _beyondCap(uint256 b0, uint256 b1) internal pure returns (bool) {
        (uint256 hi, uint256 lo) = b0 >= b1 ? (b0, b1) : (b1, b0);
        if (lo == 0) return hi != 0;
        // Exact: multiply before divide so this agrees with _skewBps (no truncation of lo/BPS).
        return (hi - lo) * BPS > lo * MAX_SKEW_BPS;
    }
}
