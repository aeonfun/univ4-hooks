#!/usr/bin/env python3
"""Unit tests for sync_source.py, no network or forge needed.

The fixture mirrors the Twigpine Wrap Hook build that broke weekly-sync on
2026-10-05: a standard-json verified build whose main file imports its own
helper by a relative path and its deps through remappings that do not exist in
this repo (`openzeppelin-contracts/`, `@uniswap/v4-core/` pointing under
lib/v4-periphery). Run: python3 -m unittest discover -s scripts -p "test_*.py"
"""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sync_source as ss

REMAPPINGS = [
    "@uniswap/v4-core/=lib/v4-periphery/lib/v4-core/",
    "openzeppelin-contracts/=lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/",
    "@openzeppelin/contracts/=lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/",
]
OZ = "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol"
POOL = "lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol"
BASE = "src/vendor/base/BaseHook.sol"
MAIN = "src/Wrap.sol"
SOURCES = {
    MAIN: (
        "// SPDX-License-Identifier: MIT\n"
        "pragma solidity 0.8.26;\n"
        'import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";\n'
        "import {\n    BaseHook\n} from \"./vendor/base/BaseHook.sol\";\n"
        "contract Wrap is BaseHook {}\n"
    ),
    BASE: (
        'import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";\n'
        'import "@openzeppelin/contracts/token/ERC20/IERC20.sol";\n'
        "abstract contract BaseHook {}\n"
    ),
    OZ: "interface IERC20 {}\n",
    POOL: "struct PoolKey { address a; }\n",
}
STANDARD_JSON = "{" + json.dumps({
    "language": "Solidity",
    "sources": {p: {"content": c} for p, c in SOURCES.items()},
    "settings": {"remappings": REMAPPINGS},
}) + "}"


class ResolveImport(unittest.TestCase):
    def test_relative(self):
        self.assertEqual(ss.resolve_import(MAIN, "./vendor/base/BaseHook.sol", []), BASE)
        self.assertEqual(ss.resolve_import(BASE, "../../Wrap.sol", []), MAIN)

    def test_remapping_longest_prefix_wins(self):
        self.assertEqual(ss.resolve_import(BASE, "@openzeppelin/contracts/token/ERC20/IERC20.sol", REMAPPINGS), OZ)
        self.assertEqual(ss.resolve_import(MAIN, "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol", REMAPPINGS), OZ)

    def test_context_remapping_only_applies_inside_its_context(self):
        rm = ["src/other/:x/=lib/a/", "x/=lib/b/"]
        self.assertEqual(ss.resolve_import("src/other/A.sol", "x/F.sol", rm), "lib/a/F.sol")
        self.assertEqual(ss.resolve_import("src/A.sol", "x/F.sol", rm), "lib/b/F.sol")

    def test_unmapped_is_left_as_written(self):
        self.assertEqual(ss.resolve_import(MAIN, "forge-std/Test.sol", REMAPPINGS), "forge-std/Test.sol")


class ParseSources(unittest.TestCase):
    def test_standard_json_keeps_remappings(self):
        sources, remappings = ss.parse_sources(STANDARD_JSON, "Wrap")
        self.assertEqual(set(sources), set(SOURCES))
        self.assertEqual(remappings, REMAPPINGS)

    def test_raw_single_file_has_no_remappings(self):
        sources, remappings = ss.parse_sources("contract Wrap {}", "Wrap")
        self.assertEqual(sources, {"src/Wrap.sol": "contract Wrap {}"})
        self.assertEqual(remappings, [])


class ProcessHook(unittest.TestCase):
    """End to end over a temp repo: every file of the build lands under
    src/vendor/<Name>/ and every import resolves to a file that exists."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        self._saved = (ss.hl.REPO_ROOT, ss.SRC_DIR, ss.fetch_source, ss.forge_build)
        ss.hl.REPO_ROOT = self.root
        ss.SRC_DIR = os.path.join(self.root, "src")
        sources, remappings = ss.parse_sources(STANDARD_JSON, "Wrap")
        ss.fetch_source = lambda meta, addr, key: ("Wrap", sources, remappings)
        self.hook = {"name": "Twig Wrap", "addresses": {"base": "0x" + "ab" * 20}}
        self.chains = {"base": {"chainId": 8453, "explorerApiType": "etherscan", "explorerApi": "x"}}

    def tearDown(self):
        ss.hl.REPO_ROOT, ss.SRC_DIR, ss.fetch_source, ss.forge_build = self._saved
        self.tmp.cleanup()

    def _imports_resolve(self, rel_path):
        path = os.path.join(self.root, rel_path)
        content = open(path).read()
        specs = [m.group(3) for m in ss.IMPORT_RE.finditer(content)]
        self.assertTrue(specs, rel_path)
        for spec in specs:
            self.assertTrue(spec.startswith("."), f"{rel_path}: {spec} not rewritten")
            self.assertTrue(os.path.isfile(os.path.normpath(os.path.join(os.path.dirname(path), spec))),
                            f"{rel_path}: {spec} does not exist")

    def test_vendors_whole_build_with_resolvable_imports(self):
        r = ss.process_hook(self.hook, self.chains, "key", write=True)
        self.assertEqual(r["status"], "added")
        self.assertEqual(r["file"], "src/TwigWrap.sol")
        self.assertEqual(r["vendor_dir"], "src/vendor/TwigWrap")
        for p in (BASE, OZ, POOL):
            self.assertTrue(os.path.isfile(os.path.join(self.root, "src/vendor/TwigWrap", p)), p)
        # nothing is written to the repo's own lib/, so forge auto-remapping is untouched
        self.assertFalse(os.path.exists(os.path.join(self.root, "lib")))
        self._imports_resolve("src/TwigWrap.sol")
        self._imports_resolve(f"src/vendor/TwigWrap/{BASE}")

    def test_verify_drops_a_hook_that_does_not_compile(self):
        ss.forge_build = lambda: (False, "Error (6275): Source not found")
        r = ss.process_hook(self.hook, self.chains, "key", write=True, verify=True)
        self.assertEqual(r["status"], "build-failed")
        self.assertIn("6275", r["error"])
        self.assertFalse(os.path.exists(os.path.join(self.root, "src/TwigWrap.sol")))
        self.assertFalse(os.path.exists(os.path.join(self.root, "src/vendor/TwigWrap")))

    def test_dry_run_writes_nothing(self):
        r = ss.process_hook(self.hook, self.chains, "key", write=False)
        self.assertEqual(r["status"], "added")
        self.assertFalse(os.path.exists(os.path.join(self.root, "src")))


if __name__ == "__main__":
    unittest.main()
