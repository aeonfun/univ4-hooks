// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// SOURCE VERIFIED ON THE CHAIN EXPLORER - vendored here by scripts/sync_source.py
// (comment long-dashes normalized to hyphens; no code or logic change).
// Its deps are the verified build's own files under src/vendor/TeamWar/, imports rewritten to them.
//   base (8453): 0x8DfA52588d4423e96a93E6923BdE3240af6320cC
//   robinhood (4663): 0x9C657d8637E98b9299Be6e4e23d52fD2713aA0Cc

// TeamWar - "Pick red or blue. Trade for your team. Each week the team with more volume takes the
// losers' pot."
//
// Players join RED (1) or BLUE (2) per pool with joinTeam(), the only way to join. A member's swap pays GAME_BPS of its ETH leg into their team's pot for the current
// week and adds its ETH size to the team's and the player's weekly volume. After the week ends
// (Monday 00:00 UTC) the team with more volume splits both pots pro-rata by member volume. A tie
// returns each team its own pot; a one-sided week returns the only team its own pot. Players who
// never join pay no game fee, and a swap whose player is known only from tx.origin (no hookData
// address, no router msgSender()) is treated as a non-member's. Switching team takes effect next week. Settlement is lazy (first
// swap of a later week, or anyone calls finalize) and claims are pull-only per (pool, week).
//
// Inherits EthGameHook (ETH-side fee on all four swap shapes) and AeonFee (mandatory 10 bps).
// Flags: 0x20CC.

import {IPoolManager} from "./vendor/TeamWar/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "./vendor/TeamWar/lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "./vendor/TeamWar/lib/v4-core/src/types/PoolId.sol";

import {EthGameHook} from "./vendor/TeamWar/src/EthGameHook.sol";

contract TeamWar is EthGameHook {
    using PoolIdLibrary for PoolKey;

    uint8 public constant NONE = 0;
    uint8 public constant RED = 1;
    uint8 public constant BLUE = 2;
    uint8 public constant TIE = 3;

    /// @notice Game fee on a team swap's ETH leg (25 = 0.25%).
    uint256 public constant GAME_BPS = 25;
    /// @notice Unix time 0 is a Thursday; +4 days puts week boundaries on Monday 00:00 UTC.
    uint256 public constant WEEK_OFFSET = 4 days;

    /// @notice Swaps below this pay the game fee but add no volume (native units, per chain).
    uint256 public immutable MIN_SWAP;

    struct Member {
        uint8 team;
        uint8 nextTeam;
        uint32 nextFromWeek;
    }

    struct War {
        uint128[3] pot; // index 1 = red, 2 = blue
        uint128[3] volume;
        uint8 winner; // 0 = not final, 1 red, 2 blue, 3 tie
    }

    mapping(PoolId => mapping(address => Member)) public members;
    mapping(PoolId => mapping(uint32 => War)) internal _wars;
    mapping(PoolId => mapping(uint32 => mapping(address => uint128))) public volOf;
    mapping(PoolId => mapping(uint32 => mapping(address => uint8))) public teamOf;
    mapping(PoolId => mapping(uint32 => mapping(address => bool))) public claimed;

    /// @dev Last week that took a game fee on each pool. Lazy finalize looks at this week only.
    mapping(PoolId => uint32) public lastActiveWeek;
    mapping(PoolId => bool) public isPool;

    event Joined(PoolId indexed id, address indexed player, uint8 team, uint32 fromWeek);
    event Scored(
        PoolId indexed id, uint32 indexed week, address indexed player, uint8 team, uint256 ethVolume, uint256 feePaid
    );
    event WarFinalized(
        PoolId indexed id, uint32 indexed week, uint8 winner, uint256 redVolume, uint256 blueVolume, uint256 prize
    );
    event Claimed(PoolId indexed id, uint32 indexed week, address indexed player, uint256 amount);

    error BadTeam();
    error UnknownPool();
    error WeekNotOver();
    error MinTooLow();

    constructor(IPoolManager _pm, uint256 minSwap) EthGameHook(_pm) {
        if (minSwap < MIN_FLOOR) revert MinTooLow();
        MIN_SWAP = minSwap;
    }

    // ---------------------------------------------------------------------------------------
    // Weeks and teams
    // ---------------------------------------------------------------------------------------

    function currentWeek() public view returns (uint32) {
        return uint32((block.timestamp - WEEK_OFFSET) / 1 weeks);
    }

    function _weekEnd(uint32 week) internal pure returns (uint256) {
        return (uint256(week) + 1) * 1 weeks + WEEK_OFFSET;
    }

    /// @notice The team `player` plays for in `week` on pool `id` (0 = not playing).
    function teamFor(PoolId id, address player, uint32 week) public view returns (uint8) {
        Member memory m = members[id][player];
        if (m.nextTeam != NONE && week >= m.nextFromWeek) return m.nextTeam;
        return m.team;
    }

    /// @notice Join a team, or switch team from next week. Works with any router afterwards.
    function joinTeam(PoolKey calldata key, uint8 team) external {
        if (team != RED && team != BLUE) revert BadTeam();
        PoolId id = key.toId();
        if (!isPool[id]) revert UnknownPool();
        _join(id, msg.sender, team);
    }

    function _join(PoolId id, address player, uint8 team) internal {
        uint32 week = currentWeek();
        Member storage m = members[id][player];

        // Fold a switch that has already taken effect into `team`.
        if (m.nextTeam != NONE && week >= m.nextFromWeek) {
            m.team = m.nextTeam;
            m.nextTeam = NONE;
            m.nextFromWeek = 0;
        }

        if (m.team == NONE) {
            // First join applies right away.
            m.team = team;
            emit Joined(id, player, team, week);
        } else if (m.team == team) {
            // Re-picking the current team cancels a pending switch.
            if (m.nextTeam != NONE) {
                m.nextTeam = NONE;
                m.nextFromWeek = 0;
                emit Joined(id, player, team, week);
            }
        } else {
            // Switch: play the rest of this week on the old team.
            m.nextTeam = team;
            m.nextFromWeek = week + 1;
            emit Joined(id, player, team, week + 1);
        }
    }

    // ---------------------------------------------------------------------------------------
    // Game
    // ---------------------------------------------------------------------------------------

    function _onInitialize(PoolKey calldata key) internal override {
        PoolId id = key.toId();
        isPool[id] = true;
        lastActiveWeek[id] = currentWeek();
    }

    function _beforeGame(PoolKey calldata key) internal override {
        PoolId id = key.toId();
        uint32 last = lastActiveWeek[id];
        if (last < currentWeek() && _wars[id][last].winner == NONE) _finalize(id, last);
    }

    function _onSwap(address sender, PoolKey calldata key, bool, uint256 ethAmount, bytes calldata hookData)
        internal
        override
        returns (uint256 fee)
    {
        PoolId id = key.toId();
        uint32 week = currentWeek();

        // Player from hookData, else the router's msgSender(). No tx.origin fallback: tx.origin is
        // whoever sent the transaction, not necessarily whoever is swapping (a vault, keeper or
        // relayed call), so charging a game fee on it would tax a swap that never chose to play.
        address player = _hookDataPlayer(hookData);
        if (player == address(0)) player = _routerMsgSender(sender);
        if (player == address(0)) return 0;

        // Joining happens only in joinTeam(), where msg.sender is the consent.
        uint8 team = teamFor(id, player, week);
        if (team == NONE) return 0;

        War storage w = _wars[id][week];
        fee = _bps(ethAmount, GAME_BPS);
        w.pot[team] += _u128(fee);

        uint256 scored;
        if (ethAmount >= MIN_SWAP) {
            scored = ethAmount;
            uint128 v = _u128(ethAmount);
            w.volume[team] += v;
            volOf[id][week][player] += v;
            teamOf[id][week][player] = team;
        }
        if (lastActiveWeek[id] != week) lastActiveWeek[id] = week;
        emit Scored(id, week, player, team, scored, fee);
    }

    function _finalize(PoolId id, uint32 week) internal {
        War storage w = _wars[id][week];
        uint256 redVol = w.volume[RED];
        uint256 blueVol = w.volume[BLUE];
        uint256 redPot = w.pot[RED];
        uint256 bluePot = w.pot[BLUE];
        // Dead week: nothing to settle, stays at winner 0.
        if (redPot == 0 && bluePot == 0 && redVol == 0 && blueVol == 0) return;

        uint8 winner;
        uint256 prize;
        if (redVol > blueVol) {
            winner = RED;
            prize = redPot + bluePot;
        } else if (blueVol > redVol) {
            winner = BLUE;
            prize = redPot + bluePot;
        } else {
            winner = TIE;
            if (redVol == 0) {
                // Only sub-MIN_SWAP fees and no volume on either side: no one can claim these
                // pots, so they roll into the same teams' pots for the current week.
                uint32 nowWeek = currentWeek();
                War storage next = _wars[id][nowWeek];
                next.pot[RED] += uint128(redPot);
                next.pot[BLUE] += uint128(bluePot);
                w.pot[RED] = 0;
                w.pot[BLUE] = 0;
                if (lastActiveWeek[id] < nowWeek) lastActiveWeek[id] = nowWeek;
            }
        }
        w.winner = winner;
        emit WarFinalized(id, week, winner, redVol, blueVol, prize);
    }

    // ---------------------------------------------------------------------------------------
    // External
    // ---------------------------------------------------------------------------------------

    /// @notice Finalize a finished week. Reverts if the week is not over; no-op if already final.
    function finalize(PoolKey calldata key, uint32 week) external {
        if (week >= currentWeek()) revert WeekNotOver();
        PoolId id = key.toId();
        if (_wars[id][week].winner == NONE) _finalize(id, week);
    }

    /// @notice Claim winnings for finished weeks on one pool. Finalizes weeks that need it.
    function claim(PoolKey calldata key, uint32[] calldata weekIds) external nonReentrant {
        PoolId id = key.toId();
        uint32 nowWeek = currentWeek();
        uint256 total;
        for (uint256 i; i < weekIds.length; ++i) {
            uint32 week = weekIds[i];
            if (week < nowWeek && _wars[id][week].winner == NONE) _finalize(id, week);
            uint256 amount = claimable(id, week, msg.sender);
            if (amount == 0) continue;
            claimed[id][week][msg.sender] = true;
            total += amount;
            emit Claimed(id, week, msg.sender, amount);
        }
        if (total == 0) revert NothingToClaim();
        _sendEth(msg.sender, total);
    }

    /// @notice ETH `player` can claim for a finalized week. 0 if not final, lost, or claimed.
    function claimable(PoolId id, uint32 week, address player) public view returns (uint256) {
        War storage w = _wars[id][week];
        uint8 winner = w.winner;
        if (winner == NONE || claimed[id][week][player]) return 0;
        uint8 t = teamOf[id][week][player];
        uint256 vol = volOf[id][week][player];
        if (t == NONE || vol == 0) return 0;
        uint256 teamVol = w.volume[t];
        if (winner == t) return ((uint256(w.pot[RED]) + w.pot[BLUE]) * vol) / teamVol;
        if (winner == TIE) return (uint256(w.pot[t]) * vol) / teamVol;
        return 0;
    }

    /// @notice Full war state for a pool and week.
    function war(PoolId id, uint32 week)
        external
        view
        returns (uint256 redPot, uint256 bluePot, uint256 redVolume, uint256 blueVolume, uint8 winner)
    {
        War storage w = _wars[id][week];
        return (w.pot[RED], w.pot[BLUE], w.volume[RED], w.volume[BLUE], w.winner);
    }

    /// @notice Live scoreboard for the current week.
    function scoreboard(PoolId id)
        external
        view
        returns (uint256 redVolume, uint256 blueVolume, uint256 redPot, uint256 bluePot, uint256 secondsLeft)
    {
        uint32 week = currentWeek();
        War storage w = _wars[id][week];
        return (w.volume[RED], w.volume[BLUE], w.pot[RED], w.pot[BLUE], _weekEnd(week) - block.timestamp);
    }
}
