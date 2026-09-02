// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// LegacyLedger - regenerated on the AeonFee base, custody-free.
// "Every trade pays a 0.05% tax and builds your loyalty tier." Loyalty is an on-chain score
// that climbs with each taxed swap (bragging rights / tiers). The 0.05% tax is the hook's OWN
// skim, taken in _afterSwapExtra AFTER the mandatory 10 bps AeonFee, and routed STRAIGHT OUT
// to the aeon treasury (AEON_FEE_RECIPIENT) - the hook holds NO funds, so there is no pot to
// strand and no rebate to misprice. Flags: AFTER_SWAP + returns-delta = 0x44.

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {AeonFee} from "./AeonFee.sol";

contract LegacyLedger is AeonFee {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @notice Flat tax charged on the received amount, in basis points. 5 = 0.05%.
    uint256 public constant TAX_BPS = 5;
    /// @notice Marks past this one still accrue but no longer raise the tier.
    uint256 public constant SCORE_CAP = 20;

    /// @notice Cumulative loyalty marks per trader (one per taxed swap).
    mapping(address => uint256) public legacyScore;

    event TaxPaid(PoolId indexed id, address indexed player, Currency indexed currency, uint256 score, uint256 tax);

    error TaxOverflow();

    constructor(IPoolManager _pm) AeonFee(_pm) {}

    // Hook's own 0.05% tax, taken AFTER the base 10 bps AeonFee (base owns afterSwap) and routed
    // straight to the treasury. Returns the extra delta it took, which the base folds into its
    // own fee delta. The hook custodies nothing.
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

        // (2) tax on the UNSPECIFIED currency (same side as the base fee). Take the magnitude so
        // it is charged on exact-output too (input side, negative delta).
        (Currency taxCurrency, int128 unspecifiedAmount) = ((params.amountSpecified < 0) == params.zeroForOne)
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());
        // Widen before negating so a settled delta of type(int128).min cannot overflow and brick the swap.
        uint256 magnitude = uint256(unspecifiedAmount < 0 ? -int256(unspecifiedAmount) : int256(unspecifiedAmount));
        if (magnitude == 0) return int128(0);

        uint256 tax = (magnitude * TAX_BPS) / 10_000;
        if (tax == 0) return int128(0);
        if (tax > uint256(uint128(type(int128).max))) revert TaxOverflow();

        PoolId id = key.toId();
        uint256 score = legacyScore[player] + 1;
        legacyScore[player] = score;

        emit TaxPaid(id, player, taxCurrency, score, tax);
        // route the tax straight to the treasury - the hook never holds it.
        poolManager.take(taxCurrency, AEON_FEE_RECIPIENT, tax);
        return int128(uint128(tax));
    }

    /// @notice `player`'s current loyalty tier (0..SCORE_CAP).
    function loyaltyTier(address player) external view returns (uint256) {
        uint256 score = legacyScore[player];
        return score < SCORE_CAP ? score : SCORE_CAP;
    }

    /// @notice How many more taxed swaps `player` needs to reach the top tier.
    function marksToMaxTier(address player) external view returns (uint256) {
        uint256 score = legacyScore[player];
        return score >= SCORE_CAP ? 0 : SCORE_CAP - score;
    }
}
