// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// DynamicFee — regenerated on the AeonFee base.
// "Charges a higher swap fee when the market gets choppy and eases off when it calms down."
// beforeSwap overrides the LP fee from the previous swap's tick move; the mandatory 10 bps
// AeonFee is inherited on top. The pool MUST be initialized with fee = DYNAMIC_FEE_FLAG.
// Flags: AFTER_INITIALIZE + BEFORE_SWAP + AFTER_SWAP + returns-delta = 0x10C4.

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {AeonFee} from "./AeonFee.sol";

contract DynamicFee is AeonFee {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // fee parameters (hundredths of a bip; 3000 = 0.30%)
    uint24 public constant BASE_FEE = 3000;
    uint24 public constant MIN_FEE = 500;
    uint24 public constant MAX_FEE = 50000;
    uint24 public constant FEE_PER_TICK = 100;

    mapping(PoolId => int24) public tickAtSwapStart;
    mapping(PoolId => uint256) public lastMove;

    event DynamicFeeApplied(PoolId indexed id, uint256 lastMove, uint24 feeApplied);

    constructor(IPoolManager _pm) AeonFee(_pm) {}

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        external
        onlyPoolManager
        returns (bytes4)
    {
        tickAtSwapStart[key.toId()] = tick;
        return IHooks.afterInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        (, int24 curTick,,) = poolManager.getSlot0(id);
        tickAtSwapStart[id] = curTick;

        uint24 fee = _computeFee(id);
        emit DynamicFeeApplied(id, lastMove[id], fee);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // Post-swap logic runs AFTER the mandatory protocol fee (base AeonFee.afterSwap).
    // Tracks the tick move for the next swap's dynamic fee. Returns no extra delta.
    function _afterSwapExtra(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (int128) {
        PoolId id = key.toId();
        (, int24 newTick,,) = poolManager.getSlot0(id);
        int256 diff = int256(newTick) - int256(tickAtSwapStart[id]);
        lastMove[id] = diff >= 0 ? uint256(diff) : uint256(-diff);
        return int128(0);
    }

    function _computeFee(PoolId id) internal view returns (uint24) {
        uint256 fee = uint256(BASE_FEE) + lastMove[id] * uint256(FEE_PER_TICK);
        if (fee < MIN_FEE) return MIN_FEE;
        if (fee > MAX_FEE) return MAX_FEE;
        return uint24(fee);
    }
}
