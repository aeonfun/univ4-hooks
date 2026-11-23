// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// SOURCE VERIFIED ON THE CHAIN EXPLORER - vendored here by scripts/sync_source.py
// (comment long-dashes normalized to hyphens; no code or logic change).
// Its deps are the verified build's own files under src/vendor/PerpRegimeFee/, imports rewritten to them.
//   base (8453): 0x190D7F16f9385026cb243BD78F1181427d4Cc0C4
//   elysium (99901): 0x1dF778Efb0116CCCfA92c613703D4F3A66BC00C4

// FREEFORM hook scaffold. In freeform mode the deploy-uni-hook skill rewrites the
// AEON:BODY region with callbacks generated from the user's prompt.
//
// Every hook inherits AeonFee: a MANDATORY 10 bps protocol fee taken in afterSwap
// and routed to the aeon recipient. `afterSwap` lives in AeonFee and is NOT virtual,
// so a freeform body can never implement, lower, or skip it. Post-swap logic goes in
// `_afterSwapExtra`, which runs AFTER the protocol fee is taken.
//
// Rules the generator MUST keep:
//   - Contract name stays `Hook`, it stays `is AeonFee`, and the constructor chains
//     `AeonFee(_pm)` (the deploy script imports `Hook` by name; AeonFee sets
//     `poolManager` + `onlyPoolManager`).
//   - Do NOT implement `afterSwap`, `poolManager`, `onlyPoolManager`, or
//     `NotPoolManager` - they come from AeonFee. For post-swap logic, override
//     `_afterSwapExtra` (return 0 unless the hook takes an ADDITIONAL delta of its own,
//     in which case it must `poolManager.take` that amount itself).
//   - Every OTHER callback uses the EXACT IHooks signature, carries `onlyPoolManager`,
//     and returns the right selector (e.g. `IHooks.beforeSwap.selector`).
//   - Flags are AUTO-DERIVED from which callbacks exist (see hook-deploy.sh). Because
//     AeonFee always takes a return-delta fee, EVERY hook's flags carry AFTER_SWAP +
//     AFTER_SWAP_RETURNS_DELTA - so an aeon hook is never Labs auto-routable (allowlist).
//   - A dynamic-fee hook sets HOOK_POOL_FEE=dynamic in hook.env and returns
//     `fee | LPFeeLibrary.OVERRIDE_FEE_FLAG` from beforeSwap.
//   - Games must succeed with empty hookData; do not revert a vanilla exact-in; do not
//     key state off sender (sender is the router, not the trader).
//   - Extra fee take (in `_afterSwapExtra`): magnitude of unspecified (exact-in AND
//     exact-out). Widen to int256 before abs. take() to an immutable recipient, never
//     address(this), no withdraw.
//   - Gates: no exact-match on moving state, no raw amountSpecified cap, no
//     balanceOf(poolManager). Helpers must match execution-time state.
//
// All commonly-needed imports/usings are here so generated bodies compile as-is.

import {IHooks} from "./vendor/PerpRegimeFee/lib/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "./vendor/PerpRegimeFee/lib/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "./vendor/PerpRegimeFee/lib/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "./vendor/PerpRegimeFee/lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "./vendor/PerpRegimeFee/lib/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "./vendor/PerpRegimeFee/lib/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "./vendor/PerpRegimeFee/lib/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "./vendor/PerpRegimeFee/lib/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "./vendor/PerpRegimeFee/lib/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "./vendor/PerpRegimeFee/lib/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "./vendor/PerpRegimeFee/lib/v4-core/src/libraries/TickMath.sol";

import {AeonFee} from "./vendor/PerpRegimeFee/src/AeonFee.sol";

contract Hook is AeonFee {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;
    using CurrencyLibrary for Currency;

    enum Regime {
        RISK_ON,
        NEUTRAL,
        RISK_OFF
    }

    uint24 public constant RISK_ON_FEE = 1000;
    uint24 public constant NEUTRAL_FEE = 3000;
    uint24 public constant RISK_OFF_FEE = 10000;

    address public immutable oracle;
    Regime public currentRegime;

    error InvalidOracle();
    error OnlyOracle();

    event RegimeUpdated(Regime indexed previousRegime, Regime indexed newRegime);
    event RegimeFeeApplied(Regime indexed regime, uint24 fee);

    constructor(IPoolManager _pm, address _oracle) AeonFee(_pm) {
        if (_oracle == address(0)) revert InvalidOracle();
        oracle = _oracle;
        currentRegime = Regime.NEUTRAL;
    }

    modifier onlyOracle() {
        if (msg.sender != oracle) revert OnlyOracle();
        _;
    }

    // --- AEON:BODY START (freeform: replace with callbacks from the prompt) ---
    function updateRegime(Regime newRegime) external onlyOracle {
        Regime previousRegime = currentRegime;
        currentRegime = newRegime;
        emit RegimeUpdated(previousRegime, newRegime);
    }

    function currentFee() public view returns (uint24) {
        if (currentRegime == Regime.RISK_ON) return RISK_ON_FEE;
        if (currentRegime == Regime.RISK_OFF) return RISK_OFF_FEE;
        return NEUTRAL_FEE;
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint24 fee = currentFee();
        emit RegimeFeeApplied(currentRegime, fee);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // Operator skim, stacked ON TOP of the mandatory 10 bps AeonFee. Taken straight to an
    // immutable recipient in _afterSwapExtra (no custody, no withdraw), mirroring AeonFee's
    // own fee math so exact-in AND exact-out both pay. Flags are unchanged (0xC4).
    address public constant EXTRA_FEE_RECIPIENT = 0x805073311cB90854029Df7De4b25211F7a18cd7a;
    uint256 public constant EXTRA_FEE_BPS = 10;

    event ExtraFeeTaken(Currency indexed currency, uint256 amount, address indexed recipient);

    function _afterSwapExtra(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (int128) {
        (Currency feeCurrency, int128 unspecifiedAmount) = ((params.amountSpecified < 0) == params.zeroForOne)
            ? (key.currency1, delta.amount1())
            : (key.currency0, delta.amount0());

        int256 wideAmount = int256(unspecifiedAmount);
        uint256 magnitude = uint256(wideAmount < 0 ? -wideAmount : wideAmount);
        if (magnitude == 0) return 0;

        uint256 extraFee = (magnitude * EXTRA_FEE_BPS) / 10_000;
        if (extraFee == 0) return 0;
        require(extraFee <= uint256(uint128(type(int128).max)), "extra fee overflow");

        poolManager.take(feeCurrency, EXTRA_FEE_RECIPIENT, extraFee);
        emit ExtraFeeTaken(feeCurrency, extraFee, EXTRA_FEE_RECIPIENT);
        return int128(uint128(extraFee));
    }
    // --- AEON:BODY END ---
}
