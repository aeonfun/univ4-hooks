// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// NoOp — regenerated on the AeonFee base.
// Waves every trade through untouched; the mandatory 10 bps AeonFee is inherited.
// Flags: BEFORE_SWAP (emit) + AFTER_SWAP + AFTER_SWAP_RETURNS_DELTA (forced) = 0xC4.

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {AeonFee} from "./AeonFee.sol";

contract NoOp is AeonFee {
    event BeforeSwapFired(address indexed sender, bool zeroForOne, int256 amountSpecified);

    constructor(IPoolManager _pm) AeonFee(_pm) {}

    function beforeSwap(address sender, PoolKey calldata, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        emit BeforeSwapFired(sender, params.zeroForOne, params.amountSpecified);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
