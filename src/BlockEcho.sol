// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// BlockEcho - regenerated on the AeonFee base.
// "Your trade only goes through if its amount ends in the same digits as the current block
// number" (last two decimal digits). Mandatory 10 bps AeonFee inherited.
// Flags: BEFORE_SWAP + AFTER_SWAP + returns-delta = 0xC4.

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {AeonFee} from "./AeonFee.sol";

contract BlockEcho is AeonFee {
    /// @notice How many trailing decimal digits must echo. 100 = the last two.
    uint256 public constant ECHO_MODULUS = 100;
    /// @notice Circular tolerance (mod ECHO_MODULUS) the amount suffix may differ from the
    /// block suffix. An exact 0 made the advertised escape untakeable: the `view` helpers are
    /// answered against the sealed head N, but `beforeSwap` runs at execution (N+1 earliest), so
    /// an amount quoted for block N missed by one every time. The window absorbs that off-by-one
    /// (and a tx landing up to ECHO_WINDOW blocks late). The quote helpers below target the
    /// EXECUTION block (block.number + 1) to match.
    uint256 public constant ECHO_WINDOW = 2;

    /// @notice The submitted amount's trailing digits did not echo the block's (within window).
    error AmountEchoMismatch(uint256 submitted, uint256 amountSuffix, uint256 blockSuffix);

    constructor(IPoolManager _pm) AeonFee(_pm) {}

    /// @notice Circular distance between two suffixes on the ring of size ECHO_MODULUS.
    function _suffixDistance(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 d = a > b ? a - b : b - a;
        uint256 other = ECHO_MODULUS - d;
        return d < other ? d : other;
    }

    /// @notice The trailing digits to aim for. A swap submitted now executes next block, so this
    /// targets the EXECUTION block (block.number + 1), not the sealed head.
    function requiredSuffix() public view returns (uint256) {
        return (block.number + 1) % ECHO_MODULUS;
    }

    /// @notice Would a swap of `amount` clear the gate at the execution block (within window)?
    function isAcceptable(uint256 amount) public view returns (bool) {
        return _suffixDistance(amount % ECHO_MODULUS, (block.number + 1) % ECHO_MODULUS) <= ECHO_WINDOW;
    }

    /// @notice ESCAPE 1 - smallest swappable amount >= `target` that clears the gate at the
    /// EXECUTION block (block.number + 1), so the amount is takeable by an off-chain caller.
    function acceptableAmountAtOrAbove(uint256 target) public view returns (uint256) {
        uint256 suffix = (block.number + 1) % ECHO_MODULUS;
        uint256 candidate = target - (target % ECHO_MODULUS) + suffix;
        if (candidate < target) candidate += ECHO_MODULUS;
        if (candidate == 0) candidate = ECHO_MODULUS;
        return candidate;
    }

    /// @notice ESCAPE 2 - blocks (from the execution block) until `amount` first clears the gate
    /// within the window; 0 if it clears at the next block.
    function blocksUntilAcceptable(uint256 amount) public view returns (uint256) {
        uint256 amountSuffix = amount % ECHO_MODULUS;
        uint256 start = (block.number + 1) % ECHO_MODULUS;
        for (uint256 k = 0; k < ECHO_MODULUS; k++) {
            if (_suffixDistance(amountSuffix, (start + k) % ECHO_MODULUS) <= ECHO_WINDOW) return k;
        }
        return 0; // unreachable: a window always contains some block within one period
    }

    function _size(int256 amountSpecified) internal pure returns (uint256) {
        return amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 size = _size(params.amountSpecified);
        uint256 amountSuffix = size % ECHO_MODULUS;
        uint256 blockSuffix = block.number % ECHO_MODULUS;
        if (_suffixDistance(amountSuffix, blockSuffix) > ECHO_WINDOW) {
            revert AmountEchoMismatch(size, amountSuffix, blockSuffix);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
