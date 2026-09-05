# Deployments

Fleet deployed across Base (8453), Robinhood Chain (4663), Ethereum (1), and
Monad (143). Base/Robinhood and Ethereum/Monad were deployed in separate rounds,
so each hook's mined CREATE2 address differs per chain. All source verified:
Basescan (Base), Blockscout (Robinhood), Etherscan (Ethereum), Sourcify (Monad,
all 10 exact_match).

| Hook | Base (8453) | Robinhood (4663) | Ethereum (1) | Monad (143) |
|------|-------------|------------------|--------------|-------------|
| DynamicFee | 0x723b16eF13a1b9A2BD63238BEC47cDF1d4A010C4 | 0x7566a3BFbE88C06BC5F33FEA927f461e8279d0C4 | 0x80F48fDCa095D081a3fE7843AB234C5533a450c4 | 0x86037d62EceCd7E380984Ad9d24dd0c5112d50C4 |
| NoOp | 0xFBa729A7d8fc48cBb261A845A0f26281ED7800C4 | 0x8EF1699f78F830375239F6f3165cB72D5b64c0c4 | 0xc8FA143077D632A056a9A970cE71E3BdcF01C0c4 | 0x707A3072E285A2e2398253A30Bf6Bd7b5a7B40c4 |
| HeavierHand | 0x69072454d019C4167007C070Ee49CF06c8aC50C4 | 0x368575b8712E7A6b56B309F6b3CE20549e9C90C4 | 0xBc674333E0f06C24b164deE6bdE1CaA3e44710c4 | 0x4429A70F33907c1b5f7471675D56cDF5090190c4 |
| BlockEcho | 0x5e48f905661D75501CA756eDB3403dA98F0400C4 | 0xf2f992Fe611f64ECFcc413c420F558C85A7480c4 | 0x66F4a8433885d2838AE760393c3BDbdCBd8D40C4 | 0x15d90705718D052D32eB8e34271E8743C26E40C4 |
| TailTwins | 0x9818dDD1102c9606Cd693aC17A7B8B17609480c4 | 0x971Df49844604E44514120682eAc3fcDC4F5C0c4 | 0x50220C80DA4280afB2D86AD4a6B28f9dfF46C0c4 | 0x75e7B5A738884F37086c2Be7789A883Ca6ce80C4 |
| TotalizerTrap | 0xA7a62422d13C7648cA53ad91E9268ac4bFC6C0c4 | 0x1e27183E12a9C108DD850E022f26870B12a200C4 | 0x190bCa1A2f6CAd09efAE5d0BAb9564553Ba640C4 | 0x57E6efF5Cc442EFeEebB79D108CCb7C01086c0c4 |
| CrownClash | 0xD24D29a47Adb8786072Ab2Cb9925dC8Ba36Bc044 | 0xcbbc0818c555bFf795a2ab6261D224E793678044 | 0xb09AbA41D397474e6C25a625f87eF8c200480044 | 0xb268D7930580E7717B72804190FE910d2c200044 |
| LegacyLedger | 0xDb4a0eb0410407d6C22A35c27288834e0D9F4044 | 0x70dEc3A54943fd96Fe460ff74172038F57208044 | 0x9c9f5e18c8530E96c735704471542E72a7a00044 | 0xf50C9B994A5A0Aba3EB1b7E044f88B2f12f1c044 |
| ExactInGate | 0xeC78eE3F1FC117415a8006A0344Ccaff30aa40C4 | 0x2c10AfB513a6505beFB74dFdF5800B392C9f00c4 | 0x95c9Fa3cd4067A0fd69fB41D291C79193B5500C4 | 0x7810753D326c0E4b9755b5FA09a8b8998C75C0C4 |
| CapGate | 0xa12bF4fC954B37cbe7Acc2fA652328071F8b00c4 | 0x57777eb796b2b01AeF0A0a6752217C5DBe9a00C4 | 0x62Edc83Dc155F9dE77A58c65D9AD5762158f00c4 | 0x00f39795c6d49B24de38a232b0F5d4BDfe4200c4 |

Treasury (AeonFee recipient), all chains: 0xF1E958db7D1e4C074377946018Ad645db4FB158e

Uniswap v4 PoolManager per chain: Base 0x498581fF718922c3f8e6a244956aF099B2652b2b,
Robinhood 0x8366a39Cc670B4001A1121B8F6a443a643E40951, Ethereum
0x000000000004444c5dc75cB358380D2e3dE08A90, Monad
0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e.

## HeavierHand + CapGate: price-anchored redeploy (2026-09-05)

HeavierHand and CapGate were redeployed with corrected logic. HeavierHand now
anchors its skew band to the pool's OWN initialization price instead of an implicit
1.0 (it gained an `afterInitialize` callback, so its flags are now `0x10C4`), which
fixes a pool being permanently one-directional on any pair that is not a
same-decimals 1:1. CapGate now caps each swap at 5% of the pool's virtual reserve of
the token being spent instead of a fixed `100e18` token count, so the cap is
decimals-safe. The addresses in the table above are the NEW ones; coverage was also
extended to Arbitrum, BNB Chain, and Unichain:

| Hook | Arbitrum (42161) | BNB Chain (56) | Unichain (130) |
|------|------------------|----------------|----------------|
| HeavierHand | 0xdaC850494b2A31c21b8AB6d22c4Af846A9f790c4 | 0x26589E4873E7F5E0F3e0D20782A61c2495Fe90c4 | 0xC3bFb8010F83E013FE9DE2525A8Be575310BD0c4 |
| CapGate | 0x81e4FDB9a9787800aef889bA112AAdddd43C80c4 | 0x58CAA0d759D282d4C505a15681d8Dd3A724580c4 | 0x27D5FDf460643EB270B6E836d218968D6D7400C4 |

PoolManager for the added chains: Arbitrum
0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32, BNB Chain
0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9df, Unichain
0x1F98400000000000000000000000000000000004.

Superseded HeavierHand + CapGate addresses (immutable, still on-chain, do NOT use):
HeavierHand Base 0x2AD6936032d4201fc74041AfbC801FAAb1bf40c4, Robinhood
0x6Df3BeBfBeC267221b819aC30Bb32e2F02C700c4, Ethereum
0x240339F2114F066016f36639e522a8A9C3b840c4, Monad
0x6F0FE61cae116edC23F00E74eB8604ADef4800c4. CapGate Base
0x0A914acb246063B4ED0F3a0FC13D0C0e8C8500c4, Robinhood
0x6B567e25CC6E9d77f1A030A68Db39F86c03540c4, Ethereum
0xfebC2D261c006409eD765bAcfF039846770280C4, Monad
0xD4F21c282c7c1e8098D511039Ad39044488cC0c4.

## Deploying

Every hook is deployed through the canonical CREATE2 proxy
(0x4e59b44847b379578588920cA78FbF26c0B4956C) at a mined salt so the address' low
14 bits carry the hook's v4 permission flags. See `script/HookMiner.sol`,
`script/DeployFleet.s.sol`, and the wrapper `script/deploy-eth.sh`. The mainnet
deploy is gated behind `test/fork/ForkDeploy.t.sol` (a mainnet-fork run of all 10:
CREATE2 deploy + real PoolManager.initialize, plus a live swap on NoOp/DynamicFee
asserting the AeonFee reaches the treasury).

Any v4 chain uses the same chain-agnostic path: `HOOK=<name>
POOL_MANAGER=<chain-pool-manager> forge script
script/DeployFleet.s.sol:DeployFleet --sig 'run()' --rpc-url <rpc>
--private-key <burner> --broadcast --slow`, then verify with the chain's verifier
(e.g. Monad on Sourcify: `--verifier sourcify --verifier-url
https://sourcify-api-monad.blockvision.org/ --chain-id 143`). `deploy-eth.sh` is
Ethereum-only (its defaults, the `HOOK_MAINNET_OK` lock, and its Etherscan
chain-id 1 verify step); use the raw forge command above for other v4 chains.
