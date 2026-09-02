// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// TailTwins - regenerated on the AeonFee base.
// "Your trade must match the pool's current price in its last digit - and that price shifts
// with every swap." Compares slot0.sqrtPriceX96's low byte to |amountSpecified|'s low byte.
// Mandatory 10 bps AeonFee inherited. Flags: BEFORE_SWAP + AFTER_SWAP + returns-delta = 0xC4.

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {AeonFee} from "./AeonFee.sol";

contract TailTwins is AeonFee {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice The "tail" both sides are compared on: the low byte.
    uint256 public constant TAIL_MASK = 0xff;
    /// @notice One more than the widest tail - the period of the escape search.
    uint256 public constant TAIL_PERIOD = 0x100;
    /// @notice Circular tolerance (in tail units) the submitted tail may differ from the live
    /// price tail. An exact 0 was a self-DoS: the price tail re-randomises on every swap, so a
    /// pre-quoted exact-match amount failed the moment any other swap moved the price (a second
    /// concurrent trader cleared 0/100). A band lets a quote survive small drift between quoting
    /// and execution. This is a best-effort game, not a guarantee: heavy contention can still
    /// push the live tail past the band. For a hard guarantee a caller must commit its own price.
    uint256 public constant TAIL_TOLERANCE = 16;

    /// @notice The submitted size's low byte was not within TAIL_TOLERANCE of the live price's.
    error TailMismatch(uint256 submitted, uint256 amountTail, uint256 priceTail);
    /// @notice Views fail closed on an uninitialized pool rather than mislead a router.
    error PoolNotInitialized(PoolId id);

    constructor(IPoolManager _pm) AeonFee(_pm) {}

    /// @notice The pool's live sqrt price, straight from slot0.
    function currentSqrtPriceX96(PoolKey calldata key) public view returns (uint160 sqrtPriceX96) {
        PoolId id = key.toId();
        (sqrtPriceX96,,,) = poolManager.getSlot0(id);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized(id);
    }

    /// @notice The low byte every swap size must equal, for THIS pool right now.
    function requiredTail(PoolKey calldata key) public view returns (uint256) {
        return uint256(currentSqrtPriceX96(key)) & TAIL_MASK;
    }

    /// @notice Circular distance between two tails on the ring of size TAIL_PERIOD.
    function _tailDistance(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 d = a > b ? a - b : b - a;
        uint256 other = TAIL_PERIOD - d;
        return d < other ? d : other;
    }

    /// @notice Would a swap of `amount` clear the gate right now (within TAIL_TOLERANCE)?
    function isAcceptable(PoolKey calldata key, uint256 amount) public view returns (bool) {
        return _tailDistance(amount & TAIL_MASK, uint256(currentSqrtPriceX96(key)) & TAIL_MASK) <= TAIL_TOLERANCE;
    }

    /// @notice THE ESCAPE - smallest size >= `target` that clears the gate at the current price.
    function acceptableAmountAtOrAbove(PoolKey calldata key, uint256 target) public view returns (uint256) {
        uint256 tail = uint256(currentSqrtPriceX96(key)) & TAIL_MASK;
        uint256 candidate = target - (target & TAIL_MASK) + tail;
        if (candidate < target) candidate += TAIL_PERIOD;
        if (candidate == 0) candidate = TAIL_PERIOD;
        return candidate;
    }

    function _size(int256 amountSpecified) internal pure returns (uint256) {
        return amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 size = _size(params.amountSpecified);
        uint256 amountTail = size & TAIL_MASK;
        uint256 priceTail = uint256(currentSqrtPriceX96(key)) & TAIL_MASK;
        if (_tailDistance(amountTail, priceTail) > TAIL_TOLERANCE) revert TailMismatch(size, amountTail, priceTail);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
