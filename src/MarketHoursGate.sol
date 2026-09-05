// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// SOURCE VERIFIED ON THE CHAIN EXPLORER - vendored here by scripts/sync_source.py
// (comment long-dashes normalized to hyphens; no code or logic change).
//   base (8453): 0x82086452Fe75Cb217F44Cf8c33af638bf9018080
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

    // --- AEON:BODY START (freeform: replace with callbacks from the prompt) ---
    // Market-hours gate: swaps only clear during the US regular session
    // (09:30-16:00 America/New_York, Monday-Friday). Every other window reverts.
    // beforeSwap reads block.timestamp directly at execution time (never a
    // cached/off-chain value), so the check always reflects the block that
    // actually executes the swap. Auto-derived flag for this hook: BEFORE_SWAP (0x80).

    error MarketClosed();

    uint256 private constant SECONDS_PER_DAY = 1 days;
    uint256 private constant OPEN_SECONDS = 9 hours + 30 minutes; // 09:30 local
    uint256 private constant CLOSE_SECONDS = 16 hours; // 16:00 local

    /// @notice True if `timestamp` falls inside the US market session.
    function isMarketOpen(uint256 timestamp) public pure returns (bool) {
        uint256 daysSinceEpoch = timestamp / SECONDS_PER_DAY;
        uint256 utcSecondsOfDay = timestamp % SECONDS_PER_DAY;
        uint256 utcDow = (daysSinceEpoch + 4) % 7; // 0=Sunday .. 6=Saturday

        int256 offsetHours = _easternOffsetHours(daysSinceEpoch);
        int256 localSeconds = int256(utcSecondsOfDay) + offsetHours * int256(1 hours);

        uint256 localDow = utcDow;
        if (localSeconds < 0) {
            localSeconds += int256(SECONDS_PER_DAY);
            localDow = (utcDow + 6) % 7; // ET is still the previous calendar day
        } else if (localSeconds >= int256(SECONDS_PER_DAY)) {
            localSeconds -= int256(SECONDS_PER_DAY);
            localDow = (utcDow + 1) % 7; // ET has already rolled to the next day
        }

        if (localDow == 0 || localDow == 6) return false; // Sunday / Saturday

        uint256 localSecondsOfDay = uint256(localSeconds);
        return localSecondsOfDay >= OPEN_SECONDS && localSecondsOfDay < CLOSE_SECONDS;
    }

    /// @dev US Eastern UTC offset (-4 during EDT, -5 during EST) for the given day.
    /// DST: 2nd Sunday of March 02:00 local -> 1st Sunday of November 02:00 local.
    /// The offset is resolved from the UTC calendar date; the +/-1 day imprecision
    /// this can cause sits right at the 2am transition, hours outside the trading
    /// window this gate cares about, so it never affects the open/closed verdict.
    function _easternOffsetHours(uint256 daysSinceEpoch) private pure returns (int256) {
        (int256 year, int256 month, int256 day) = _civilFromDays(int256(daysSinceEpoch));
        if (month < 3 || month > 11) return -5; // Dec-Feb: always EST
        if (month > 3 && month < 11) return -4; // Apr-Oct: always EDT
        if (month == 3) {
            int256 secondSunday = _nthSundayOfMonth(year, 3, 2);
            return day >= secondSunday ? int256(-4) : int256(-5);
        }
        int256 firstSunday = _nthSundayOfMonth(year, 11, 1);
        return day < firstSunday ? int256(-4) : int256(-5);
    }

    /// @dev Day-of-month of the n-th Sunday of (year, month).
    function _nthSundayOfMonth(int256 year, int256 month, int256 n) private pure returns (int256) {
        int256 firstDayEpoch = _daysFromCivil(year, month, 1);
        int256 dow = ((firstDayEpoch + 4) % 7 + 7) % 7; // 0=Sunday
        int256 firstSunday = dow == 0 ? int256(1) : int256(8) - dow;
        return firstSunday + (n - 1) * 7;
    }

    /// @dev Howard Hinnant's civil_from_days: days-since-epoch -> (year, month, day).
    function _civilFromDays(int256 z) private pure returns (int256 year, int256 month, int256 day) {
        z += 719468;
        int256 era = (z >= 0 ? z : z - 146096) / 146097;
        int256 doe = z - era * 146097; // [0, 146096]
        int256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365; // [0, 399]
        int256 y = yoe + era * 400;
        int256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
        int256 mp = (5 * doy + 2) / 153; // [0, 11]
        day = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
        month = mp < 10 ? mp + 3 : mp - 9; // [1, 12]
        year = y + (month <= 2 ? int256(1) : int256(0));
    }

    /// @dev Inverse of _civilFromDays: (year, month, day) -> days-since-epoch.
    function _daysFromCivil(int256 y, int256 m, int256 d) private pure returns (int256) {
        y -= (m <= 2 ? int256(1) : int256(0));
        int256 era = (y >= 0 ? y : y - 399) / 400;
        int256 yoe = y - era * 400; // [0, 399]
        int256 doy = (153 * (m + (m > 2 ? int256(-3) : int256(9))) + 2) / 5 + d - 1; // [0, 365]
        int256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy; // [0, 146096]
        return era * 146097 + doe - 719468;
    }

    function beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!isMarketOpen(block.timestamp)) revert MarketClosed();
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
    // --- AEON:BODY END ---
}
