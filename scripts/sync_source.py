#!/usr/bin/env python3
"""Backfill in-repo Solidity source for any listed hook that only has a registry
entry.

Scope is the repo itself: every hooks/<slug>.json already carries the hook's
name and its deployed address(es). This script finds the listings that have no
matching src/<Name>.sol, pulls the verified source from the chain's explorer
(using the address in the JSON), and writes it under src/ so all listed hooks
have source in-repo, not just a registry row. It never touches a hook that
already has a src file, and never overwrites an existing lib/ file.

For each missing hook it:
  - tries each address the listing has, on its chain, until one returns verified
    source (etherscan-family needs ETHERSCAN_API_KEY; blockscout is keyless);
  - extracts the main contract file and writes it to src/<Name>.sol verbatim,
    with comment long-dashes normalized to hyphens and a provenance header;
  - vendors every other file of the verified build (its own helpers and its lib/
    deps) under src/vendor/<Name>/, keeping the explorer paths, and rewrites the
    imports to relative paths into that copy. Each hook then compiles against the
    exact code it was verified with, independent of this repo's remappings and of
    every other hook's deps;
  - with --verify, runs forge build and drops the hook again if it does not
    compile, so one bad listing never breaks the build or the weekly sync.

Usage:
  python3 scripts/sync_source.py                 # dry run: report what is missing
  python3 scripts/sync_source.py --write         # write source + libs, emit summary
  python3 scripts/sync_source.py --write --verify  # also forge build, drop what fails
  ETHERSCAN_API_KEY=... python3 scripts/sync_source.py --write --verify

Writes sync_summary.md (for a PR body) when run with --write.
"""
import argparse
import json
import os
import posixpath
import re
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hooklib as hl

TIMEOUT = 20
SRC_DIR = os.path.join(hl.REPO_ROOT, "src")
VENDOR_DIR = os.path.join(SRC_DIR, "vendor")
UA = {"User-Agent": "univ4-hooks-sync"}
LONG_DASHES = (chr(0x2014), chr(0x2013))  # em dash, en dash -> normalized to '-'
# `import "x";`, `import "x" as y;`, `import {a, b} from "x";`, `import * as y from "x";`
IMPORT_RE = re.compile(r"""(\bimport\b[^;"']*?)(["'])([^"']+)\2""")


def src_filename(name: str) -> str:
    """PascalCase-ish Solidity filename from a hook name. 'Aegis DFM' -> 'AegisDFM'."""
    cleaned = re.sub(r"[^A-Za-z0-9]+", "", name)
    return cleaned or "Hook"


def _get_json(url: str):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return json.load(resp)


def _source_url(meta: dict, address: str, api_key: str) -> str:
    q = {"module": "contract", "action": "getsourcecode", "address": address}
    if meta["explorerApiType"] == "etherscan":
        q["chainid"] = meta["chainId"]
        q["apikey"] = api_key
    return meta["explorerApi"] + "?" + urllib.parse.urlencode(q)


def parse_sources(source_code: str, contract_name: str):
    """Explorer getsourcecode `SourceCode` -> ({path: content}, remappings). Handles
    the three shapes: `{{...}}` standard-json-input, a bare `{...}` sources map, and
    a raw single Solidity file. Remappings come from the standard-json settings
    (the ones the hook was verified with); the other shapes have none."""
    s = (source_code or "").strip()
    if s.startswith("{{") and s.endswith("}}"):
        obj = json.loads(s[1:-1])
        srcs = obj.get("sources", obj)
        remappings = (obj.get("settings") or {}).get("remappings") or []
        return {k: v.get("content", "") if isinstance(v, dict) else str(v) for k, v in srcs.items()}, remappings
    if s.startswith("{"):
        try:
            obj = json.loads(s)
            srcs = obj.get("sources", obj)
            if isinstance(srcs, dict) and srcs:
                return {k: (v.get("content", "") if isinstance(v, dict) else str(v)) for k, v in srcs.items()}, []
        except json.JSONDecodeError:
            pass
    # raw single-file source
    return {f"src/{contract_name or 'Hook'}.sol": source_code}, []


def pick_main_file(sources: dict, contract_name: str):
    """The file that declares the deployed contract. Prefer a non-lib file whose
    body defines `contract <ContractName>`; fall back to any file that does; then
    to the sole non-lib file."""
    decl = re.compile(r"\b(?:abstract\s+contract|contract)\s+" + re.escape(contract_name) + r"\b")
    non_lib = {p: c for p, c in sources.items() if not p.startswith("lib/")}
    for pool in (non_lib, sources):
        for path, content in pool.items():
            if decl.search(content or ""):
                return path, content
    if len(non_lib) == 1:
        return next(iter(non_lib.items()))
    return None, None


def resolve_import(importer: str, spec: str, remappings) -> str:
    """The source path an import points at, the way solc resolves it for the
    verified build: relative to the importing file, else through the longest
    matching remapping (`[context:]prefix=target`), else as written."""
    if spec.startswith("."):
        return posixpath.normpath(posixpath.join(posixpath.dirname(importer), spec))
    best = None
    for r in remappings:
        ctx, _, rule = r.rpartition(":")
        prefix, _, target = rule.partition("=")
        if not prefix or (ctx and not importer.startswith(ctx)):
            continue
        if spec.startswith(prefix) and (best is None or len(prefix) > len(best[0])):
            best = (prefix, target)
    return best[1] + spec[len(best[0]):] if best else spec


def rewrite_imports(path: str, content: str, dests: dict, remappings) -> str:
    """Point every import that resolves to a file of the verified build at that
    file's vendored copy, as a path relative to where `path` itself is written.
    Imports that resolve to nothing in the build are left as written."""
    here = posixpath.dirname(dests[path])

    def sub(m):
        target = resolve_import(path, m.group(3), remappings)
        if target not in dests:
            return m.group(0)
        rel = posixpath.relpath(dests[target], here)
        if not rel.startswith("."):
            rel = "./" + rel
        return f"{m.group(1)}{m.group(2)}{rel}{m.group(2)}"

    return IMPORT_RE.sub(sub, content)


def normalize_dashes(text: str) -> str:
    for d in LONG_DASHES:
        text = text.replace(d, "-")
    return text


def inherits_aeonfee(main_content: str, sources: dict) -> bool:
    if re.search(r"\bis\b[^{]*\bAeonFee\b", main_content):
        return True
    return any("AeonFee" in p or "abstract contract AeonFee" in (c or "") for p, c in sources.items())


def provenance_header(name, entries, has_fee, vendor_dir=None):
    lines = [
        "",
        "// SOURCE VERIFIED ON THE CHAIN EXPLORER - vendored here by scripts/sync_source.py",
        "// (comment long-dashes normalized to hyphens; no code or logic change).",
    ]
    if vendor_dir:
        lines.append(f"// Its deps are the verified build's own files under {vendor_dir}/, imports rewritten to them.")
    for chain, addr, cid in entries:
        lines.append(f"//   {chain} ({cid}): {addr}")
    if not has_fee:
        lines += [
            "// NOTE: this hook does NOT inherit AeonFee, so it takes no 10 bps protocol",
            "// fee onchain, unlike the AeonFee reference hooks in this dir.",
        ]
    return "\n".join(lines)


def insert_header(body: str, header: str) -> str:
    lines = body.split("\n")
    # keep SPDX + pragma at the very top if present, insert header after them
    at = 0
    if lines and lines[0].lstrip().startswith("// SPDX"):
        at = 1
        if len(lines) > 1 and lines[1].lstrip().startswith("pragma"):
            at = 2
    return "\n".join(lines[:at] + header.split("\n") + lines[at:])


def fetch_source(meta, address, api_key):
    """Return (contract_name, sources_dict, remappings) or None. Never raises."""
    try:
        if meta["explorerApiType"] == "etherscan" and not api_key:
            return None
        data = _get_json(_source_url(meta, address, api_key))
        result = data.get("result")
        entry = result[0] if isinstance(result, list) and result else (result if isinstance(result, dict) else None)
        if not entry:
            return None
        cname = (entry.get("ContractName") or "").strip()
        sc = entry.get("SourceCode") or ""
        if not cname or not sc.strip():
            return None
        return (cname, *parse_sources(sc, cname))
    except Exception:
        return None


def forge_build():
    """(ok, first error line) for a forge build of the whole repo."""
    try:
        r = subprocess.run(["forge", "build"], cwd=hl.REPO_ROOT, capture_output=True, text=True)
    except FileNotFoundError:
        return False, "forge not installed"
    if r.returncode == 0:
        return True, ""
    out = (r.stderr + "\n" + r.stdout).splitlines()
    err = next((ln.strip() for ln in out if "Error" in ln), out[-1].strip() if out else "forge build failed")
    return False, err


def process_hook(hook, chains, api_key, write, verify=False):
    """Returns a dict describing the outcome for one listing."""
    name = hook["name"]
    fname = src_filename(name)
    dest = os.path.join(SRC_DIR, fname + ".sol")
    slug = hl.slugify(name)
    if os.path.exists(dest):
        return {"slug": slug, "name": name, "status": "has-source"}

    addresses = hook.get("addresses", {}) or {}
    tried = []
    for chain, addr in addresses.items():
        meta = chains.get(chain)
        if not meta or not hl.ADDR_RE.match(addr or ""):
            tried.append(f"{chain}:bad-chain-or-addr")
            continue
        got = fetch_source(meta, addr, api_key)
        if not got:
            tried.append(f"{chain}:unverified-or-nokey")
            continue
        cname, sources, remappings = got
        main_path, main_content = pick_main_file(sources, cname)
        if not main_content:
            tried.append(f"{chain}:no-main-file")
            continue

        # Main file -> src/<Name>.sol; every other file of the verified build ->
        # src/vendor/<Name>/<explorer path>, so this hook's deps never collide with
        # the repo's lib/ or another hook's copy of the same lib.
        vendor_rel = f"src/vendor/{fname}"
        dests = {p: (f"src/{fname}.sol" if p == main_path else f"{vendor_rel}/{p}") for p in sources}
        vendored = sorted(p for p in sources if p != main_path)

        entries = [(c, a, chains[c]["chainId"]) for c, a in addresses.items() if c in chains]
        has_fee = inherits_aeonfee(main_content, sources)
        body = normalize_dashes(rewrite_imports(main_path, main_content, dests, remappings))
        body = insert_header(body, provenance_header(name, entries, has_fee, vendor_rel if vendored else None))

        result = {
            "slug": slug, "name": name, "status": "added",
            "file": f"src/{fname}.sol", "chain": chain, "address": addr,
            "contract": cname, "has_fee": has_fee, "vendored": vendored,
            "vendor_dir": vendor_rel,
        }
        if not write:
            return result

        vendor_abs = os.path.join(hl.REPO_ROOT, vendor_rel)
        shutil.rmtree(vendor_abs, ignore_errors=True)
        for path in vendored:
            dst = os.path.join(hl.REPO_ROOT, dests[path])
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(dst, "w") as f:
                f.write(normalize_dashes(rewrite_imports(path, sources[path], dests, remappings)))
        os.makedirs(SRC_DIR, exist_ok=True)
        with open(dest, "w") as f:
            f.write(body)

        if verify:
            ok, err = forge_build()
            if not ok:
                # never leave a listing's source in the tree if it breaks the build
                os.remove(dest)
                shutil.rmtree(vendor_abs, ignore_errors=True)
                return {"slug": slug, "name": name, "status": "build-failed",
                        "file": result["file"], "chain": chain, "address": addr, "error": err}
        return result
    return {"slug": slug, "name": name, "status": "no-verified-source", "tried": tried}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--write", action="store_true", help="write source + lib files")
    p.add_argument("--verify", action="store_true",
                   help="with --write: forge build after each added hook, drop it if it fails")
    args = p.parse_args()

    api_key = os.environ.get("ETHERSCAN_API_KEY", "")
    chains = hl.load_chains()

    results = [process_hook(hl.load_hook(pth), chains, api_key, args.write, args.verify and args.write)
               for pth in hl.hook_paths()]

    added = [r for r in results if r["status"] == "added"]
    missing = [r for r in results if r["status"] == "no-verified-source"]
    broken = [r for r in results if r["status"] == "build-failed"]
    has = [r for r in results if r["status"] == "has-source"]

    for r in added:
        fee = "AeonFee" if r["has_fee"] else "NO-AeonFee"
        extra = f" +{len(r['vendored'])} files in {r['vendor_dir']}/" if r["vendored"] else ""
        print(f"ADDED   {r['name']:<20} {r['file']}  [{r['chain']} {fee}]{extra}")
    warn = "::warning::" if os.environ.get("GITHUB_ACTIONS") else ""
    for r in broken:
        print(f"{warn}BROKEN  {r['name']:<20} {r['file']} does not compile, not added ({r['error']})")
    for r in missing:
        print(f"MISSING {r['name']:<20} no verified source ({', '.join(r['tried'])})")
    print(f"\n{len(has)} already sourced, {len(added)} added, {len(broken)} do not compile, "
          f"{len(missing)} still missing.")

    if args.write:
        lines = ["## Hook source sync", ""]
        if added:
            lines.append("Vendored verified source for listings that had none:")
            for r in added:
                fee = "inherits AeonFee" if r["has_fee"] else "**no AeonFee** (no 10 bps fee onchain)"
                lines.append(f"- `{r['file']}` - {r['name']} from {r['chain']} `{r['address']}` (`contract {r['contract']}`, {fee})")
                if r["vendored"]:
                    lines.append(f"  - {len(r['vendored'])} files of its verified build vendored under `{r['vendor_dir']}/`, imports rewritten to them")
        if broken:
            lines.append("")
            lines.append("Verified source found but it does not compile here, so it was left out:")
            for r in broken:
                lines.append(f"- {r['name']} from {r['chain']} `{r['address']}`: `{r['error']}`")
        if missing:
            lines.append("")
            lines.append("Still missing source (unverified onchain, or no explorer key for the chain):")
            for r in missing:
                lines.append(f"- {r['name']} ({', '.join(r['tried'])})")
        lines.append("")
        lines.append("Source is verbatim from the explorer (comment dashes normalized). "
                     "forge build + validate run in CI; fill any prose the listing still needs before merge.")
        with open(os.path.join(hl.REPO_ROOT, "sync_summary.md"), "w") as f:
            f.write("\n".join(lines) + "\n")

    # exit 0 always: "nothing to sync" is a normal weekly outcome
    return 0


if __name__ == "__main__":
    sys.exit(main())
