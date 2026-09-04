#!/usr/bin/env python3
"""Scaffold a hooks/<slug>.json from a chain + address (+ optional metadata).

The v4 permission flags and callbacks are decoded straight from the address, so a
submitter only has to supply a chain and an address; a reviewer then fills the
prose (mechanic / plain / rules) and the semantic tags (category / klass). This
is what the analyze-hook workflow runs on a new submission issue.

Usage:
  python3 scripts/scaffold_hook.py --chain base --address 0x... \\
      [--name Foo] [--source community] [--category Fees] [--klass FEE] \\
      [--mechanic "..."] [--plain "..."] [--rule "..." --rule "..."] \\
      [--date 2026-09-04] [--stdout]
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hooklib as hl

# A rough klass guess from the flags, so the scaffold has a sensible default the
# reviewer can correct. Return-delta bits => it moves value; otherwise it gates.
def guess_klass(bits):
    return_delta = bits & (0b1111)  # low 4 = the four *ReturnDelta bits
    if return_delta:
        return "VALUE"
    return "GATE"


def build_entry(chain, address, name="", source="community", category="Access",
                klass="", template="freeform", stage="deployed", mechanic="",
                plain="", rules=None, audit_url="", deployer="", date=""):
    """The canonical hook entry, with flags + callbacks decoded from the address.
    Shared by the CLI and the analyze-hook workflow. Raises ValueError on a bad
    chain or address so callers can report it."""
    chains = hl.load_chains()
    if chain not in chains:
        raise ValueError(f"unknown chain {chain!r}; known: {', '.join(chains)}")
    if not hl.ADDR_RE.match(address):
        raise ValueError("address must be 0x + 40 hex chars")

    bits = hl.flag_bits_of(address)
    name = (name or "").strip() or f"Hook {address[:6]}"
    entry = {
        "name": name,
        "source": source,
        "verified": False,
        "category": category if category in hl.CATEGORIES else "Access",
        "klass": klass if klass in hl.KLASSES else guess_klass(bits),
        "template": template if template in hl.TEMPLATES else "freeform",
        "stage": stage if stage in hl.STAGES else "deployed",
        "flags": hl.flags_hex(bits),
        "addresses": {chain: address},
        "mechanic": (mechanic or "").strip() or "TODO: one-line summary of what this hook does.",
        "plain": (plain or "").strip() or "TODO: plain-language explainer for the modal.",
        "rules": [r for r in (rules or []) if r.strip()] or ["TODO: first rule the hook enforces."],
        "date": date or "TODO-YYYY-MM-DD",
    }
    if audit_url:
        entry["auditUrl"] = audit_url
    if deployer:
        entry["deployer"] = deployer
    return entry


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--chain", required=True, help="chain key (see chains.json)")
    p.add_argument("--address", required=True)
    p.add_argument("--name", default="")
    p.add_argument("--source", default="community", choices=hl.SOURCES)
    p.add_argument("--category", default="Access", choices=hl.CATEGORIES)
    p.add_argument("--klass", default="", choices=[""] + hl.KLASSES)
    p.add_argument("--template", default="freeform", choices=hl.TEMPLATES)
    p.add_argument("--stage", default="deployed", choices=hl.STAGES)
    p.add_argument("--mechanic", default="")
    p.add_argument("--plain", default="")
    p.add_argument("--rule", action="append", dest="rules", default=[])
    p.add_argument("--audit-url", default="")
    p.add_argument("--deployer", default="")
    p.add_argument("--date", default="")
    p.add_argument("--stdout", action="store_true", help="print JSON instead of writing a file")
    args = p.parse_args()

    try:
        entry = build_entry(
            args.chain, args.address, name=args.name, source=args.source,
            category=args.category, klass=args.klass, template=args.template,
            stage=args.stage, mechanic=args.mechanic, plain=args.plain,
            rules=args.rules, audit_url=args.audit_url, deployer=args.deployer,
            date=args.date,
        )
    except ValueError as e:
        p.error(str(e))

    name = entry["name"]
    bits = int(entry["flags"], 16)
    blob = json.dumps(entry, indent=2) + "\n"
    if args.stdout:
        sys.stdout.write(blob)
        return

    slug = hl.slugify(name)
    path = os.path.join(hl.HOOKS_DIR, slug + ".json")
    os.makedirs(hl.HOOKS_DIR, exist_ok=True)
    with open(path, "w") as f:
        f.write(blob)
    print(os.path.relpath(path, hl.REPO_ROOT))
    print(f"flags {entry['flags']} -> callbacks: {', '.join(hl.callbacks_of(bits)) or '(none)'}", file=sys.stderr)


if __name__ == "__main__":
    main()
