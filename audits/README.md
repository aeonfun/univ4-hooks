# Fleet audits

Autonomous `sc-audit` reports for the aeon.fun Uniswap v4 hook fleet. Each hook's
verified on-chain Base source was audited threat-model-first (Slither + an agentic
invariant / access-control / oracle pass + a fuzz arm gated on findings) against the
full 11-class v4-hook checklist, with every vendored `@uniswap/v4-core` file
SHA-256-diffed against the genuine npm release. **All 12 hooks: CLEAN (0 confirmed).** Community hooks audited on request are listed below the fleet rows.

| Hook | Category | Full audit | Marketplace | Verdict | Date |
|------|----------|-----------|-------------|---------|------|
| BlockEcho | Games | [blockecho.md](./blockecho.md) | [aeon.fun/hooks](https://www.aeon.fun/hooks?hook=blockecho) | CLEAN (0) | 2026-09-07 |
| CapGate | Access | [capgate.md](./capgate.md) | [aeon.fun/hooks](https://www.aeon.fun/hooks?hook=capgate) | CLEAN (0) | 2026-09-06 |
| CrownClash | Rewards | [crownclash.md](./crownclash.md) | [aeon.fun/hooks](https://www.aeon.fun/hooks?hook=crownclash) | CLEAN (0) | 2026-09-07 |
| DailyWindowGate | Access | [dailywindowgate.md](./dailywindowgate.md) | [aeon.fun/hooks](https://www.aeon.fun/hooks?hook=dailywindowgate) | CLEAN (0) | 2026-09-07 |
| DynamicFee | Fees | [dynamicfee.md](./dynamicfee.md) | [aeon.fun/hooks](https://www.aeon.fun/hooks?hook=dynamicfee) | CLEAN (0) | 2026-09-07 |
| ExactInGate | Access | [exactingate.md](./exactingate.md) | [aeon.fun/hooks](https://www.aeon.fun/hooks?hook=exactingate) | CLEAN (0) | 2026-09-07 |
| HeavierHand | Access | [heavierhand.md](./heavierhand.md) | [aeon.fun/hooks](https://www.aeon.fun/hooks?hook=heavierhand) | CLEAN (0) | 2026-09-07 |
| LegacyLedger | Rewards | [legacyledger.md](./legacyledger.md) | [aeon.fun/hooks](https://www.aeon.fun/hooks?hook=legacyledger) | CLEAN (0) | 2026-09-07 |
| MarketHoursGate | Access | [markethoursgate.md](./markethoursgate.md) | [aeon.fun/hooks](https://www.aeon.fun/hooks?hook=markethoursgate) | CLEAN (0) | 2026-09-07 |
| NoOp | Access | [noop.md](./noop.md) | [aeon.fun/hooks](https://www.aeon.fun/hooks?hook=noop) | CLEAN (0) | 2026-09-07 |
| TailTwins | Games | [tailtwins.md](./tailtwins.md) | [aeon.fun/hooks](https://www.aeon.fun/hooks?hook=tailtwins) | CLEAN (0) | 2026-09-07 |
| TotalizerTrap | Games | [totalizertrap.md](./totalizertrap.md) | [aeon.fun/hooks](https://www.aeon.fun/hooks?hook=totalizertrap) | CLEAN (0) | 2026-09-07 |
| Twigpine Wrap Hook (community) | Orders | [twigpine-wrap-hook.md](./twigpine-wrap-hook.md) | [aeon.fun/hooks](https://www.aeon.fun/hooks?hook=twigpine-wrap-hook) | CLEAN (0 novel, 1 known low) | 2026-10-04 |

Each audit links back to its hook on the marketplace, and each hook on
[aeon.fun/hooks](https://www.aeon.fun/hooks) links to its full audit here - the two stay in sync via
the `auditUrl` field in `hooklist.json`.

These are autonomous agent audits: thorough and case-exhaustive at the source level,
but not a substitute for a paid human audit. Each report's *Coverage and limitations*
section states exactly what was and was not machine-proven. Findings on first-party
hooks are operator-gated by policy; nothing here is under embargo (all clean).
