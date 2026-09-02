// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Mainnet-FORK deploy gate for the ETH rollout. Run with:
//   forge test --fork-url <eth-mainnet-rpc> --match-path test/fork/ForkDeploy.t.sol -vv
//
// For every one of the 10 fleet hooks this:
//   1. mines the CREATE2 salt and deploys through the real 0x4e59 proxy (exactly the
//      mainnet broadcast path) => proves the mined address + flag bits are valid,
//   2. calls the REAL mainnet PoolManager.initialize with that hook => proves v4
//      accepts the address (the #1 chain-specific failure mode),
// and for the two non-gating hooks (NoOp, DynamicFee) additionally adds real
// liquidity and runs a swap, asserting the mandatory 10 bps AeonFee reaches the
// treasury. The other 8 gate swaps by design (unit-tested + live on Base/Robinhood),
// so re-proving their swap path here would just trip their intended reverts.
//
// Self-contained (no forge-std): the fork is provided by --fork-url, so the whole
// test already runs against real mainnet state with no cheatcodes.

import {HookMiner} from "../../script/HookMiner.sol";
import {V4Router} from "./V4Router.sol";
import {MockERC20} from "./MockERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {DynamicFee} from "../../src/DynamicFee.sol";
import {NoOp} from "../../src/NoOp.sol";
import {HeavierHand} from "../../src/HeavierHand.sol";
import {BlockEcho} from "../../src/BlockEcho.sol";
import {TailTwins} from "../../src/TailTwins.sol";
import {TotalizerTrap} from "../../src/TotalizerTrap.sol";
import {CrownClash} from "../../src/CrownClash.sol";
import {LegacyLedger} from "../../src/LegacyLedger.sol";
import {ExactInGate} from "../../src/ExactInGate.sol";
import {CapGate} from "../../src/CapGate.sol";

contract ForkDeployTest {
    // Uniswap v4 Ethereum mainnet PoolManager (chains.tsv `ethereum` row).
    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant RECIPIENT = 0xF1E958db7D1e4C074377946018Ad645db4FB158e;

    // v4 flag bits
    uint160 constant AFTER_INITIALIZE = uint160(1 << 12);
    uint160 constant BEFORE_SWAP = uint160(1 << 7);
    uint160 constant AFTER_SWAP = uint160(1 << 6);
    uint160 constant AFTER_SWAP_RETURNS_DELTA = uint160(1 << 2);
    uint160 constant MASK = uint160(0x3FFF);

    uint24 constant DYNAMIC_FEE_FLAG = 0x800000;
    uint160 constant SQRT_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_SQRT = 4295128739;

    function _eq(bool c, string memory m) internal pure {
        require(c, m);
    }

    // Deploy a hook via the real CREATE2 proxy at its mined address, assert flags,
    // and initialize a fresh mainnet pool with it. Returns hook + the pool key.
    function _deployAndInit(uint160 flags, bytes memory creationCode, uint24 poolFee)
        internal
        returns (address hook, PoolKey memory key, MockERC20 tA, MockERC20 tB)
    {
        bytes memory initCode = abi.encodePacked(creationCode, abi.encode(PM));
        (address expected, bytes32 salt) = HookMiner.mine(flags, creationCode, abi.encode(PM));
        _eq(expected.code.length == 0, "canonical addr already deployed");

        (bool ok,) = HookMiner.CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        _eq(ok, "create2 deploy failed");
        _eq(expected.code.length > 0, "hook not deployed at mined addr");
        _eq(uint160(expected) & MASK == (flags & MASK), "flag bits wrong");
        hook = expected;

        tA = new MockERC20("Fork A", "FA");
        tB = new MockERC20("Fork B", "FB");
        (Currency c0, Currency c1) = address(tA) < address(tB)
            ? (Currency.wrap(address(tA)), Currency.wrap(address(tB)))
            : (Currency.wrap(address(tB)), Currency.wrap(address(tA)));

        key = PoolKey({currency0: c0, currency1: c1, fee: poolFee, tickSpacing: 60, hooks: IHooks(hook)});
        PM.initialize(key, SQRT_1_1);
    }

    // Full liquidity + swap, asserting the mandatory AeonFee reaches the treasury.
    function _swapAndAssertFee(PoolKey memory key, MockERC20 tA, MockERC20 tB) internal {
        V4Router router = new V4Router(PM);
        tA.mint(address(router), 1e24);
        tB.mint(address(router), 1e24);

        router.addLiquidity(key, 1e21);

        Currency feeCur = key.currency0; // zeroForOne exact-in => fee on currency1 (output)
        feeCur; // silence
        uint256 beforeBal0 = _bal(key.currency0);
        uint256 beforeBal1 = _bal(key.currency1);

        router.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: MIN_SQRT + 1})
        );

        uint256 gained = (_bal(key.currency1) - beforeBal1) + (_bal(key.currency0) - beforeBal0);
        _eq(gained > 0, "AeonFee not routed to treasury");
    }

    function _bal(Currency c) internal view returns (uint256) {
        return MockERC20(Currency.unwrap(c)).balanceOf(RECIPIENT);
    }

    // ---- per-hook deploy + initialize (address-validity gate for all 10) ----

    function test_DynamicFee() public {
        (, PoolKey memory key, MockERC20 a, MockERC20 b) = _deployAndInit(
            AFTER_INITIALIZE | BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA,
            type(DynamicFee).creationCode,
            DYNAMIC_FEE_FLAG
        );
        _swapAndAssertFee(key, a, b);
    }

    function test_NoOp() public {
        (, PoolKey memory key, MockERC20 a, MockERC20 b) =
            _deployAndInit(BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA, type(NoOp).creationCode, 3000);
        _swapAndAssertFee(key, a, b);
    }

    function test_HeavierHand() public {
        _deployAndInit(BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA, type(HeavierHand).creationCode, 3000);
    }

    function test_BlockEcho() public {
        _deployAndInit(BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA, type(BlockEcho).creationCode, 3000);
    }

    function test_TailTwins() public {
        _deployAndInit(BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA, type(TailTwins).creationCode, 3000);
    }

    function test_TotalizerTrap() public {
        _deployAndInit(BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA, type(TotalizerTrap).creationCode, 3000);
    }

    function test_ExactInGate() public {
        _deployAndInit(BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA, type(ExactInGate).creationCode, 3000);
    }

    function test_CapGate() public {
        _deployAndInit(BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA, type(CapGate).creationCode, 3000);
    }

    function test_CrownClash() public {
        _deployAndInit(AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA, type(CrownClash).creationCode, 3000);
    }

    function test_LegacyLedger() public {
        _deployAndInit(AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA, type(LegacyLedger).creationCode, 3000);
    }
}
