// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// CapGate - regenerated on the AeonFee base.
// "Rejects any trade bigger than a fixed FRACTION of the pool - the pool fills small swaps only."
// beforeSwap reverts TradeTooLarge when the swap's specified amount exceeds MAX_TRADE_BPS of the
// pool's virtual reserve of the SAME currency the amount is denominated in. Reading the cap off
// the pool's own reserves makes it dimensionless: a raw token cap (the old `MAX_TRADE = 100e18`)
// silently did nothing on any pool whose specified token had < 18 decimals, and meant wildly
// different real sizes across pairs. Mandatory 10 bps AeonFee inherited.
// Flags: BEFORE_SWAP + AFTER_SWAP + returns-delta = 0xC4.

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {AeonFee} from "./AeonFee.sol";

contract CapGate is AeonFee {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;
    /// @notice Max swap size as a fraction of the specified currency's virtual reserve (5%).
    uint256 public constant MAX_TRADE_BPS = 500;

    /// @notice The specified amount was more than MAX_TRADE_BPS of that currency's reserve.
    error TradeTooLarge(uint256 size, uint256 cap, bool specifiedIsZero);

    constructor(IPoolManager _pm) AeonFee(_pm) {}

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 size = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        // amountSpecified is denominated in currency0 or currency1 depending on direction AND
        // exact-in vs exact-out. Cap it against the reserve of that SAME currency so the bound is
        // dimensionless (same units on both sides), regardless of token decimals.
        //   zeroForOne + exact-in  -> pays currency0 (specified = currency0)
        //   zeroForOne + exact-out -> receives currency1 (specified = currency1)
        //   oneForZero + exact-in  -> pays currency1 (specified = currency1)
        //   oneForZero + exact-out -> receives currency0 (specified = currency0)
        bool exactIn = params.amountSpecified < 0;
        bool specifiedIsZero = params.zeroForOne == exactIn;

        (uint256 b0, uint256 b1) = _reserves(key);
        uint256 reserve = specifiedIsZero ? b0 : b1;
        // Uninitialized / no active liquidity: no reserve to size against. Do not brick - a swap
        // on an empty pool fails in core anyway.
        if (reserve == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        uint256 cap = FullMath.mulDiv(reserve, MAX_TRADE_BPS, BPS); // 5% of the specified reserve
        if (size > cap) revert TradeTooLarge(size, cap, specifiedIsZero);

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice This pool's VIRTUAL reserves at the current price, from its own slot0 price and
    /// active liquidity via StateLibrary - NOT `balanceOf(poolManager)` (the v4 singleton's
    /// global inventory across every pool).
    function reserves(PoolKey calldata key) external view returns (uint256 balance0, uint256 balance1) {
        return _reserves(key);
    }

    /// @notice The current cap (max specified size) for a given direction + exact-in/out, so a
    /// caller can size a trade without guessing. 0 means the pool has no active liquidity.
    function maxTradeSize(PoolKey calldata key, bool zeroForOne, bool exactIn) external view returns (uint256) {
        (uint256 b0, uint256 b1) = _reserves(key);
        uint256 reserve = (zeroForOne == exactIn) ? b0 : b1;
        return FullMath.mulDiv(reserve, MAX_TRADE_BPS, BPS);
    }

    function _reserves(PoolKey calldata key) internal view returns (uint256 b0, uint256 b1) {
        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        if (sqrtPriceX96 == 0) return (0, 0);
        uint128 liquidity = poolManager.getLiquidity(id);
        if (liquidity == 0) return (0, 0);
        b0 = FullMath.mulDiv(uint256(liquidity), FixedPoint96.Q96, sqrtPriceX96);
        b1 = FullMath.mulDiv(uint256(liquidity), sqrtPriceX96, FixedPoint96.Q96);
    }
}
