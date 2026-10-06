// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ComboBreaker - "Buy in a row to build the combo. Every buy in the streak pays less. The seller
// who breaks it pays the streak."
//
// Back-to-back qualifying buys (>= MIN_BUY) grow the combo, and each one pays a smaller game
// fee. A sell of at least breakThreshold (which scales with the streak's volume) breaks the
// streak and pays a breaker fee that grows with the combo. The streak's pot (every game fee
// paid during it, plus the breaker fee) is split among its buyers pro-rata by ETH weight. Weight
// counts in the split only once it is MATURITY_MINUTES old, and a streak cannot be broken before
// its first buy's weight counts (a big sell before then is a chip). A streak with no qualifying
// buy for STREAK_TTL closes at the next interaction with no breaker fee. With no streak live, fees fill a seed pot that
// opens the next streak. Payouts are pull-only per closed streak.
//
// Fees depend only on (direction, ETH amount, pool state), never on hookData. Identity only
// decides who gets paid.
//
// Inherits EthGameHook (ETH-side fee on all four swap shapes) and AeonFee (mandatory 10 bps).
// Flags: 0x20CC.

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {EthGameHook} from "./EthGameHook.sol";

contract ComboBreaker is EthGameHook {
    using PoolIdLibrary for PoolKey;

    /// @notice Default game fee (30 = 0.30%).
    uint256 public constant BASE_BPS = 30;
    /// @notice Buy discount per combo step.
    uint256 public constant BUY_STEP_BPS = 2;
    /// @notice Lowest buy fee (reached at combo 13).
    uint256 public constant BUY_FLOOR_BPS = 4;
    /// @notice Breaker fee added per combo step.
    uint256 public constant BREAK_STEP_BPS = 10;
    /// @notice Highest breaker fee (500 = 5%, reached at combo 47).
    uint256 public constant BREAK_CAP_BPS = 500;
    /// @notice A sell must be this share of the streak's volume to break it (1_000 = 10%).
    uint256 public constant BREAK_PCT_BPS = 1_000;
    /// @notice A streak with no qualifying buy for this long closes with no breaker fee.
    uint256 public constant STREAK_TTL = 24 hours;
    /// @notice Weight bought in minute m (block.timestamp / 60) counts in a streak's split only
    /// if the streak closes in a minute c with c - m > MATURITY_MINUTES, i.e. after at least 10
    /// full minutes. A streak can be broken only once its first buy's weight counts; before that a
    /// big sell is a chip. Stops a trader buying in and breaking in the same block (or opening a
    /// streak and breaking it at once) to take most of a pot others built.
    uint256 public constant MATURITY_MINUTES = 10;
    /// @dev Ring size: one slot per minute that can still be immature at close.
    uint256 internal constant RING = MATURITY_MINUTES + 1;

    /// @notice Smallest buy that grows the combo, in native units (set per chain).
    uint256 public immutable MIN_BUY;
    /// @notice Smallest sell that can break a streak, in native units (set per chain).
    uint256 public immutable MIN_BREAK;

    struct Streak {
        uint128 pot; // ETH in the live streak pot
        uint128 volume; // streakVolume
        uint128 totalWeight; // sum of buyer weights
        uint32 combo;
        uint64 lastBuyAt;
        uint64 id; // global streak id, 0 = no live streak
        uint64 startedAt; // first qualifying buy of the streak
    }

    struct Closed {
        uint128 pot;
        uint128 totalWeight; // mature weight only
        uint32 closeMinute;
    }

    /// @dev Weight bought in one minute. A ring of RING buckets per streak and per player holds
    /// every minute that can still be immature; older slots are overwritten (already mature).
    struct Bucket {
        uint32 minute;
        uint128 weight;
        uint96 fee; // game fees paid by that minute's weight; refunded if immature at close
    }

    mapping(PoolId => Streak) public live;
    mapping(PoolId => uint128) public seedPot;

    mapping(uint64 => Closed) public closed;
    mapping(uint64 => mapping(address => uint128)) public weightOf;
    mapping(uint64 => mapping(address => bool)) public claimed;

    mapping(uint64 => Bucket[RING]) internal _streakBuckets;
    mapping(uint64 => mapping(address => Bucket[RING])) internal _playerBuckets;

    /// @notice Last streak id handed out (ids start at 1).
    uint64 public lastStreakId;

    event ComboUp(
        PoolId indexed id, uint64 indexed streakId, address indexed player, uint32 combo, uint256 ethIn, uint256 feePaid
    );
    event Chip(PoolId indexed id, uint64 indexed streakId, address indexed player, uint256 ethOut, uint256 feePaid);
    event ComboBroken(
        PoolId indexed id, uint64 indexed streakId, address indexed breaker, uint32 combo, uint256 breakerFee, uint256 pot
    );
    event StreakExpired(PoolId indexed id, uint64 indexed streakId, uint32 combo, uint256 pot);
    event Claimed(address indexed player, uint64 indexed streakId, uint256 amount);

    error ZeroMinimum();

    constructor(IPoolManager _pm, uint256 minBuy, uint256 minBreak) EthGameHook(_pm) {
        if (minBuy < MIN_FLOOR || minBreak < MIN_FLOOR) revert ZeroMinimum();
        MIN_BUY = minBuy;
        MIN_BREAK = minBreak;
    }

    // ---------------------------------------------------------------------------------------
    // Fee tiers
    // ---------------------------------------------------------------------------------------

    /// @notice Fee for the next qualifying buy at `combo`: max(BUY_FLOOR_BPS, BASE_BPS - combo * BUY_STEP_BPS).
    function buyBps(uint256 combo) public pure returns (uint256) {
        uint256 discount = combo * BUY_STEP_BPS;
        if (discount >= BASE_BPS - BUY_FLOOR_BPS) return BUY_FLOOR_BPS;
        return BASE_BPS - discount;
    }

    /// @notice Breaker fee at `combo`: min(BREAK_CAP_BPS, BASE_BPS + combo * BREAK_STEP_BPS).
    function breakBps(uint256 combo) public pure returns (uint256) {
        uint256 bps = BASE_BPS + combo * BREAK_STEP_BPS;
        return bps > BREAK_CAP_BPS ? BREAK_CAP_BPS : bps;
    }

    function _breakThreshold(uint256 volume) internal view returns (uint256) {
        uint256 bar = _bps(volume, BREAK_PCT_BPS);
        return bar > MIN_BREAK ? bar : MIN_BREAK;
    }

    // ---------------------------------------------------------------------------------------
    // Game
    // ---------------------------------------------------------------------------------------

    function _beforeGame(PoolKey calldata key) internal override {
        _expire(key.toId());
    }

    function _onSwap(address sender, PoolKey calldata key, bool isBuy, uint256 ethAmount, bytes calldata hookData)
        internal
        override
        returns (uint256 fee)
    {
        PoolId id = key.toId();
        Streak storage s = live[id];
        uint32 combo = s.combo;

        if (isBuy) {
            if (ethAmount < MIN_BUY) {
                // Small buy: base fee, no weight, combo unchanged.
                fee = _bps(ethAmount, BASE_BPS);
                _feed(id, s, combo, fee);
                return fee;
            }

            fee = _bps(ethAmount, buyBps(combo));
            address player = _resolvePlayer(sender, hookData);
            uint64 sid = s.id;
            uint128 pot = s.pot;
            if (combo == 0) {
                // Open a new streak with the seed pot.
                sid = ++lastStreakId;
                s.id = sid;
                s.startedAt = uint64(block.timestamp);
                pot = seedPot[id];
                seedPot[id] = 0;
            }
            uint128 w = _u128(ethAmount);
            combo += 1;
            s.combo = combo;
            s.volume += w;
            s.totalWeight += w;
            s.lastBuyAt = uint64(block.timestamp);
            s.pot = pot + _u128(fee);
            weightOf[sid][player] += w;
            uint32 m = _minute(block.timestamp);
            if (fee > type(uint96).max) revert FeeOverflow();
            _addBucket(_streakBuckets[sid], m, w, uint96(fee));
            _addBucket(_playerBuckets[sid][player], m, w, uint96(fee));
            emit ComboUp(id, sid, player, combo, ethAmount, fee);
            return fee;
        }

        // Sell.
        if (combo == 0) {
            fee = _bps(ethAmount, BASE_BPS);
            seedPot[id] += _u128(fee);
            return fee;
        }

        address seller = _resolvePlayer(sender, hookData);
        if (ethAmount < _breakThreshold(s.volume) || !_mature(_minute(s.startedAt), _minute(block.timestamp))) {
            // Chip damage (too small, or the streak is too young to break): base fee into the
            // streak pot, streak survives.
            fee = _bps(ethAmount, BASE_BPS);
            s.pot += _u128(fee);
            emit Chip(id, s.id, seller, ethAmount, fee);
            return fee;
        }

        // COMBO BREAKER.
        fee = _bps(ethAmount, breakBps(combo));
        uint64 streakId = s.id;
        uint256 finalPot = uint256(s.pot) + fee;
        // No forfeit: no identity a swap carries proves who the breaker is (hookData and
        // msgSender() are caller-chosen, tx.origin can be borrowed by any contract the player
        // calls), so taking weight away would let an attacker strip someone else's share. A
        // breaker who also bought gets back only their pro-rata share of their own fee.
        _close(id, streakId, s.totalWeight, finalPot);
        delete live[id];
        emit ComboBroken(id, streakId, seller, combo, fee, finalPot);
    }

    /// @dev Route a non-scoring fee: into the live streak pot, or the seed pot if none.
    function _feed(PoolId id, Streak storage s, uint32 combo, uint256 fee) internal {
        if (fee == 0) return;
        if (combo == 0) seedPot[id] += _u128(fee);
        else s.pot += _u128(fee);
    }

    /// @dev Record a closed streak's split over mature weight only. Weight younger than
    /// MATURITY_MINUTES gets no share of the pot, but its buyers get their own game fees back,
    /// so a timed break cannot hand young buyers' fees to whoever happens to be mature.
    function _close(PoolId id, uint64 streakId, uint128 totalWeight, uint256 pot) internal {
        uint32 c = _minute(block.timestamp);
        (uint128 immW, uint256 immFee) = _immature(_streakBuckets[streakId], c);
        uint128 mature = totalWeight - immW;
        if (mature == 0) {
            // Unreachable by the break rule (the first buy is mature) and by expiry (all weight is
            // a day old); kept so a pot can never be stranded.
            seedPot[id] += _u128(pot);
            return;
        }
        // Immature buyers get their own fees back (claimable); only the rest is split.
        closed[streakId] = Closed({pot: _u128(pot - immFee), totalWeight: mature, closeMinute: c});
    }

    function _minute(uint256 ts) internal pure returns (uint32) {
        return uint32(ts / 60);
    }

    /// @dev Weight bought in minute `m` counts at close minute `c`.
    function _mature(uint32 m, uint32 c) internal pure returns (bool) {
        return uint256(c) - m > MATURITY_MINUTES;
    }

    function _addBucket(Bucket[RING] storage ring, uint32 m, uint128 w, uint96 fee) internal {
        Bucket storage b = ring[m % RING];
        // A slot holding an older minute is at least RING minutes old, so already mature.
        if (b.minute != m) {
            b.minute = m;
            b.weight = w;
            b.fee = fee;
        } else {
            b.weight += w;
            b.fee += fee;
        }
    }

    /// @dev Weight in `ring` still immature at close minute `c`.
    function _immature(Bucket[RING] storage ring, uint32 c) internal view returns (uint128 sum, uint256 fees) {
        for (uint256 i; i < RING; ++i) {
            Bucket storage b = ring[i];
            if (b.weight != 0 && !_mature(b.minute, c)) {
                sum += b.weight;
                fees += b.fee;
            }
        }
    }

    /// @dev Close a timed-out streak with no breaker fee.
    function _expire(PoolId id) internal {
        Streak storage s = live[id];
        if (s.combo == 0 || block.timestamp <= uint256(s.lastBuyAt) + STREAK_TTL) return;
        uint64 streakId = s.id;
        uint32 combo = s.combo;
        uint128 pot = s.pot;
        _close(id, streakId, s.totalWeight, pot);
        delete live[id];
        emit StreakExpired(id, streakId, combo, pot);
    }

    // ---------------------------------------------------------------------------------------
    // External
    // ---------------------------------------------------------------------------------------

    /// @notice Close a timed-out streak without swapping. No-op otherwise.
    function poke(PoolKey calldata key) external {
        _expire(key.toId());
    }

    /// @notice Claim your share of closed streaks. Skips streaks with nothing owed.
    function claim(uint64[] calldata streakIds) external nonReentrant {
        uint256 total;
        for (uint256 i; i < streakIds.length; ++i) {
            uint64 sid = streakIds[i];
            uint256 amount = claimable(sid, msg.sender);
            if (amount == 0) continue;
            claimed[sid][msg.sender] = true;
            total += amount;
            emit Claimed(msg.sender, sid, amount);
        }
        if (total == 0) revert NothingToClaim();
        _sendEth(msg.sender, total);
    }

    /// @notice ETH `player` can claim from a closed streak. 0 for a live streak.
    function claimable(uint64 streakId, address player) public view returns (uint256) {
        if (claimed[streakId][player]) return 0;
        Closed memory c = closed[streakId];
        if (c.totalWeight == 0) return 0;
        (uint128 immW, uint256 immFee) = _immature(_playerBuckets[streakId][player], c.closeMinute);
        uint256 w = weightOf[streakId][player] - immW;
        return (uint256(c.pot) * w) / c.totalWeight + immFee;
    }

    /// @notice What the next swap faces on this pool (a timed-out streak counts as closed).
    function preview(PoolId id)
        external
        view
        returns (uint32 combo, uint256 pot, uint256 nextBuyBps, uint256 breakThreshold, uint256 breakBps_)
    {
        Streak memory s = live[id];
        if (s.combo == 0 || block.timestamp > uint256(s.lastBuyAt) + STREAK_TTL) {
            return (0, seedPot[id], buyBps(0), _breakThreshold(0), breakBps(0));
        }
        return (s.combo, s.pot, buyBps(s.combo), _breakThreshold(s.volume), breakBps(s.combo));
    }
}
