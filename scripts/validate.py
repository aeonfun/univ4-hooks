#!/usr/bin/env python3
"""Validate every hooks/*.json against schema.json and the v4 flag invariant.

Checks, per file:
  1. JSON Schema (schema.json).
  2. Filename == slugify(name).json  (one canonical file per hook).
  3. flags == (address & 0x3FFF) for EVERY address  (v4 encodes flags in the
     address' low 14 bits, so this must hold or the hook could never have been
     deployed).
  4. Every chain key is one we know (chains.json).
  5. verified/source agree (community submissions are never pre-verified).

Usage:
  python3 scripts/validate.py                  # all hooks
  python3 scripts/validate.py hooks/noop.json  # specific files
"""
import json
import os
import sys

import jsonschema

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hooklib as hl


def check_one(path, schema, chains, errors):
    rel = os.path.relpath(path, hl.REPO_ROOT)
    hook = hl.load_hook(path)

    try:
        jsonschema.validate(hook, schema)
    except jsonschema.ValidationError as e:
        loc = ".".join(str(p) for p in e.path) or "<root>"
        errors.append(f"{rel}: schema: {loc}: {e.message}")
        return  # further checks assume a well-formed doc

    want = hl.slugify(hook["name"]) + ".json"
    if os.path.basename(path) != want:
        errors.append(f"{rel}: filename should be {want} (from name {hook['name']!r})")

    flags = int(hook["flags"], 16)
    for chain, addr in hook["addresses"].items():
        if chain not in chains:
            errors.append(f"{rel}: unknown chain {chain!r} (see chains.json)")
            continue
        got = hl.flag_bits_of(addr)
        if got != flags:
            errors.append(
                f"{rel}: {chain} address flags {hl.flags_hex(got)} != declared {hook['flags']} "
                f"(a v4 hook's low 14 address bits ARE its flags)"
            )

    if hook["source"] == "community" and hook["verified"]:
        errors.append(f"{rel}: community submissions cannot be verified=true until they clear the gates")


def main():
    with open(hl.SCHEMA_PATH) as f:
        schema = json.load(f)
    chains = hl.load_chains()

    files = sys.argv[1:] or hl.hook_paths()
    if not files:
        print("No hook files to validate.")
        return

    errors = []
    for path in files:
        check_one(path, schema, chains, errors)

    if errors:
        print("\n".join(f"FAIL {e}" for e in errors))
        print(f"\n{len(errors)} error(s) across {len(files)} file(s).")
        sys.exit(1)
    print(f"OK: all {len(files)} hook file(s) valid.")


if __name__ == "__main__":
    main()
