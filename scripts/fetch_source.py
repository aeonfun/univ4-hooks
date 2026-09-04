#!/usr/bin/env python3
"""Best-effort: fetch a hook's verified contract name from a block explorer.

Given a chain + address, ask the chain's explorer for the verified source and
return the ContractName. This is how the analyze-hook workflow auto-fills a
submission's name when the submitter left it blank - the flags already come from
the address, this just saves typing the name. Purely best-effort: any failure
(no API key, unverified, network error, unsupported chain) returns None and the
caller falls back to the submitted/derived name.

Etherscan-family chains use the unified v2 API and need ETHERSCAN_API_KEY.
Blockscout chains (Robinhood) are tried keylessly but may be Cloudflare-gated; if
so the fetch simply returns None and the caller uses the submitted name.

Usage:
  ETHERSCAN_API_KEY=... python3 scripts/fetch_source.py --chain base --address 0x...
"""
import argparse
import json
import os
import sys
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hooklib as hl

TIMEOUT = 15


def _get_json(url: str):
    req = urllib.request.Request(url, headers={"User-Agent": "univ4-hooks-analyzer"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return json.load(resp)


def _source_url(meta: dict, address: str, api_key: str) -> str:
    q = {"module": "contract", "action": "getsourcecode", "address": address}
    if meta["explorerApiType"] == "etherscan":
        q["chainid"] = meta["chainId"]
        q["apikey"] = api_key
    return meta["explorerApi"] + "?" + urllib.parse.urlencode(q)


def fetch_contract(chain: str, address: str, chains=None, api_key: str = None):
    """Return {"name": str, "verified": True} or None. Never raises."""
    try:
        chains = chains or hl.load_chains()
        meta = chains.get(chain)
        if not meta or "explorerApiType" not in meta:
            return None
        api_key = api_key if api_key is not None else os.environ.get("ETHERSCAN_API_KEY", "")
        if meta["explorerApiType"] == "etherscan" and not api_key:
            return None  # etherscan v2 requires a key
        data = _get_json(_source_url(meta, address, api_key))
        result = data.get("result")
        entry = result[0] if isinstance(result, list) and result else (result if isinstance(result, dict) else None)
        if not entry:
            return None
        name = (entry.get("ContractName") or "").strip()
        # Unverified contracts return an empty ContractName (and empty SourceCode).
        if not name or not (entry.get("SourceCode") or "").strip():
            return None
        return {"name": name, "verified": True}
    except Exception:
        return None


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--chain", required=True)
    p.add_argument("--address", required=True)
    args = p.parse_args()
    if not hl.ADDR_RE.match(args.address):
        p.error("address must be 0x + 40 hex chars")
    got = fetch_contract(args.chain, args.address)
    if not got:
        print("no verified source found (or no API key)", file=sys.stderr)
        sys.exit(1)
    print(got["name"])


if __name__ == "__main__":
    main()
