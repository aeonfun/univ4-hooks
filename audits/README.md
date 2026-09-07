# Fleet audits

Autonomous `sc-audit` reports for the aeon.fun Uniswap v4 hook fleet. Each hook's
verified on-chain Base source was audited threat-model-first (Slither + an agentic
invariant / access-control / oracle pass + a fuzz arm gated on findings) against the
full 11-class v4-hook checklist, with every vendored `@uniswap/v4-core` file
SHA-256-diffed against the genuine npm release. **All 12 hooks: CLEAN (0 confirmed).**

| Hook | Category | Full audit | Verdict | Date |
|------|----------|-----------|---------|------|
| BlockEcho | Games | [blockecho.md](./blockecho.md) | CLEAN (0) | 2026-09-07 |
| CapGate | Access | [capgate.md](./capgate.md) | CLEAN (0) | 2026-09-06 |
| CrownClash | Rewards | [crownclash.md](./crownclash.md) | CLEAN (0) | 2026-09-07 |
| DailyWindowGate | Access | [dailywindowgate.md](./dailywindowgate.md) | CLEAN (0) | 2026-09-07 |
| DynamicFee | Fees | [dynamicfee.md](./dynamicfee.md) | CLEAN (0) | 2026-09-07 |
| ExactInGate | Access | [exactingate.md](./exactingate.md) | CLEAN (0) | 2026-09-07 |
| HeavierHand | Access | [heavierhand.md](./heavierhand.md) | CLEAN (0) | 2026-09-07 |
| LegacyLedger | Rewards | [legacyledger.md](./legacyledger.md) | CLEAN (0) | 2026-09-07 |
| MarketHoursGate | Access | [markethoursgate.md](./markethoursgate.md) | CLEAN (0) | 2026-09-07 |
| NoOp | Access | [noop.md](./noop.md) | CLEAN (0) | 2026-09-07 |
| TailTwins | Games | [tailtwins.md](./tailtwins.md) | CLEAN (0) | 2026-09-07 |
| TotalizerTrap | Games | [totalizertrap.md](./totalizertrap.md) | CLEAN (0) | 2026-09-07 |

These are autonomous agent audits: thorough and case-exhaustive at the source level,
but not a substitute for a paid human audit. Each report's *Coverage and limitations*
section states exactly what was and was not machine-proven. Findings on first-party
hooks are operator-gated by policy; nothing here is under embargo (all clean).
