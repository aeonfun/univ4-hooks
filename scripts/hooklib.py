#!/usr/bin/env python3
"""Shared helpers for the univ4-hooks hooklist: flag decoding, slugs, chains.

A Uniswap v4 hook encodes its permission flags in the low 14 bits of its own
address (see v4-core Hooks.sol). So the flags, the flag bitmap and the list of
callbacks a hook implements are all DERIVABLE from the address - a submitter only
has to give us a chain and an address. This module is the single source of truth
for that decode; validate.py, aggregate.py and scaffold_hook.py all import it.
"""
import json
import os
import re

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOKS_DIR = os.path.join(REPO_ROOT, "hooks")
CHAINS_PATH = os.path.join(REPO_ROOT, "chains.json")
SCHEMA_PATH = os.path.join(REPO_ROOT, "schema.json")

# The 14 v4 permission bits, high to low, with the labels the aeon.fun/hooks page
# renders. Order matters: callbacks() emits in this order. Labels use the site's
# short "ReturnDelta" spelling (not v4-core's "ReturnsDelta") so hooklist.json is
# a drop-in for the website.
FLAG_BITS = [
    (1 << 13, "beforeInitialize"),
    (1 << 12, "afterInitialize"),
    (1 << 11, "beforeAddLiquidity"),
    (1 << 10, "afterAddLiquidity"),
    (1 << 9, "beforeRemoveLiquidity"),
    (1 << 8, "afterRemoveLiquidity"),
    (1 << 7, "beforeSwap"),
    (1 << 6, "afterSwap"),
    (1 << 5, "beforeDonate"),
    (1 << 4, "afterDonate"),
    (1 << 3, "beforeSwapReturnDelta"),
    (1 << 2, "afterSwapReturnDelta"),
    (1 << 1, "afterAddLiquidityReturnDelta"),
    (1 << 0, "afterRemoveLiquidityReturnDelta"),
]

# The permission flags live in the low 14 bits of the address.
FLAG_MASK = 0x3FFF

CALLBACK_LABELS = [label for _, label in FLAG_BITS]

CATEGORIES = ["Fees", "Rewards", "Access", "Games", "Orders", "Launch"]
KLASSES = ["VALUE", "FEE", "GATE"]
TEMPLATES = ["dynamic", "noop", "freeform"]
STAGES = ["template", "deployed", "frontend"]
SOURCES = ["aeon", "community"]

ADDR_RE = re.compile(r"^0x[a-fA-F0-9]{40}$")
FLAGS_RE = re.compile(r"^0x[0-9A-Fa-f]{1,4}$")


def load_chains():
    with open(CHAINS_PATH) as f:
        return json.load(f)


def flag_bits_of(address: str) -> int:
    """The permission-flag integer encoded in an address' low 14 bits."""
    if not ADDR_RE.match(address):
        raise ValueError(f"not a 20-byte hex address: {address!r}")
    return int(address, 16) & FLAG_MASK


def flags_hex(bits: int) -> str:
    """Canonical flags string, e.g. 0x10C4 (upper-case nibbles, no padding)."""
    return "0x" + format(bits, "X")


def callbacks_of(bits: int) -> list:
    """The v4 callbacks a flag integer lights, high bit to low."""
    return [label for bit, label in FLAG_BITS if bits & bit]


def slugify(name: str) -> str:
    """Kebab-case slug used as the hook's JSON filename. 'Aegis DFM' -> 'aegis-dfm'."""
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return s


def hook_paths():
    if not os.path.isdir(HOOKS_DIR):
        return []
    return sorted(
        os.path.join(HOOKS_DIR, f)
        for f in os.listdir(HOOKS_DIR)
        if f.endswith(".json")
    )


def load_hook(path: str) -> dict:
    with open(path) as f:
        return json.load(f)
