// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Measures the REAL mainnet deploy gas per hook (CREATE2 via the 0x4e59 proxy,
// hook contract only — no demo pool). Run:
//   forge test --fork-url <rpc> --match-path test/fork/GasProbe.t.sol -vv
import {HookMiner} from "../../script/HookMiner.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
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

contract GasProbeTest {
    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    uint160 constant AI = uint160(1 << 12);
    uint160 constant BS = uint160(1 << 7);
    uint160 constant AS = uint160(1 << 6);
    uint160 constant ASD = uint160(1 << 2);

    event DeployGas(string name, uint256 gasUsed, uint256 initCodeBytes);

    function _probe(string memory name, uint160 flags, bytes memory code) internal {
        bytes memory init = abi.encodePacked(code, abi.encode(PM));
        (, bytes32 salt) = HookMiner.mine(flags, code, abi.encode(PM));
        uint256 g = gasleft();
        (bool ok,) = HookMiner.CREATE2_DEPLOYER.call(abi.encodePacked(salt, init));
        uint256 used = g - gasleft();
        require(ok, "deploy failed");
        emit DeployGas(name, used, init.length);
    }

    function test_gas_all() public {
        _probe("DynamicFee", AI | BS | AS | ASD, type(DynamicFee).creationCode);
        _probe("NoOp", BS | AS | ASD, type(NoOp).creationCode);
        _probe("HeavierHand", BS | AS | ASD, type(HeavierHand).creationCode);
        _probe("BlockEcho", BS | AS | ASD, type(BlockEcho).creationCode);
        _probe("TailTwins", BS | AS | ASD, type(TailTwins).creationCode);
        _probe("TotalizerTrap", BS | AS | ASD, type(TotalizerTrap).creationCode);
        _probe("ExactInGate", BS | AS | ASD, type(ExactInGate).creationCode);
        _probe("CapGate", BS | AS | ASD, type(CapGate).creationCode);
        _probe("CrownClash", AS | ASD, type(CrownClash).creationCode);
        _probe("LegacyLedger", AS | ASD, type(LegacyLedger).creationCode);
    }
}
