// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// CapGate — regenerated on the AeonFee base.
// "Rejects any trade above a fixed size cap before it runs - the pool fills small swaps only."
// beforeSwap reverts TradeTooLarge when |amountSpecified| exceeds MAX_TRADE; the mandatory
// 10 bps AeonFee is inherited. Flags: BEFORE_SWAP + AFTER_SWAP + returns-delta = 0xC4.

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {AeonFee} from "./AeonFee.sol";

contract CapGate is AeonFee {
    /// @notice Max absolute swap size the pool accepts (in the swap's specified-currency units).
    uint256 public constant MAX_TRADE = 100e18;

    error TradeTooLarge(uint256 size, uint256 cap);

    constructor(IPoolManager _pm) AeonFee(_pm) {}

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 size =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        if (size > MAX_TRADE) revert TradeTooLarge(size, MAX_TRADE);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
