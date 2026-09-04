#!/usr/bin/env python3
"""Turn a 'Submit a hook' issue-form body into a hooks/<slug>.json scaffold.

Reads the issue body from $ISSUE_BODY (as GitHub issue forms render it: an
`### Field label` header followed by the value). Writes the scaffold and prints
its path on stdout for the workflow to commit. Unknown / missing fields fall back
to the scaffold defaults; a bad chain or address exits non-zero so the workflow
fails loudly and the maintainer handles it by hand.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hooklib as hl
from scaffold_hook import build_entry

# Maps a submit-hook.yml field label -> the build_entry kwarg it feeds.
LABEL_TO_KEY = {
    "chain": "chain",
    "hook address": "address",
    "hook name": "name",
    "category": "category",
    "one-line summary": "mechanic",
    "plain-language description": "plain",
    "rules": "_rules",
    "audit url": "audit_url",
    "deployer address": "deployer",
}

NONE_MARKERS = {"", "_no response_", "none", "n/a"}


def parse_body(body: str) -> dict:
    fields = {}
    # Split on '### ' headers; each chunk is "Label\n\nvalue...".
    for chunk in re.split(r"^###\s+", body, flags=re.MULTILINE)[1:]:
        head, _, rest = chunk.partition("\n")
        label = head.strip().lower()
        value = rest.strip()
        if value.lower() in NONE_MARKERS:
            value = ""
        fields[label] = value
    return fields


def main():
    body = os.environ.get("ISSUE_BODY", "")
    fields = parse_body(body)

    kwargs = {}
    for label, value in fields.items():
        key = LABEL_TO_KEY.get(label)
        if not key:
            continue
        if key == "_rules":
            kwargs["rules"] = [ln.strip("-* \t") for ln in value.splitlines() if ln.strip()]
        else:
            kwargs[key] = value

    chain = kwargs.pop("chain", "")
    address = kwargs.pop("address", "")
    if not chain or not address:
        sys.exit("issue is missing a chain or an address")

    # First-listed date = the submission date (overridable for reproducible runs).
    import datetime
    kwargs.setdefault("date", os.environ.get("SUBMISSION_DATE") or datetime.date.today().isoformat())

    entry = build_entry(chain, address, source="community", **kwargs)

    import json
    slug = hl.slugify(entry["name"])
    path = os.path.join(hl.HOOKS_DIR, slug + ".json")
    os.makedirs(hl.HOOKS_DIR, exist_ok=True)
    with open(path, "w") as f:
        f.write(json.dumps(entry, indent=2) + "\n")
    # stdout = path (consumed by the workflow); stderr = human summary.
    print(os.path.relpath(path, hl.REPO_ROOT))
    bits = int(entry["flags"], 16)
    print(
        f"{entry['name']} on {chain}: flags {entry['flags']} -> "
        f"{', '.join(hl.callbacks_of(bits)) or '(none)'}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
