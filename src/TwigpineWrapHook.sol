// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// SOURCE VERIFIED ON THE CHAIN EXPLORER - vendored here by scripts/sync_source.py
// (comment long-dashes normalized to hyphens; no code or logic change).
// Its deps are the verified build's own files under src/vendor/TwigpineWrapHook/, imports rewritten to them.
//   base (8453): 0xf7423f48886F86F551B517254d21AF4267732888
// NOTE: this hook does NOT inherit AeonFee, so it takes no 10 bps protocol
// fee onchain, unlike the AeonFee reference hooks in this dir.

import {IERC20} from "./vendor/TwigpineWrapHook/lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "./vendor/TwigpineWrapHook/lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Wrapper} from "./vendor/TwigpineWrapHook/lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Wrapper.sol";
import {IPoolManager} from "./vendor/TwigpineWrapHook/lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "./vendor/TwigpineWrapHook/lib/v4-periphery/lib/v4-core/src/types/Currency.sol";
// Vendored byte-identical from Uniswap/v4-hooks-public@e4eabe5 (src/base/*), which is the post-audit
// (OZ H-01/L-01/L-02/N-01 resolved) version of the code that Uniswap Labs deployed as WETHHook on Base
// (0xb08211d57032dd10b1974d4b876851a7f7596888, verified source on blockscout).
import {BaseTokenWrapperHook} from "./vendor/TwigpineWrapHook/src/vendor/v4-hooks-public/BaseTokenWrapperHook.sol";

/// @title TwigWrapHook
/// @notice Uniswap v4 hook that makes a fee-0 GITLAWB/TWIG pool wrap/unwrap 1:1 inside swaps.
/// @dev No owner, no admin, no storage, no upgrade. All liquidity ops revert (base contract).
///      The only external entry points are the IHooks callbacks (onlyPoolManager) and view getters.
///      Mirrors the audited WstETHHook structure: take input from PoolManager -> wrap/unwrap -> settle output.
contract TwigWrapHook is BaseTokenWrapperHook {
    using SafeERC20 for IERC20;

    /// @notice The TWIG ERC20Wrapper (wrapper currency). Its underlying() is GITLAWB.
    ERC20Wrapper public immutable wrapper;

    constructor(IPoolManager _manager, ERC20Wrapper _wrapper)
        BaseTokenWrapperHook(_manager, Currency.wrap(address(_wrapper)), Currency.wrap(address(_wrapper.underlying())))
    {
        wrapper = _wrapper;
        // hook -> wrapper pull of GITLAWB in depositFor
        IERC20(address(_wrapper.underlying())).forceApprove(address(_wrapper), type(uint256).max);
    }

    /// @inheritdoc BaseTokenWrapperHook
    function _deposit(uint256 underlyingAmount) internal override returns (uint256, uint256) {
        // GITLAWB: PoolManager -> hook (uses PoolManager's GITLAWB inventory; repaid by the swapper within the unlock)
        _take(underlyingCurrency, address(this), underlyingAmount);
        // GITLAWB: hook -> wrapper, mints TWIG to the hook (1:1)
        wrapper.depositFor(address(this), underlyingAmount);
        // TWIG: hook -> PoolManager (sync + transfer + settle)
        _settle(wrapperCurrency, address(this), underlyingAmount);
        return (underlyingAmount, underlyingAmount);
    }

    /// @inheritdoc BaseTokenWrapperHook
    function _withdraw(uint256 wrappedAmount) internal override returns (uint256, uint256) {
        // TWIG: PoolManager -> hook (uses PoolManager's TWIG inventory; repaid by the swapper within the unlock)
        _take(wrapperCurrency, address(this), wrappedAmount);
        // burns the hook's TWIG, GITLAWB: wrapper -> hook (1:1)
        wrapper.withdrawTo(address(this), wrappedAmount);
        // GITLAWB: hook -> PoolManager (sync + transfer + settle)
        _settle(underlyingCurrency, address(this), wrappedAmount);
        return (wrappedAmount, wrappedAmount);
    }
}
