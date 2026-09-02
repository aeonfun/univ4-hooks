// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Minimal unlock-callback router for fork tests: adds full-range liquidity and runs
// a swap through the REAL PoolManager, settling every ERC20 delta itself (sync +
// transfer + settle when owed to the pool, take when owed to us). Typed entirely
// against the vendored v4-core interfaces, so it shares types with the fleet hooks.
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

contract V4Router is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager public immutable pm;

    // full range for tickSpacing 60 (887272 floored to a multiple of 60)
    int24 internal constant TICK_LOWER = -887220;
    int24 internal constant TICK_UPPER = 887220;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    function addLiquidity(PoolKey calldata key, int256 liq) external {
        pm.unlock(abi.encode(uint8(0), key, liq, IPoolManager.SwapParams(false, 0, 0)));
    }

    function swap(PoolKey calldata key, IPoolManager.SwapParams calldata p)
        external
        returns (BalanceDelta delta)
    {
        return abi.decode(pm.unlock(abi.encode(uint8(1), key, int256(0), p)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "not pm");
        (uint8 action, PoolKey memory key, int256 liq, IPoolManager.SwapParams memory p) =
            abi.decode(data, (uint8, PoolKey, int256, IPoolManager.SwapParams));

        BalanceDelta delta;
        if (action == 0) {
            (delta,) = pm.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: TICK_LOWER,
                    tickUpper: TICK_UPPER,
                    liquidityDelta: liq,
                    salt: bytes32(0)
                }),
                ""
            );
        } else {
            delta = pm.swap(key, p, "");
        }

        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency cur, int128 amt) internal {
        if (amt < 0) {
            // we owe the pool: sync, transfer the owed amount in, settle
            pm.sync(cur);
            IERC20Minimal(Currency.unwrap(cur)).transfer(address(pm), uint256(uint128(-amt)));
            pm.settle();
        } else if (amt > 0) {
            // pool owes us: pull it out
            pm.take(cur, address(this), uint256(uint128(amt)));
        }
    }
}
