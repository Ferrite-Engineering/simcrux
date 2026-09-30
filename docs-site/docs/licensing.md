# Tiers & licensing

Licensing terms are the same for all four EDACrux products, so the full
reference lives in one place on the suite site:
**[edacrux.app/licensing](https://edacrux.app/licensing)**.

## What each tier adds in SimCrux {#tiers}

| Tier | What it adds |
|---|---|
| Open Core | The complete regression runner: every simulator driver, every pass/fail detector, the results dashboard, the Details panel and Log Viewer, the last-10-runs history sparkline, exports, `--ci`, the FuseSoC and RISC-V importers, the web dashboard, and cross-probe. |
| <span class="tier tier-pro">Pro</span> | [Trend charts, flaky-test detection and seed / parameter sweeps](trends-and-flaky.md), [baseline comparison and PR annotations](baselines-ci-exports.md), [custom driver plugins](projects-and-simulators.md#plugins), and [multi-project workspaces](integrations.md#workspaces). |
| <span class="tier tier-enterprise">Enterprise</span> | The [team results database](team-database.md), [org-wide retention and distributed execution](administration.md) from the signed policy file, and the audit log. |
| <span class="tier tier-edu">EDU</span> | Every Pro feature, free for verified students, non-commercial. |

In the app, actions that need a paid tier carry a **PRO** badge in the command
palette and a tier suffix in the menu bar. The simulator drivers, the
detectors and the RISC-V compatibility verdict are never tier-gated.

## What the badges mean {#badges}

Open Core is free and open source: the whole runner in the first row of the
table, with no account, no key and no time limit. The Pro, Enterprise and EDU
rows ask for a license. Where a badged feature is the thing being asked
for, the app says so rather than quietly doing less — a sweep that is not
expanded is named in a warning banner, and a CI regression gate that resolves
below Pro fails the run instead of passing it.

## Entering a license key {#license-key}

The SimCrux download includes a **Settings → License** section. It is where a
key goes, and it is never tier-gated,
because it is how a first key gets in. A CI run takes its license as a file
instead; see [License tier in CI](cli.md#license-in-ci).
