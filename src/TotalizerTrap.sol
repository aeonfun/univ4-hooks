// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// TotalizerTrap — regenerated on the AeonFee base.
// "The pool keeps a running total of everything traded. If your swap would land it on a
// multiple of 11, it's blocked." Mandatory 10 bps AeonFee inherited.
// Flags: BEFORE_SWAP + AFTER_SWAP + returns-delta = 0xC4.

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {AeonFee} from "./AeonFee.sol";

contract TotalizerTrap is AeonFee {
    using PoolIdLibrary for PoolKey;

    /// @notice The trap modulus. Exactly one residue in eleven is forbidden, forever.
    uint256 public constant TRAP_MODULUS = 11;

    /// @notice The odometer: cumulative nominal swap size, per pool. Monotone increasing.
    mapping(PoolId => uint256) public totalOf;

    /// @notice This swap would land the odometer on a multiple of TRAP_MODULUS.
    error TotalizerTripped(uint256 submitted, uint256 totalBefore, uint256 wouldBe);

    constructor(IPoolManager _pm) AeonFee(_pm) {}

    /// @notice The odometer for THIS pool right now.
    function cumulativeTotal(PoolKey calldata key) public view returns (uint256) {
        return totalOf[key.toId()];
    }

    /// @notice Would a swap of `amount` trip the trap right now?
    function wouldTrip(PoolKey calldata key, uint256 amount) public view returns (bool) {
        return (totalOf[key.toId()] + amount) % TRAP_MODULUS == 0;
    }

    /// @notice The unique smallest positive size that trips right now.
    function trippingAmount(PoolKey calldata key) public view returns (uint256) {
        return TRAP_MODULUS - (totalOf[key.toId()] % TRAP_MODULUS);
    }

    /// @notice THE ESCAPE — smallest swappable size >= `target` that clears the trap now.
    function acceptableAmountAtOrAbove(PoolKey calldata key, uint256 target) public view returns (uint256) {
        uint256 total = totalOf[key.toId()];
        uint256 candidate = target == 0 ? 1 : target;
        if ((total + candidate) % TRAP_MODULUS == 0) candidate += 1;
        return candidate;
    }

    function _size(int256 amountSpecified) internal pure returns (uint256) {
        return amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        uint256 size = _size(params.amountSpecified);
        uint256 totalBefore = totalOf[id];
        uint256 wouldBe = totalBefore + size;
        if (wouldBe % TRAP_MODULUS == 0) revert TotalizerTripped(size, totalBefore, wouldBe);
        totalOf[id] = wouldBe;
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
