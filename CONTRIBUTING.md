# Contributing a hook

This repo is the registry behind [aeon.fun/hooks](https://www.aeon.fun/hooks).
Adding a hook means adding one small JSON file; most of it is filled in for you.

## The short version

Open a **[Submit a hook](https://github.com/aeonfun/univ4-hooks/issues/new?template=submit-hook.yml)**
issue with a chain and a deployed hook address. The `analyze-hook` workflow decodes
the permission flags from the address, scaffolds `hooks/<slug>.json`, and opens a
PR. A maintainer fills any missing prose and merges. On merge, `hooklist.json` is
regenerated and the website picks up the new hook.

You can do the same by hand: run the scaffolder and open a PR.

```
python3 scripts/scaffold_hook.py --chain base --address 0x...  \
  --name MyHook --category Fees --mechanic "One-line summary."
python3 scripts/aggregate.py        # regenerate hooklist.json + HOOKS.md
python3 scripts/validate.py         # check before you push
```

## Why chain + address is enough

A Uniswap v4 hook must be deployed at an address whose **low 14 bits equal its
permission flags** (v4-core `Hooks.sol`). So the flags, the flag bitmap, and the
exact set of callbacks a hook implements are all decoded from the address - you
never type them, and CI rejects any file where they disagree with the address.

## The format

One file per hook: `hooks/<slug>.json`, where `<slug>` is the kebab-case name.
Validated against `schema.json`. Fields:

| Field | Who sets it | Notes |
|-------|-------------|-------|
| `name` | you | contract name as listed; the filename is `slugify(name).json` |
| `source` | maintainer | `aeon` (fleet) or `community` |
| `verified` | maintainer | community hooks are `false` until they clear aeon's gates |
| `category` | you | `Fees` / `Rewards` / `Access` / `Games` / `Orders` / `Launch` |
| `klass` | you | `VALUE` (moves tokens) / `FEE` (dynamic LP fee) / `GATE` (yes/no on a swap) |
| `template` | you | `dynamic` / `noop` / `freeform` |
| `stage` | you | `template` / `deployed` / `frontend` |
| `flags` | derived | hex, e.g. `0x10C4`; must equal `address & 0x3FFF` |
| `addresses` | you | one address per chain (fleet hooks ship to all four) |
| `mechanic` | you | one-line tile summary |
| `plain` | you | plain-language modal explainer |
| `rules` | you | the exact rules it enforces, one per line |
| `auditUrl` | optional | link to an audit |
| `deployer` | optional | deployer address |
| `date` | you | first-listed date, ISO |

`flagBits` and `callbacks` are **not** stored - `scripts/aggregate.py` derives them
into `hooklist.json` so they can never drift from the address.

## Multi-chain hooks

aeon fleet hooks are the same contract deployed to several chains (the CREATE2 salt
is mined per chain, so each chain's address differs but shares the same low 14
bits). Those live in a single file with several entries under `addresses`. A
community hook is usually one chain, so one entry.

## What CI checks

`scripts/validate.py` (run by `.github/workflows/hooklist.yml` on every PR):

1. Each `hooks/*.json` matches `schema.json`.
2. The filename equals `slugify(name).json`.
3. `flags == address & 0x3FFF` for **every** address.
4. Chains are known (`chains.json`).
5. `community` hooks are not marked `verified`.

And `scripts/aggregate.py --check` fails the build if `hooklist.json` or `HOOKS.md`
is stale - regenerate with `python3 scripts/aggregate.py` and commit the result.

## Getting audited

A listed-but-unaudited hook can be put through aeon's three gates (static audit,
behavioral forge test, fork sim) via a
[Request an audit](https://github.com/aeonfun/univ4-hooks/issues/new?template=request-audit.yml)
issue. If it clears, `verified` flips to `true`.
