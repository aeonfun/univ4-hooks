// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Behavioral fork test for the re-anchored HeavierHand + fraction-based CapGate.
// Proves an OFF-1:1 pool (price 4.0) is NOT permanently one-directional (the old bug) and
// that CapGate's cap is a fraction of the pool's own reserves, not a raw token constant.
// Self-contained (no forge-std, no cheatcodes): runs against a real Base fork via --fork-url.
//
//   forge test --root . --match-path test/fork/GateFix.t.sol --fork-url <base-rpc> -vv

import {HookMiner} from "../../script/HookMiner.sol";
import {V4Router} from "./V4Router.sol";
import {MockERC20} from "./MockERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

import {HeavierHand} from "../../src/HeavierHand.sol";
import {CapGate} from "../../src/CapGate.sol";
import {TailTwins} from "../../src/TailTwins.sol";

library console {
    address constant CONSOLE = 0x000000000000000000636F6e736F6c652e6c6f67;

    function log(string memory a, uint256 b) internal view {
        _send(abi.encodeWithSignature("log(string,uint256)", a, b));
    }

    function log(string memory a, bool b) internal view {
        _send(abi.encodeWithSignature("log(string,bool)", a, b));
    }

    function log(string memory a) internal view {
        _send(abi.encodeWithSignature("log(string)", a));
    }

    function _send(bytes memory payload) private view {
        address c = CONSOLE;
        assembly {
            pop(staticcall(gas(), c, add(payload, 0x20), mload(payload), 0x00, 0x00))
        }
    }
}

contract GateFixTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Uniswap v4 Base PoolManager.
    IPoolManager constant PM = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);

    uint160 constant AFTER_INITIALIZE = uint160(1 << 12);
    uint160 constant BEFORE_SWAP = uint160(1 << 7);
    uint160 constant AFTER_SWAP = uint160(1 << 6);
    uint160 constant AFTER_SWAP_RETURNS_DELTA = uint160(1 << 2);
    uint160 constant MASK = uint160(0x3FFF);

    uint160 constant Q96 = 79228162514264337593543950336;
    uint160 constant SQRT_4 = 158456325028528675187087900672; // price 4.0 = 2 * Q96
    // Price ~4.0 but with a NON-zero low byte (0x37 = 55). SQRT_1_1 = 2^96 and SQRT_4 = 2^97 both
    // end in a zero byte, so a low-byte gate (TailTwins) is vacuous at either - it must be proven
    // off a price whose low byte is not zero.
    uint160 constant SQRT_ODD = 158456325028528675187087900727;
    uint160 constant MIN_SQRT = 4295128739;
    uint160 constant MAX_SQRT = 1461446703485210103287273052203988822378723970342;

    function _eq(bool c, string memory m) internal pure {
        require(c, m);
    }

    function _mineDeploy(uint160 flags, bytes memory creationCode) internal returns (address hook) {
        bytes memory initCode = abi.encodePacked(creationCode, abi.encode(PM));
        (address expected, bytes32 salt) = HookMiner.mine(flags, creationCode, abi.encode(PM));
        _eq(expected.code.length == 0, "addr already deployed");
        (bool ok,) = HookMiner.CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        _eq(ok, "create2 deploy failed");
        _eq(expected.code.length > 0, "hook not deployed");
        _eq(uint160(expected) & MASK == (flags & MASK), "flag bits wrong");
        hook = expected;
    }

    function _pool(address hook) internal returns (PoolKey memory key, V4Router router) {
        return _poolAt(hook, SQRT_4); // default: pool opens at PRICE 4.0, not 1:1
    }

    function _poolAt(address hook, uint160 sqrtP) internal returns (PoolKey memory key, V4Router router) {
        MockERC20 tA = new MockERC20("Fork A", "FA");
        MockERC20 tB = new MockERC20("Fork B", "FB");
        (Currency c0, Currency c1) = address(tA) < address(tB)
            ? (Currency.wrap(address(tA)), Currency.wrap(address(tB)))
            : (Currency.wrap(address(tB)), Currency.wrap(address(tA)));
        key = PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(hook)});
        PM.initialize(key, sqrtP);

        router = new V4Router(PM);
        MockERC20(Currency.unwrap(c0)).mint(address(router), 1e27);
        MockERC20(Currency.unwrap(c1)).mint(address(router), 1e27);
        router.addLiquidity(key, 1e21);
    }

    function _swap(V4Router router, PoolKey memory key, bool zeroForOne, int256 amt) internal {
        router.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amt,
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT + 1 : MAX_SQRT - 1
            })
        );
    }

    function _swapReverts(V4Router router, PoolKey memory key, bool zeroForOne, int256 amt, bytes4 sel)
        internal
        returns (bool)
    {
        try router.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amt,
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT + 1 : MAX_SQRT - 1
            })
        ) returns (
            BalanceDelta
        ) {
            return false;
        } catch (bytes memory err) {
            return _hasSelector(err, sel);
        }
    }

    function _hasSelector(bytes memory data, bytes4 sel) internal pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i = 0; i + 4 <= data.length; i++) {
            if (data[i] == sel[0] && data[i + 1] == sel[1] && data[i + 2] == sel[2] && data[i + 3] == sel[3]) {
                return true;
            }
        }
        return false;
    }

    // ---------------------------------------------------------------- HeavierHand

    function test_HeavierHand_offParityIsTwoDirectional() public {
        address hook = _mineDeploy(
            AFTER_INITIALIZE | BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA, type(HeavierHand).creationCode
        );
        (PoolKey memory key, V4Router router) = _pool(hook);
        HeavierHand hh = HeavierHand(hook);

        // (1) at init cur == ref: BOTH legs open, direction EITHER. Under the OLD implicit-1.0
        //     code a price-4 pool was permanently beyond the band and one-directional forever.
        _eq(hh.isAllowed(key, true), "init: zeroForOne must be allowed");
        _eq(hh.isAllowed(key, false), "init: oneForZero must be allowed");
        _eq(hh.allowedDirection(key) == 0, "init: direction must be EITHER");
        console.log("HH skewBps @init", hh.skewBps(key));
        console.log("HH priceRatioBps @init", hh.priceRatioBps(key));

        // (2) the leg the old code permanently blocked now SWAPS for real.
        _swap(router, key, true, -1e18);
        console.log("HH zeroForOne swap OK (previously-blocked leg)");

        // (3) now cur < ref, inside band, currency0 heavier: heavy leg open, light leg closed.
        _eq(hh.isAllowed(key, true), "post: heavy (zeroForOne) must stay allowed");
        _eq(!hh.isAllowed(key, false), "post: light (oneForZero) must be blocked");
        _eq(
            _swapReverts(router, key, false, -1e18, HeavierHand.MustSellHeavierSide.selector),
            "post: oneForZero must revert MustSellHeavierSide"
        );
        _swap(router, key, true, -1e18); // heavy leg still works
        console.log("HH oneForZero reverted, zeroForOne still OK");
        console.log("HH skewBps @post", hh.skewBps(key));
        console.log("HH priceRatioBps @post", hh.priceRatioBps(key));
    }

    // ---------------------------------------------------------------- CapGate

    function test_CapGate_capIsFractionOfReserves() public {
        address hook = _mineDeploy(BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA, type(CapGate).creationCode);
        (PoolKey memory key, V4Router router) = _pool(hook);
        CapGate cg = CapGate(hook);

        // (5) maxTradeSize == 5% of the currency0 virtual reserve, independently recomputed.
        uint128 liq = PM.getLiquidity(key.toId());
        (uint160 sp,,,) = PM.getSlot0(key.toId());
        uint256 b0 = FullMath.mulDiv(uint256(liq), FixedPoint96.Q96, sp);
        uint256 expectedCap = FullMath.mulDiv(b0, 500, 10_000);
        uint256 cap = cg.maxTradeSize(key, true, true);
        console.log("CG reserve b0", b0);
        console.log("CG maxTradeSize(c0)", cap);
        console.log("CG expected 5% cap", expectedCap);
        _eq(cap == expectedCap, "cap must equal 5% of b0");
        _eq(cap > 0, "cap must be > 0");
        _eq(cap != 100e18, "cap must NOT be the old 100e18 constant");

        // (6) under the cap passes; over the cap reverts TradeTooLarge.
        _swap(router, key, true, -int256(cap - (cap / 10)));
        console.log("CG under-cap swap OK");
        _eq(
            _swapReverts(router, key, true, -int256(cap + (cap / 10)), CapGate.TradeTooLarge.selector),
            "over-cap swap must revert TradeTooLarge"
        );
        console.log("CG over-cap swap reverted TradeTooLarge");
    }

    // ---------------------------------------------------------------- TailTwins

    // The tail-match mechanic is vacuous at 1:1: SQRT_1_1 = 2^96 has low byte 0, so requiredTail is
    // a constant 0 and every ForkDeploy fixture that inits at parity never exercises the gate. Init
    // OFF parity (low byte 0x37) so the required tail is nonzero and the gate actually binds.
    function test_TailTwins_tailBindsOffParity() public {
        address hook = _mineDeploy(BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA, type(TailTwins).creationCode);
        (PoolKey memory key, V4Router router) = _poolAt(hook, SQRT_ODD);
        TailTwins tt = TailTwins(hook);

        // (1) required tail is the price's low byte - nonzero here, unlike the 1:1 blind spot.
        uint256 tail = tt.requiredTail(key);
        console.log("TT requiredTail @init", tail);
        _eq(tail != 0, "requiredTail must be nonzero off parity (1:1 would give 0)");

        // (2) a size whose low byte is a half-ring away (circular distance 128 > tolerance 16) is
        //     rejected. Run this BEFORE the passing swap so the price - and thus the tail - is unmoved.
        uint256 pass = tt.acceptableAmountAtOrAbove(key, 1e18); // low byte == tail
        uint256 bad = (pass & ~uint256(0xff)) | ((tail + 128) & 0xff);
        if (bad == 0) bad = 0x100;
        _eq(
            _swapReverts(router, key, true, -int256(bad), TailTwins.TailMismatch.selector),
            "off-tail swap must revert TailMismatch"
        );
        console.log("TT off-tail swap reverted TailMismatch");

        // (3) a tail-matching size clears the gate and actually moves the price - proving the gate
        //     reads live slot0, not a frozen constant.
        _eq(tt.isAcceptable(key, pass), "matching-tail size must be acceptable");
        _swap(router, key, true, -int256(pass));
        (uint160 spAfter,,,) = PM.getSlot0(key.toId());
        _eq(spAfter != SQRT_ODD, "price must move after the swap (gate reads live price)");
        console.log("TT matching-tail swap OK; requiredTail now", tt.requiredTail(key));
    }
}
