// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Self-contained CREATE2 hook-address miner (no v4-periphery dependency).
//
// A Uniswap v4 hook's contract address must carry its callback permissions in the
// low 14 bits. We brute-force a CREATE2 salt (deployed through the canonical
// deterministic proxy 0x4e59...) until the resulting address' low bits == flags.
//
// `mine` is PURE (no per-iteration state access) so it is fast on a fork RPC. It
// returns the FIRST flag-matching salt, ignoring existing code. The first deploy of
// a given (creationCode, ctorArgs, flags) lands there deterministically; the caller
// does a single `hookAddress.code.length` check for idempotency before deploying.
library HookMiner {
    // Canonical Arachnid deterministic deployment proxy (present on every EVM chain,
    // including Ethereum mainnet). CREATE2 from here => address independent of nonce.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Low 14 bits: the full v4 hook-permission mask ((1 << 14) - 1).
    uint160 internal constant ALL_HOOK_MASK = uint160(0x3FFF);

    uint256 internal constant MAX_LOOP = 200_000;

    /// @notice First salt whose CREATE2 address' low 14 bits == `flags` (ignores code).
    function mine(uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        flags = flags & ALL_HOOK_MASK;
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));
        for (uint256 s; s < MAX_LOOP; s++) {
            hookAddress = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, bytes32(s), initCodeHash))))
            );
            if (uint160(hookAddress) & ALL_HOOK_MASK == flags) return (hookAddress, bytes32(s));
        }
        revert("HookMiner: no salt found");
    }
}
