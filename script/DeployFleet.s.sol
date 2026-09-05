// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Deploy ONE fleet hook to a target chain via the canonical CREATE2 proxy, at the
// mined address that carries the hook's v4 permission flag bits. Hook contract only
// (no demo pool) — the fork test (test/fork/ForkDeploy.t.sol) is the pool/swap gate.
//
// Simulate (dry-run, no key needed):
//   forge script script/DeployFleet.s.sol --sig 'run()' --fork-url <rpc>
// Broadcast (armed):
//   HOOK=DynamicFee forge script script/DeployFleet.s.sol --sig 'run()' \
//     --rpc-url <rpc> --private-key <burner> --broadcast --slow
//
// Env: HOOK (required, one of the 10 names), POOL_MANAGER (optional; defaults to the
//      Uniswap v4 Ethereum mainnet PoolManager).
//
// Self-contained (no forge-std): minimal Vm + console interfaces, matching this
// repo's test style, so the fleet build stays forge-std-free.

import {HookMiner} from "./HookMiner.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {DynamicFee} from "../src/DynamicFee.sol";
import {NoOp} from "../src/NoOp.sol";
import {HeavierHand} from "../src/HeavierHand.sol";
import {BlockEcho} from "../src/BlockEcho.sol";
import {TailTwins} from "../src/TailTwins.sol";
import {TotalizerTrap} from "../src/TotalizerTrap.sol";
import {CrownClash} from "../src/CrownClash.sol";
import {LegacyLedger} from "../src/LegacyLedger.sol";
import {ExactInGate} from "../src/ExactInGate.sol";
import {CapGate} from "../src/CapGate.sol";

interface Vm {
    function startBroadcast() external;
    function stopBroadcast() external;
    function envString(string calldata) external view returns (string memory);
    function envOr(string calldata, address) external view returns (address);
}

library console {
    address constant CONSOLE = 0x000000000000000000636F6e736F6c652e6c6f67;

    function log(string memory a, address b) internal view {
        _send(abi.encodeWithSignature("log(string,address)", a, b));
    }

    function log(string memory a, string memory b) internal view {
        _send(abi.encodeWithSignature("log(string,string)", a, b));
    }

    function log(string memory a, uint256 b) internal view {
        _send(abi.encodeWithSignature("log(string,uint256)", a, b));
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

contract DeployFleet {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    // Uniswap v4 Ethereum mainnet PoolManager (default target).
    address constant ETH_MAINNET_PM = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    uint160 constant AFTER_INITIALIZE = uint160(1 << 12);
    uint160 constant BEFORE_SWAP = uint160(1 << 7);
    uint160 constant AFTER_SWAP = uint160(1 << 6);
    uint160 constant AFTER_SWAP_RETURNS_DELTA = uint160(1 << 2);
    uint160 constant MASK = uint160(0x3FFF);

    function _select(string memory name) internal pure returns (uint160 flags, bytes memory code) {
        bytes32 k = keccak256(bytes(name));
        if (k == keccak256("DynamicFee")) {
            return
                (AFTER_INITIALIZE | BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA, type(DynamicFee).creationCode);
        }
        if (k == keccak256("NoOp")) {
            return (BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA, type(NoOp).creationCode);
        }
        if (k == keccak256("HeavierHand")) {
            return
                (AFTER_INITIALIZE | BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA, type(HeavierHand).creationCode);
        }
        if (k == keccak256("BlockEcho")) {
            return (BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA, type(BlockEcho).creationCode);
        }
        if (k == keccak256("TailTwins")) {
            return (BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA, type(TailTwins).creationCode);
        }
        if (k == keccak256("TotalizerTrap")) {
            return (BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA, type(TotalizerTrap).creationCode);
        }
        if (k == keccak256("ExactInGate")) {
            return (BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA, type(ExactInGate).creationCode);
        }
        if (k == keccak256("CapGate")) {
            return (BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA, type(CapGate).creationCode);
        }
        if (k == keccak256("CrownClash")) {
            return (AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA, type(CrownClash).creationCode);
        }
        if (k == keccak256("LegacyLedger")) {
            return (AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA, type(LegacyLedger).creationCode);
        }
        revert("unknown HOOK");
    }

    function run() external {
        address pm = vm.envOr("POOL_MANAGER", ETH_MAINNET_PM);
        string memory name = vm.envString("HOOK");
        (uint160 flags, bytes memory code) = _select(name);

        bytes memory ctorArgs = abi.encode(IPoolManager(pm));
        (address expected, bytes32 salt) = HookMiner.mine(flags, code, ctorArgs);

        console.log("hook name   ", name);
        console.log("poolManager ", pm);
        console.log("mined addr  ", expected);
        console.log("flags       ", uint256(flags));

        if (expected.code.length > 0) {
            console.log("ALREADY_DEPLOYED", expected);
            return;
        }

        bytes memory initCode = abi.encodePacked(code, ctorArgs);
        vm.startBroadcast();
        (bool ok,) = HookMiner.CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        vm.stopBroadcast();

        require(ok, "create2 deploy failed");
        require(expected.code.length > 0, "hook not deployed");
        require(uint160(expected) & MASK == (flags & MASK), "flag bits wrong");
        console.log("DEPLOYED    ", expected);
    }
}
