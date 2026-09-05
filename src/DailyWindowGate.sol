// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// SOURCE VERIFIED ON THE CHAIN EXPLORER - vendored here by scripts/sync_source.py
// (comment long-dashes normalized to hyphens; no code or logic change).
//   base (8453): 0x752B180116f5110dCBEa9564a43ACBEF82ebc080
// NOTE: this hook does NOT inherit AeonFee, so it takes no 10 bps protocol
// fee onchain, unlike the AeonFee reference hooks in this dir.

// FREEFORM hook scaffold. In freeform mode the deploy-uni-hook skill rewrites the
// AEON:BODY region with callbacks generated from the user's prompt.
//
// Rules the generator MUST keep:
//   - Contract name stays `Hook` and constructor stays `constructor(IPoolManager)`
//     (the deploy script imports `Hook` by name).
//   - Every callback uses the EXACT IHooks signature, carries `onlyPoolManager`,
//     and returns the right selector (e.g. `IHooks.beforeSwap.selector`).
//   - Flags are AUTO-DERIVED from which callbacks exist (see hook-deploy.sh).
//     For a return-delta callback, also list it in hook.env HOOK_RETURNS_DELTA.
//   - A dynamic-fee hook sets HOOK_POOL_FEE=dynamic in hook.env and returns
//     `fee | LPFeeLibrary.OVERRIDE_FEE_FLAG` from beforeSwap.
//   - Labs auto-route forbids 0x91, beforeSwapReturnsDelta, afterSwapReturnsDelta,
//     and dynamicFees. A take() is allowlist-only. Games must succeed with empty
//     hookData; do not revert a vanilla exact-in; do not key state off sender.
//   - Fee take: magnitude of unspecified (exact-in AND exact-out). Widen to int256
//     before abs. take() to an immutable recipient, never address(this), no withdraw.
//   - Gates: no exact-match on moving state, no raw amountSpecified cap, no
//     balanceOf(poolManager). Helpers must match execution-time state.
//
// All commonly-needed imports/usings are here so generated bodies compile as-is.

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract Hook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;

    IPoolManager public immutable poolManager;

    error NotPoolManager();

    constructor(IPoolManager _pm) {
        poolManager = _pm;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    // --- AEON:BODY START (freeform: daily 10-minute trading-window gate) ---
    // Swaps clear ONLY inside a fixed 10-minute window each UTC day:
    //   [00:00:00, 00:10:00) UTC  - inclusive of the open, exclusive of the close.
    // Every other second of the day reverts the swap. The gate reads block.timestamp
    // AT EXECUTION (no cached value, no `view` helper answered at a stale head), so it
    // is evaluated against the block the swap actually lands in - the window can never
    // drift by one block. Because WINDOW_OPEN is 0 the second-of-day is unsigned and
    // always >= open, so the only real bound is the exclusive close at 600s.
    //
    // Only `beforeSwap` is implemented, so the auto-derived flag set is BEFORE_SWAP
    // (0x80) and NOTHING else: the PoolManager never invokes an add/remove-liquidity
    // callback on this hook, so liquidity provision and withdrawal are completely
    // ungated - an LP can always enter or exit, in or out of the window, and can never
    // be locked in. The callback returns a ZERO BeforeSwapDelta and a 0 fee override,
    // so it never touches the token ledger and takes no custody.

    uint256 public constant DAY = 86400; // seconds per UTC day
    uint256 public constant WINDOW_OPEN = 0; // 00:00:00 UTC, inclusive
    uint256 public constant WINDOW_CLOSE = 600; // 00:10:00 UTC, exclusive (10 minutes)

    error TradingWindowClosed(uint256 secondsIntoDay);

    event SwapCleared(PoolId indexed id, uint256 secondsIntoDay);

    /// @notice True iff timestamp `ts` falls inside today's [00:00:00, 00:10:00) UTC
    /// trading window. Pure view of the same rule `beforeSwap` enforces at execution.
    function isTradingOpen(uint256 ts) public pure returns (bool) {
        uint256 secondsIntoDay = ts % DAY;
        return secondsIntoDay >= WINDOW_OPEN && secondsIntoDay < WINDOW_CLOSE;
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 secondsIntoDay = block.timestamp % DAY;
        if (secondsIntoDay < WINDOW_OPEN || secondsIntoDay >= WINDOW_CLOSE) {
            revert TradingWindowClosed(secondsIntoDay);
        }
        emit SwapCleared(key.toId(), secondsIntoDay);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
    // --- AEON:BODY END ---
}
