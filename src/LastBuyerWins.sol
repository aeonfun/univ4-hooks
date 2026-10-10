// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// SOURCE VERIFIED ON THE CHAIN EXPLORER - vendored here by scripts/sync_source.py
// (comment long-dashes normalized to hyphens; no code or logic change).
// Its deps are the verified build's own files under src/vendor/LastBuyerWins/, imports rewritten to them.
//   base (8453): 0x5D505d56d4B62f5F83493b4acb03353bBde760CC
//   robinhood (4663): 0x94DE41E76700443F3d6673a397B00d41CF6ea0cc

// LastBuyerWins - "Every buy resets the clock. When the clock hits zero, the last buyer takes the pot."
//
// FOMO3D as a Uniswap v4 pool. Every swap pays GAME_BPS of its ETH leg into the pool's pot.
// A qualifying buy (>= minBuyRequired, which rises with the pot) names the last buyer and
// resets a ROUND_DURATION countdown. When the countdown runs out, the last buyer is credited
// WINNER_BPS of the pot; the rest seeds the next round. Settlement is lazy (next swap, or
// anyone calls settle) and payouts are pull-only (claim / claimFor).
//
// Inherits EthGameHook (ETH-side fee on all four swap shapes) and AeonFee (mandatory 10 bps).
// Flags: 0x20CC.

import {IPoolManager} from "./vendor/LastBuyerWins/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "./vendor/LastBuyerWins/lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "./vendor/LastBuyerWins/lib/v4-core/src/types/PoolId.sol";

import {EthGameHook} from "./vendor/LastBuyerWins/src/EthGameHook.sol";

contract LastBuyerWins is EthGameHook {
    using PoolIdLibrary for PoolKey;

    /// @notice Game fee on each swap's ETH leg, in basis points (20 = 0.20%).
    uint256 public constant GAME_BPS = 20;
    /// @notice Countdown restarted by each qualifying buy.
    uint256 public constant ROUND_DURATION = 1 hours;
    /// @notice The minimum qualifying buy rises with the pot (100 = 1% of the pot).
    uint256 public constant MIN_BUY_POT_BPS = 100;
    /// @notice Winner's share of the pot (8_000 = 80%); the rest seeds the next round.
    uint256 public constant WINNER_BPS = 8_000;

    /// @notice Floor for a qualifying buy, in native units (set per chain).
    uint256 public immutable MIN_BUY;

    struct Round {
        uint128 pot; // ETH in the pot (wei)
        uint64 deadline; // 0 = idle
        uint32 roundId;
        address lastBuyer;
    }

    mapping(PoolId => Round) public rounds;
    /// @notice Unclaimed winnings, global across pools.
    mapping(address => uint256) public claimable;

    event PotFed(PoolId indexed id, uint256 amount, uint256 newPot);
    event NewLastBuyer(PoolId indexed id, uint32 indexed roundId, address indexed player, uint256 ethIn, uint64 deadline);
    event RoundWon(PoolId indexed id, uint32 indexed roundId, address indexed winner, uint256 prize, uint256 seed);
    event Claimed(address indexed player, uint256 amount);

    error ZeroMinBuy();

    constructor(IPoolManager _pm, uint256 minBuy) EthGameHook(_pm) {
        if (minBuy < MIN_FLOOR) revert ZeroMinBuy();
        MIN_BUY = minBuy;
    }

    // ---------------------------------------------------------------------------------------
    // Game
    // ---------------------------------------------------------------------------------------

    function _onInitialize(PoolKey calldata key) internal override {
        rounds[key.toId()].roundId = 1;
    }

    function _beforeGame(PoolKey calldata key) internal override {
        _settle(key.toId());
    }

    function _onSwap(address sender, PoolKey calldata key, bool isBuy, uint256 ethAmount, bytes calldata hookData)
        internal
        override
        returns (uint256 fee)
    {
        PoolId id = key.toId();
        Round storage r = rounds[id];

        // The bar is read before this swap's fee lands in the pot, so it is predictable.
        if (isBuy && ethAmount >= _minBuyRequired(r.pot)) {
            address player = _resolvePlayer(sender, hookData);
            uint64 deadline = uint64(block.timestamp + ROUND_DURATION);
            r.lastBuyer = player;
            r.deadline = deadline;
            emit NewLastBuyer(id, r.roundId, player, ethAmount, deadline);
        }

        fee = _bps(ethAmount, GAME_BPS);
        if (fee != 0) {
            uint128 newPot = r.pot + _u128(fee);
            r.pot = newPot;
            emit PotFed(id, fee, newPot);
        }
    }

    /// @dev Settle a finished round: credit the winner, keep the seed, go idle.
    function _settle(PoolId id) internal {
        Round storage r = rounds[id];
        uint64 deadline = r.deadline;
        if (deadline == 0 || block.timestamp <= deadline) return;

        address winner = r.lastBuyer;
        uint256 pot = r.pot;
        uint256 prize = _bps(pot, WINNER_BPS);
        uint256 seed = pot - prize;
        uint32 roundId = r.roundId;

        r.pot = uint128(seed);
        r.deadline = 0;
        r.lastBuyer = address(0);
        r.roundId = roundId + 1;
        claimable[winner] += prize;

        emit RoundWon(id, roundId, winner, prize, seed);
    }

    function _minBuyRequired(uint256 pot) internal view returns (uint256) {
        uint256 potBar = _bps(pot, MIN_BUY_POT_BPS);
        return potBar > MIN_BUY ? potBar : MIN_BUY;
    }

    // ---------------------------------------------------------------------------------------
    // External
    // ---------------------------------------------------------------------------------------

    /// @notice Settle a finished round without a swap. No-op if the round is not over.
    function settle(PoolKey calldata key) external {
        _settle(key.toId());
    }

    /// @notice Withdraw your winnings.
    function claim() external nonReentrant {
        _claim(msg.sender);
    }

    /// @notice Push a winner's ETH to them (helps smart wallets that cannot call claim).
    function claimFor(address player) external nonReentrant {
        _claim(player);
    }

    function _claim(address player) internal {
        uint256 amount = claimable[player];
        if (amount == 0) revert NothingToClaim();
        claimable[player] = 0;
        emit Claimed(player, amount);
        _sendEth(player, amount);
    }

    /// @notice ETH a buy needs to name the last buyer, given the pot right now.
    function minBuyRequired(PoolId id) external view returns (uint256) {
        Round memory r = rounds[id];
        // A finished, unsettled round settles before the next buy, so quote the seed pot.
        if (r.deadline != 0 && block.timestamp > r.deadline) return _minBuyRequired(r.pot - _bps(r.pot, WINNER_BPS));
        return _minBuyRequired(r.pot);
    }

    /// @notice Seconds until the current round ends. 0 if idle or already over.
    function timeLeft(PoolId id) external view returns (uint256) {
        uint64 deadline = rounds[id].deadline;
        if (deadline == 0 || block.timestamp >= deadline) return 0;
        return deadline - block.timestamp;
    }
}
