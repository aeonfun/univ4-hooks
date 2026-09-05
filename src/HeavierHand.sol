// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// HeavierHand - regenerated on the AeonFee base.
// "Keeps a pool within a band of the price it opened at." Inside a MAX_SKEW_BPS band a swap
// must pay in the side the pool has grown heavier on RELATIVE TO ITS REFERENCE PRICE (or an
// equal split); past the cap a release valve inverts so only the rebalancing leg is admitted
// (the pool can never be shut). The reference is the pool's OWN sqrt price captured at
// afterInitialize - NOT an implicit 1.0 - so the gate is symmetric for any pair and any
// starting price, not just a same-decimals pool near parity. Mandatory 10 bps AeonFee
// inherited. Flags: AFTER_INITIALIZE + BEFORE_SWAP + AFTER_SWAP + returns-delta = 0x10C4.

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
    /// @notice How far the price may walk from its reference before the gate inverts (10%).
    uint256 public constant MAX_SKEW_BPS = 1_000;

    /// @notice sqrt(1.1) * 2^96 and sqrt(0.9) * 2^96: the sqrt-price band edges around the
    /// reference. Comparing SQRT prices against these is equivalent to a +/-10% band on PRICE
    /// (price is proportional to sqrtP^2) but never squares a sqrt price, so the gate cannot
    /// overflow no matter how far the pool has drifted from its reference.
    uint256 internal constant SQRT_UP_X96 = 83095197869223157896060286990;
    uint256 internal constant SQRT_DOWN_X96 = 75162434512514379355924140470;

    uint8 public constant DIR_EITHER = 0;
    uint8 public constant DIR_ZERO_FOR_ONE = 1;
    uint8 public constant DIR_ONE_FOR_ZERO = 2;

    /// @notice The pool's sqrt price at initialization - the gate's reference point. Every
    /// decision is "where is the current price relative to THIS", not relative to 1.0.
    mapping(PoolId => uint160) public referenceSqrtPriceX96;

    /// @notice Inside the band: the swap must pay in the heavier (or equal) side vs reference.
    error MustSellHeavierSide(bool zeroForOne, uint256 priceRatioBps);
    /// @notice Past the skew cap: only the leg paying in the LIGHT (rebalancing) side is admitted.
    error MustRebalanceBeyondSkewCap(bool zeroForOne, uint256 priceRatioBps, uint256 skewBpsNow);
    /// @notice A swap arrived before afterInitialize recorded the reference (should be impossible).
    error NoReference(PoolId id);

    constructor(IPoolManager _pm) AeonFee(_pm) {}

    /// @notice Capture the pool's own opening price as the gate's reference. Called by the
    /// PoolManager exactly once, at initialize, because the address carries the AFTER_INITIALIZE
    /// flag bit. Anchoring here is what makes the gate price-agnostic.
    function afterInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96, int24)
        external
        onlyPoolManager
        returns (bytes4)
    {
        referenceSqrtPriceX96[key.toId()] = sqrtPriceX96;
        return IHooks.afterInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        uint160 ref = referenceSqrtPriceX96[id];
        if (ref == 0) revert NoReference(id);
        (uint160 cur,,,) = poolManager.getSlot0(id);

        // Heavier side is defined RELATIVE TO THE REFERENCE: when the current price is at or
        // below the reference (cur <= ref), the pool has grown heavier on currency0, so paying
        // in currency0 (zeroForOne) is the heavy leg; symmetric on the other side.
        bool paysHeavySide = params.zeroForOne ? cur <= ref : cur >= ref;

        if (_beyondCap(cur, ref)) {
            if (paysHeavySide) {
                revert MustRebalanceBeyondSkewCap(params.zeroForOne, _ratioBps(cur, ref), _skewBps(cur, ref));
            }
        } else if (!paysHeavySide) {
            revert MustSellHeavierSide(params.zeroForOne, _ratioBps(cur, ref));
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice This pool's VIRTUAL reserves at the current price, derived from its own slot0
    /// price and active liquidity via StateLibrary. NOT `balanceOf(poolManager)`, which returns
    /// the v4 SINGLETON's global inventory across every pool. Kept for observability; the gate
    /// itself works off the price ratio, where liquidity cancels (that was the old bug: with an
    /// implicit 1.0 reference the reserve ratio IS 1/price, so any off-parity pool was one-way).
    function reserves(PoolKey calldata key) external view returns (uint256 balance0, uint256 balance1) {
        return _reserves(key);
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

    /// @notice The current price as a fraction of the reference, in bps (10_000 = exactly on
    /// reference). `skewBps` is the absolute deviation from that.
    function priceRatioBps(PoolKey calldata key) external view returns (uint256) {
        (uint160 cur, uint160 ref) = _curRef(key);
        return _ratioBps(cur, ref);
    }

    function skewBps(PoolKey calldata key) external view returns (uint256) {
        (uint160 cur, uint160 ref) = _curRef(key);
        return _skewBps(cur, ref);
    }

    function isBeyondSkewCap(PoolKey calldata key) external view returns (bool) {
        (uint160 cur, uint160 ref) = _curRef(key);
        return _beyondCap(cur, ref);
    }

    /// @notice Which leg the gate admits right now. Never "neither".
    function allowedDirection(PoolKey calldata key) external view returns (uint8) {
        (uint160 cur, uint160 ref) = _curRef(key);
        if (cur == ref) return DIR_EITHER;
        bool heavyIsZero = cur < ref; // price below reference => currency0 heavier
        if (_beyondCap(cur, ref)) return heavyIsZero ? DIR_ONE_FOR_ZERO : DIR_ZERO_FOR_ONE;
        return heavyIsZero ? DIR_ZERO_FOR_ONE : DIR_ONE_FOR_ZERO;
    }

    /// @notice Quote the gate for one direction without submitting a swap.
    function isAllowed(PoolKey calldata key, bool zeroForOne) external view returns (bool) {
        (uint160 cur, uint160 ref) = _curRef(key);
        bool paysHeavySide = zeroForOne ? cur <= ref : cur >= ref;
        return _beyondCap(cur, ref) ? !paysHeavySide : paysHeavySide;
    }

    /// @notice The currency the pool has grown heavier on relative to its reference price
    /// (currency0 on a tie).
    function heavierCurrency(PoolKey calldata key) external view returns (Currency) {
        (uint160 cur, uint160 ref) = _curRef(key);
        return cur > ref ? key.currency1 : key.currency0;
    }

    function _curRef(PoolKey calldata key) internal view returns (uint160 cur, uint160 ref) {
        PoolId id = key.toId();
        ref = referenceSqrtPriceX96[id];
        (cur,,,) = poolManager.getSlot0(id);
    }

    /// @dev True when the current price is more than MAX_SKEW_BPS (10%) away from the reference
    /// on either side. Works on SQRT prices against precomputed sqrt-band edges, so nothing is
    /// ever squared - safe for any drift. `ref == 0` (no reference yet) reports not-beyond.
    function _beyondCap(uint160 cur, uint160 ref) internal pure returns (bool) {
        if (ref == 0) return false;
        uint256 upper = FullMath.mulDiv(uint256(ref), SQRT_UP_X96, FixedPoint96.Q96);
        uint256 lower = FullMath.mulDiv(uint256(ref), SQRT_DOWN_X96, FixedPoint96.Q96);
        return uint256(cur) > upper || uint256(cur) < lower;
    }

    /// @dev The price ratio (current / reference) in bps of the reference (10_000 = on
    /// reference). Informational only (getters + revert payloads), never gates a swap, so the
    /// squared-ratio math here is out of the swap path.
    function _ratioBps(uint160 cur, uint160 ref) internal pure returns (uint256) {
        if (ref == 0) return BPS;
        uint256 step = FullMath.mulDiv(uint256(cur), BPS, uint256(ref)); // (cur/ref) * BPS
        return FullMath.mulDiv(step, uint256(cur), uint256(ref)); // (cur/ref)^2 * BPS
    }

    /// @dev Absolute deviation of the price ratio from the reference, in bps. Informational.
    function _skewBps(uint160 cur, uint160 ref) internal pure returns (uint256) {
        uint256 r = _ratioBps(cur, ref);
        return r >= BPS ? r - BPS : BPS - r;
    }
}
