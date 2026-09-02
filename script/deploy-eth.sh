#!/usr/bin/env bash
# deploy-eth.sh — deploy ONE aeon.fun v4 hook to Ethereum mainnet (or any v4 chain),
# reading the burner key INSIDE the script so it never lands on the analyzed command
# line (mirrors the aeon deploy-uni-hook / secretcurl convention).
#
# Usage:
#   ./script/deploy-eth.sh simulate  <HookName>          # dry-run against a mainnet fork
#   ./script/deploy-eth.sh broadcast <HookName>          # armed — real gas
#
# HookName: DynamicFee | NoOp | HeavierHand | BlockEcho | TailTwins | TotalizerTrap
#           | CrownClash | LegacyLedger | ExactInGate | CapGate
#
# Env:
#   HOOK_DEPLOYER_PRIVATE_KEY  (broadcast only) burner key; read here, not on the CLI
#   ETH_RPC_URL                RPC (default: https://ethereum-rpc.publicnode.com)
#   POOL_MANAGER               v4 PoolManager (default: ETH mainnet 0x0000…08A90)
#   HOOK_MAINNET_OK=1          required to broadcast to mainnet (opt-in lock)
#   MAX_GAS_GWEI               refuse to broadcast above this gas price (default 15)
#   ETHERSCAN_API_KEY          if set, auto-verify after broadcast (retries for CREATE2)
set -euo pipefail

MODE="${1:?usage: deploy-eth.sh <simulate|broadcast> <HookName>}"
HOOK="${2:?missing HookName}"
RPC_URL="${ETH_RPC_URL:-https://ethereum-rpc.publicnode.com}"
PM="${POOL_MANAGER:-0x000000000004444c5dc75cB358380D2e3dE08A90}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RPC_LABEL="$(printf '%s' "$RPC_URL" | sed -E 's#(https?://[^/]+).*#\1#')"
echo "deploy-eth: $MODE hook=$HOOK rpc=$RPC_LABEL poolManager=$PM"

if [ "$MODE" = "simulate" ]; then
  HOOK="$HOOK" POOL_MANAGER="$PM" \
    forge script script/DeployFleet.s.sol:DeployFleet --sig 'run()' --fork-url "$RPC_URL"
  exit 0
fi

[ "$MODE" = "broadcast" ] || { echo "unknown mode: $MODE" >&2; exit 2; }

: "${HOOK_DEPLOYER_PRIVATE_KEY:?set HOOK_DEPLOYER_PRIVATE_KEY to broadcast}"
if [ "${HOOK_MAINNET_OK:-}" != "1" ]; then
  echo "mainnet broadcast blocked: set HOOK_MAINNET_OK=1 to authorize" >&2
  exit 7
fi

KEY="$HOOK_DEPLOYER_PRIVATE_KEY"
DEPLOYER="$(cast wallet address --private-key "$KEY")"
BAL="$(cast balance "$DEPLOYER" --rpc-url "$RPC_URL" --ether)"
echo "deployer $DEPLOYER  balance ${BAL} ETH"
awk -v b="$BAL" 'BEGIN{exit !(b+0>0)}' || { echo "deployer unfunded — fund $DEPLOYER" >&2; exit 8; }

MAX_GAS_GWEI="${MAX_GAS_GWEI:-15}"
GP="$(cast gas-price --rpc-url "$RPC_URL")"
GPG="$(awk -v g="$GP" 'BEGIN{printf "%.3f", g/1e9}')"
echo "gas price ${GPG} gwei (cap ${MAX_GAS_GWEI})"
awk -v g="$GPG" -v c="$MAX_GAS_GWEI" 'BEGIN{exit !(g>c)}' \
  && { echo "gas ${GPG} gwei > cap ${MAX_GAS_GWEI} — refusing" >&2; exit 9; }

echo "!! MAINNET broadcast: $HOOK on Ethereum (chainId 1) — real gas"
LOG="$(mktemp)"
set +e
HOOK="$HOOK" POOL_MANAGER="$PM" \
  forge script script/DeployFleet.s.sol:DeployFleet --sig 'run()' \
    --rpc-url "$RPC_URL" --private-key "$KEY" --broadcast --slow 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e
[ "$rc" -ne 0 ] && { rm -f "$LOG"; exit "$rc"; }

ADDR="$(grep -oE '0x[a-fA-F0-9]{40}' <(grep -E 'DEPLOYED|ALREADY_DEPLOYED' "$LOG") | head -1)"
echo "── receipt: $HOOK → ${ADDR:-?}  (https://etherscan.io/address/${ADDR}) ──"

if [ -n "${ETHERSCAN_API_KEY:-}" ] && [ -n "$ADDR" ] && grep -q 'DEPLOYED ' "$LOG"; then
  CNAME="src/${HOOK}.sol:${HOOK}"
  CARGS="$(cast abi-encode 'constructor(address)' "$PM")"
  echo "── verify $CNAME (retries for CREATE2 indexing) ──"
  for i in 1 2 3 4 5 6; do
    if forge verify-contract "$ADDR" "$CNAME" --chain-id 1 \
         --etherscan-api-key "$ETHERSCAN_API_KEY" --constructor-args "$CARGS" --watch 2>&1 \
         | grep -qiE 'Pass - Verified|successfully verified|already verified'; then
      echo "  verify OK (attempt $i)"; break
    fi
    echo "  verify attempt $i not confirmed — explorer still indexing"; [ "$i" -lt 6 ] && sleep 30
  done
fi
rm -f "$LOG"
