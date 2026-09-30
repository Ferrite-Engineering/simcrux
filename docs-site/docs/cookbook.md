# Cookbook

The rest of these docs explain what each feature *is*. The Cookbook shows you
how to put them together to get something done. Each recipe is a complete task —
start with a project, end with an answer — written as numbered steps you can
follow at the keyboard. They are short on purpose: a recipe is a worked example,
not a manual.

!!! tip "No project handy?"
    Every recipe works against a project you already have, but if you want to
    follow along, the minimal `simcrux.yaml` in
    [Installation & first regression](getting-started.md#first-regression) is
    enough to start from.

## Recipes {#recipes}

| Recipe | What you do | Time · tier |
|---|---|---|
| [Run your first regression](cookbook-first-regression.md) | Write a `simcrux.yaml`, open the project, run it, read the dashboard, open a failing log, and hand it to WaveCrux. | ~10 min · Open Core |
| [Triage failures & open the waveform](cookbook-triage-failures.md) | Filter to failures, tell flaky from real with the trend chart, get a waveform, and trace the bug in WaveCrux. | ~10 min · Open Core + <span class="tier tier-pro">Pro</span> |
| [Hunt down flaky tests](cookbook-flaky-tests.md) | Open the Flaky Tests panel, read a flaky test's history, and reproduce a failing seed. | ~5 min · <span class="tier tier-pro">Pro</span> |
| [Run a seed sweep](cookbook-seed-sweep.md) | Add a seed range, run the sweep, find failing seeds, re-run one deterministically, and read the Seed Failure Heatmap. | ~10 min · <span class="tier tier-pro">Pro</span> |

## How each recipe is laid out {#how-recipes-work}

Every recipe opens with a short summary — the goal, a rough time, the tier you
need, and the features it exercises — followed by numbered steps. Keyboard
shortcuts are written macOS first (++cmd++), with the ++ctrl++ equivalent for
Linux and Windows. Where a step leans on a feature covered in depth elsewhere, it
links straight to that page so you can go deeper without leaving the workflow.

!!! note "More on the way"
    This is the opening set of recipes. If there is a regression workflow you
    keep repeating and would like written up — a nightly sign-off pass, a
    bring-up checklist, a CI migration — tell us at
    [support@ferriteengineering.com](mailto:support@ferriteengineering.com).
