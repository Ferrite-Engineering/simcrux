# Keyboard & mouse reference

This is the complete default binding set for SimCrux. Shortcuts are written
macOS first; the platform modifier is ++cmd++ on macOS and ++ctrl++ on Linux and
Windows. Every action listed here is also reachable from the menu bar and — when
it can run — the command palette (++cmd+shift+p++ / ++ctrl+shift+p++), and every
binding can be changed in **Settings → Keyboard Shortcuts**.

## File {#file}

| Shortcut | Action |
|---|---|
| ++cmd+o++ / ++ctrl+o++ | Open Config… |
| ++cmd+i++ / ++ctrl+i++ | Import FuseSoC .core File… |
| ++cmd+w++ / ++ctrl+w++ | Close Tab |
| ++cmd+shift+w++ / ++ctrl+shift+w++ | Close Project |
| ++cmd+q++ / ++ctrl+q++ | Quit SimCrux — **Exit** on Linux and Windows |

## View {#view}

| Shortcut | Action |
|---|---|
| ++cmd+1++ / ++ctrl+1++ | Toggle Test Browser |
| ++cmd+2++ / ++ctrl+2++ | Toggle Inspector (the Details panel) |
| ++cmd+3++ / ++ctrl+3++ | Toggle Log Panel |
| ++cmd+shift+x++ / ++ctrl+shift+x++ | Open Cross-Probe Panel |
| ++cmd+backslash++ / ++ctrl+backslash++ | Split Pane Right |
| ++cmd+shift+k++ / ++ctrl+shift+k++ | Toggle Theme |

## Search {#search}

| Shortcut | Action |
|---|---|
| ++cmd+f++ / ++ctrl+f++ | Search… |
| ++cmd+shift+p++ / ++ctrl+shift+p++ | Command Palette… |

## Multi-project workspace {#workspace}

Both workspace bindings belong to the multi-project workspace feature.

| Shortcut | Action |
|---|---|
| ++cmd+p++ / ++ctrl+p++ | Switch Project… <span class="tier tier-pro">Pro</span> |
| ++cmd+shift+f++ / ++ctrl+shift+f++ | Search Across Projects… <span class="tier tier-pro">Pro</span> |

## Tools & help {#tools}

| Shortcut | Action |
|---|---|
| ++f5++ | Run Regression |
| ++cmd+shift+r++ / ++ctrl+shift+r++ | Re-run Selected Test |
| ++esc++ | Cancel Regression |
| ++cmd+shift+i++ / ++ctrl+shift+i++ | Tab Diagnostics… |
| ++cmd+shift+m++ / ++ctrl+shift+m++ | App Diagnostics… |
| ++cmd+comma++ / ++ctrl+comma++ | Settings… |
| ++f1++ | About SimCrux |

## Navigate {#navigate}

++f6++ / ++shift+f6++ moves keyboard focus to the next or previous region: the
toolbar, the Tests panel, the results table, the Details panel, the Log panel,
and the statistics strip with the status bar (or the start screen when no
project is open). Returning to a region puts focus back where it was.

Region traversal is the whole of keyboard navigation in SimCrux, so there is no
Navigate menu. ++cmd+shift+1++ / ++ctrl+shift+1++ and ++cmd+shift+2++ /
++ctrl+shift+2++ are unassigned and available for your own bindings in
**Settings → Keyboard Shortcuts**.

## Actions without a default binding {#unbound}

These actions ship with no key assigned. All of them are in the menu bar and the
command palette, and any of them can be given a binding in **Settings → Keyboard
Shortcuts**.

- Import RISC-V Architectural Tests…
- Import riscv-formal Checks…
- Close All Tabs
- Close Pane
- Focus Other Pane
- Move Tab to Other Pane
- Export Results…
- Show Test Trend Chart… <span class="tier tier-pro">Pro</span>
- Show Suite Trend Chart… <span class="tier tier-pro">Pro</span>
- Show Calendar Heatmap… <span class="tier tier-pro">Pro</span>
- Show Seed Failure Heatmap <span class="tier tier-pro">Pro</span>
- Show Flaky Tests… <span class="tier tier-pro">Pro</span>
- Configure Trend Retention… <span class="tier tier-pro">Pro</span>
- Dispatch PR Annotations <span class="tier tier-pro">Pro</span>
- Configure PR Annotations… <span class="tier tier-pro">Pro</span>
- Reopen Recent Project <span class="tier tier-pro">Pro</span>
- Pin Project Tab <span class="tier tier-pro">Pro</span>
- Close All Projects <span class="tier tier-pro">Pro</span>
- Manage Driver Plugins… <span class="tier tier-pro">Pro</span>
- Reload Driver Plugins <span class="tier tier-pro">Pro</span>
- Documentation
- Submit Issue…
- Check for Updates

!!! note "Move Tab to Other Pane"
    **Move Tab to Other Pane** has no default key by design. The gesture
    equivalent is dragging the tab onto the other pane, which is the faster path
    when both panes are visible.

## Dialog & overlay keys {#dialogs}

The keys that drive dialogs and overlays are fixed and not remappable. In the
command palette, **Search Tests**, the project switcher and cross-project
search:

| Key | Action |
|---|---|
| ++arrow-down++ | Next result |
| ++arrow-up++ | Previous result |
| ++enter++ | Activate the highlighted result |
| ++esc++ | Dismiss the overlay |

++esc++ also closes standard dialogs and the Tab Diagnostics drawer. Settings is
the exception: close it with its **✕** button.

## Panels & the results table {#panels}

These keys are fixed and not remappable.

| Key | Action |
|---|---|
| ++tab++ | Move between regions and controls; each results row is one stop (its check box). |
| ++enter++ on a results row | Open the test in the Details panel. |
| ++space++ on a results row | Toggle the row's check box. |
| ++cmd+shift+arrow-right++ / ++ctrl+shift+arrow-right++ (focus in the Tests panel) | Widen the Tests panel; the opposite arrow narrows it. |
| ++cmd+shift+arrow-left++ / ++ctrl+shift+arrow-left++ (focus in the Details panel) | Widen the Details panel; the opposite arrow narrows it. |
| ++cmd+shift+arrow-up++ / ++ctrl+shift+arrow-up++ (focus in the Log panel) | Grow the Log panel; the opposite arrow shrinks it. |

## Mouse {#mouse}

| Gesture | Action |
|---|---|
| Click a results-table row | Select the test and show it in the Details panel. |
| Click a column header | Sort by that column; click again to reverse. |
| Click a heatmap cell | Select that test. |
| Right-click (or long-press) a results-table row <span class="tier tier-pro">Pro</span> | Open the row menu: **Send selection to WaveCrux / NetCrux / LintCrux** under **Cross-probe to peer…**, **Re-run with seed N** (rows with a recorded seed), **Re-run all in this parameter group** (rows from a sweep) and **Show Trend Chart**. In open core the row has no menu. |
| Drag a tab onto another pane | Move the tab to that pane. |
| Hover a tab | Show a tooltip with the tab's full file path. |
| Right-click a tab | Open the tab menu — the file path, **Reveal in Finder / Explorer / Files**, and the close actions. |

## Customizing shortcuts {#customizing}

**Settings → Keyboard Shortcuts** is the full editor for the binding set. A
**Preset** chooser at the top loads a complete key map in one step —
**SimCrux (Default)** ships today — and reads **Custom** once you change any
binding. Press the pencil (**Change shortcut**) to capture new keys,
**Remove shortcut** to unbind an action, **Reset to default** for one action, or
**Reset all** for everything. Conflicts are flagged as you assign: a shared key
shows which other actions use it and which one wins. **Export…** and **Import…**
save and load the customized bindings as a `.crux-keymap.json` file — the way to
carry a binding set across machines or share it with a team.
