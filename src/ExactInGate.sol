// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ExactInGate — regenerated on the AeonFee base.
// "Only lets you trade by spending an exact amount in; asking for an exact amount out is blocked."
// amountSpecified < 0 = exact input (allowed); > 0 = exact output (rejected). Mandatory 10 bps
// AeonFee inherited. Flags: BEFORE_SWAP + AFTER_SWAP + returns-delta = 0xC4.

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {AeonFee} from "./AeonFee.sol";

contract ExactInGate is AeonFee {
    using PoolIdLibrary for PoolKey;

    /// @notice Exact-input swaps admitted, per pool.
    mapping(PoolId => uint256) public exactInCount;

    /// @notice Raised when a swap asks for an exact OUTPUT amount.
    error ExactOutputBlocked();

    event ExactInAdmitted(PoolId indexed id, address indexed sender, int256 amountSpecified, uint256 count);

    constructor(IPoolManager _pm) AeonFee(_pm) {}

    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (params.amountSpecified > 0) revert ExactOutputBlocked();

        PoolId id = key.toId();
        uint256 count = exactInCount[id] + 1;
        exactInCount[id] = count;
        emit ExactInAdmitted(id, sender, params.amountSpecified, count);

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
