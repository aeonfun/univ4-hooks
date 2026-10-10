// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// EthGameHook - shared base for the ETH-pot game hooks (LastBuyerWins, ComboBreaker, TeamWar).
//
// Pool scope: currency0 MUST be native ETH (enforced in beforeInitialize). A buy is
// zeroForOne (ETH in), a sell is oneForZero (ETH out).
//
// Every swap's game fee is taken in ETH, whichever side the caller specified:
//   - ETH is the SPECIFIED side (buy exact-in, sell exact-out): beforeSwap returns a
//     specified delta and takes the fee from the PoolManager.
//   - ETH is the UNSPECIFIED side (buy exact-out, sell exact-in): AeonFee.afterSwap takes
//     the mandatory 10 bps first, then `_afterSwapExtra` returns the game fee as an extra
//     unspecified delta and takes it.
// The derived game decides the fee and updates its own state in `_onSwap`, which sees the
// ETH amount BEFORE the game fee. Fees are held by this contract (the pots) and paid out
// pull-only. There is no admin and no rescue path.
//
// Flags: BEFORE_INITIALIZE | BEFORE_SWAP | BEFORE_SWAP_RETURNS_DELTA | AFTER_SWAP |
// AFTER_SWAP_RETURNS_DELTA (0x2000 | 0x80 | 0x08 | 0x40 | 0x04 = 0x20CC).

import {IHooks} from "../lib/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "../lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "../lib/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "../lib/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "../lib/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from
    "../lib/v4-core/src/types/BeforeSwapDelta.sol";

import {AeonFee} from "./AeonFee.sol";

interface IMsgSender {
    function msgSender() external view returns (address);
}

abstract contract EthGameHook is AeonFee {
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @notice Gas cap for the `msgSender()` probe on the router, so a hostile router
    /// cannot burn the swap's gas.
    uint256 public constant MSG_SENDER_GAS = 30_000;

    /// @notice Lowest allowed scoring minimum (MIN_BUY / MIN_BREAK / MIN_SWAP), in wei. At or
    /// above it every scoring swap pays a non-zero game fee (lowest rate is 4 bps), so the
    /// partial-fill guard always applies to swaps that change game state.
    uint256 public constant MIN_FLOOR = 10_000;

    /// @dev ETH-specified swaps record the exact amount the pool must fill, so afterSwap can
    /// reject a partial fill (a price-limited swap would otherwise score its full specified
    /// size while only filling a sliver). 0 = nothing pending.
    uint256 private _expectedFill;
    uint256 private _locked = 1;

    error NotEthPool();
    error PartialFill();
    error FeeOverflow();
    error NothingToClaim();
    error TransferFailed();
    error Reentrancy();
    error OnlyPoolManagerEth();

    constructor(IPoolManager _pm) AeonFee(_pm) {}

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    /// @notice Accepts ETH only from the PoolManager (game fees arrive through take()).
    receive() external payable {
        if (msg.sender != address(poolManager)) revert OnlyPoolManagerEth();
    }

    // ---------------------------------------------------------------------------------------
    // Hook callbacks
    // ---------------------------------------------------------------------------------------

    function beforeInitialize(address, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (!key.currency0.isAddressZero()) revert NotEthPool();
        _onInitialize(key);
        return IHooks.beforeInitialize.selector;
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        // A pending fill means this swap is nested inside another swap's callbacks (e.g. a
        // reentrant currency1 during the AeonFee take). Letting it run would overwrite or consume
        // the outer swap's _expectedFill and skip its partial-fill check.
        if (_expectedFill != 0) revert Reentrancy();
        _beforeGame(key);

        if (!_ethSpecified(params)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 ethAmount = _abs(params.amountSpecified);
        uint256 fee = _onSwap(sender, key, params.zeroForOne, ethAmount, hookData);
        if (fee == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        if (fee > uint256(uint128(type(int128).max))) revert FeeOverflow();

        // Exact-in buy: the pool swaps (amount - fee). Exact-out sell: the pool releases
        // (amount + fee). Either way the trader pays the fee; afterSwap checks the fill.
        _expectedFill = params.amountSpecified < 0 ? ethAmount - fee : ethAmount + fee;
        poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), fee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
    }

    /// @dev Runs inside AeonFee.afterSwap, after the mandatory 10 bps is taken.
    function _afterSwapExtra(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (int128) {
        if (_ethSpecified(params)) {
            uint256 expected = _expectedFill;
            if (expected != 0) {
                delete _expectedFill;
                if (_abs128(delta.amount0()) != expected) revert PartialFill();
            }
            return 0;
        }

        uint256 ethAmount = _abs128(delta.amount0());
        if (ethAmount == 0) return 0;
        uint256 fee = _onSwap(sender, key, params.zeroForOne, ethAmount, hookData);
        if (fee == 0) return 0;
        if (fee > uint256(uint128(type(int128).max))) revert FeeOverflow();

        poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), fee);
        return int128(uint128(fee));
    }

    // ---------------------------------------------------------------------------------------
    // Game interface
    // ---------------------------------------------------------------------------------------

    /// @dev Called once per pool at initialization (after the ETH check).
    function _onInitialize(PoolKey calldata key) internal virtual {}

    /// @dev Called at the start of every swap, before the swap's own rules (lazy settlement).
    function _beforeGame(PoolKey calldata key) internal virtual {}

    /// @dev Apply the game rules to one swap. `ethAmount` is the swap's ETH leg BEFORE the
    /// game fee. Returns the game fee in wei, which the caller takes into this contract.
    function _onSwap(address sender, PoolKey calldata key, bool isBuy, uint256 ethAmount, bytes calldata hookData)
        internal
        virtual
        returns (uint256 fee);

    // ---------------------------------------------------------------------------------------
    // Player identity
    // ---------------------------------------------------------------------------------------

    /// @dev Address carried in `hookData`: exactly abi.encode(address) (32 bytes). Anything else,
    /// or a zero / dirty word, returns address(0).
    function _hookDataPlayer(bytes calldata hookData) internal pure returns (address) {
        if (hookData.length != 32) return address(0);
        uint256 word = uint256(bytes32(hookData[0:32]));
        if (word >> 160 != 0) return address(0);
        return address(uint160(word));
    }

    /// @dev `sender.msgSender()` (v4 router convention), gas-capped. address(0) on any failure.
    function _routerMsgSender(address sender) internal view returns (address) {
        if (sender.code.length == 0) return address(0);
        (bool ok, bytes memory ret) =
            sender.staticcall{gas: MSG_SENDER_GAS}(abi.encodeWithSelector(IMsgSender.msgSender.selector));
        if (!ok || ret.length < 32) return address(0);
        uint256 word = abi.decode(ret, (uint256));
        if (word >> 160 != 0) return address(0);
        return address(uint160(word));
    }

    /// @dev Resolve the player: hookData address, then router msgSender(), then tx.origin.
    function _resolvePlayer(address sender, bytes calldata hookData) internal view returns (address player) {
        player = _hookDataPlayer(hookData);
        if (player != address(0)) return player;
        player = _routerMsgSender(sender);
        if (player != address(0)) return player;
        return tx.origin;
    }

    // ---------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------

    /// @dev True when currency0 (ETH) is the specified side of the swap.
    function _ethSpecified(IPoolManager.SwapParams calldata params) internal pure returns (bool) {
        return (params.amountSpecified < 0) == params.zeroForOne;
    }

    function _abs(int256 x) internal pure returns (uint256) {
        // int256.min-safe: never negates type(int256).min directly.
        return x < 0 ? uint256(-(x + 1)) + 1 : uint256(x);
    }

    /// @dev Widen to int256 before negating, so type(int128).min cannot overflow.
    function _abs128(int128 x) internal pure returns (uint256) {
        int256 w = int256(x);
        return uint256(w < 0 ? -w : w);
    }

    function _bps(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return (amount * bps) / 10_000;
    }

    function _u128(uint256 x) internal pure returns (uint128) {
        if (x > type(uint128).max) revert FeeOverflow();
        return uint128(x);
    }

    /// @dev Pull-payment send. Reverts on failure so the amount stays claimable.
    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
