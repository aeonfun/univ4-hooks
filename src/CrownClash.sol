// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// CrownClash - regenerated on the AeonFee base, custody-free.
// "Every trade pays a tiny 0.07% tribute; trade the most volume to wear the crown."
// The crown is an on-chain volume leaderboard (bragging rights). The 0.07% tribute is the
// hook's OWN skim, taken in _afterSwapExtra AFTER the mandatory 10 bps AeonFee, and routed
// STRAIGHT OUT to the aeon treasury (AEON_FEE_RECIPIENT) - the hook holds NO funds, so there
// is no pot to strand, no rescue path to get wrong. Flags: AFTER_SWAP + returns-delta = 0x44.

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {AeonFee} from "./AeonFee.sol";

contract CrownClash is AeonFee {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @notice Tribute charged on the received amount, in basis points. 7 = 0.07%.
    uint256 public constant TRIBUTE_BPS = 7;

    /// @notice The current highest-volume trader on a pool.
    mapping(PoolId => address) public champion;
    /// @notice Cumulative volume per trader, measured in a fixed unit (currency0 amount).
    mapping(PoolId => mapping(address => uint256)) public volume;

    event TributePaid(
        PoolId indexed id, address indexed player, Currency indexed currency, uint256 amount, uint256 newVolume
    );
    event Dethroned(PoolId indexed id, address indexed oldChampion, address indexed newChampion, uint256 volume);

    error TributeOverflow();

    constructor(IPoolManager _pm) AeonFee(_pm) {}

    // Hook's own 0.07% tribute, taken AFTER the base 10 bps AeonFee (base owns afterSwap) and
    // routed straight to the treasury. Returns the extra delta it took, which the base folds
    // into its own fee delta. The hook custodies nothing.
    function _afterSwapExtra(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (int128) {
        // (1) opt-in. No player named -> the swap is not playing this game.
        if (hookData.length < 32) return int128(0);
        address player = address(uint160(uint256(bytes32(hookData[0:32]))));
        if (player == address(0)) return int128(0);

        // (2) tribute on the UNSPECIFIED currency (same side as the base fee). Take the
        // magnitude so it is charged on exact-output too (input side, negative delta).
        (Currency tributeCurrency, int128 unspecifiedAmount) = ((params.amountSpecified < 0) == params.zeroForOne)
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());
        // Widen before negating so a settled delta of type(int128).min cannot overflow and brick the swap.
        uint256 magnitude = uint256(unspecifiedAmount < 0 ? -int256(unspecifiedAmount) : int256(unspecifiedAmount));
        if (magnitude == 0) return int128(0);

        uint256 tribute = (magnitude * TRIBUTE_BPS) / 10_000;
        if (tribute == 0) return int128(0);
        if (tribute > uint256(uint128(type(int128).max))) revert TributeOverflow();

        // (3) score volume in a FIXED unit: the settled currency0 amount magnitude. Scoring
        // |amountSpecified| mixed currency0/currency1 by the caller's exact-in/out choice, so a
        // dust swap could out-rank a whale (the old F1). Settled currency0 is a single unit.
        int128 d0 = delta.amount0();
        uint256 size = uint256(d0 < 0 ? -int256(d0) : int256(d0)); // widen: int128.min-safe

        PoolId id = key.toId();
        uint256 newVolume = volume[id][player] + size;
        volume[id][player] = newVolume;

        address king = champion[id];
        if (player != king && newVolume > volume[id][king]) {
            champion[id] = player;
            emit Dethroned(id, king, player, newVolume);
        }

        emit TributePaid(id, player, tributeCurrency, tribute, newVolume);
        // route the tribute straight to the treasury - the hook never holds it.
        poolManager.take(tributeCurrency, AEON_FEE_RECIPIENT, tribute);
        return int128(uint128(tribute));
    }

    /// @notice How much MORE volume `player` needs before a swap takes the crown.
    function volumeGapToDethrone(PoolId id, address player) external view returns (uint256) {
        address king = champion[id];
        if (player == king) return 0;
        uint256 bar = volume[id][king];
        uint256 have = volume[id][player];
        return have > bar ? 0 : bar - have + 1;
    }
}
