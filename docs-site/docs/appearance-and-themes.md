# Appearance & themes

SimCrux is themed by the shared `crux_theme` engine used across the EDACrux
suite, so a theme pack authored for one app applies to the others. Everything
that controls how SimCrux looks lives in one place: **Settings → Appearance**.

## Color theme presets {#presets}

Six color themes ship built in, under **Presets**. Selecting one recolors the
app immediately and the choice persists across launches. They are listed in the
order they appear in Settings.

| Preset | Brightness |
|---|---|
| Crux Dark | Dark (the default) |
| Crux Light | Light |
| Solarized Dark | Dark |
| High Contrast Dark | Dark |
| Oscilloscope | Dark |
| OLED XR | Dark |

Only one light preset ships — **Crux Light**. The other five are dark.

## Light and dark {#light-dark}

The active preset's brightness is what makes the app light or dark: pick
**Crux Light** and SimCrux goes light; pick any dark preset and it goes dark.
There is no separate System / Light / Dark setting.

**View → Toggle Theme** (++cmd+shift+k++ / ++ctrl+shift+k++) flips between
**Crux Dark** and **Crux Light** without opening Settings.

## Color overrides {#overrides}

On top of the active preset, individual named colors can be overridden one at a
time under **Color overrides**. SimCrux registers the suite's **Application
chrome** colors (scaffold, panel, toolbar, status bar, splitter and tab bar
colors); each has an
**Edit color** picker (hex, RGB or HSV) and **Reset to default**. Overrides are
saved with your settings and persist across launches. Test-status colors follow
the active preset and are not individually overridable.

## Theme packs {#packs}

A theme can be moved between machines, or shared, as a `.crux-theme.json` pack.
Under **Theme packs** in **Settings → Appearance**, **Import theme pack…** adds
a pack and **Export current theme…** saves the active theme as one. **Installed
packs** can be activated or uninstalled. Installed packs live in the `themes`
directory inside SimCrux's application-support folder.

!!! note "Localization"
    The **Presets**, **Color overrides** and **Theme packs** controls are not yet
    localized — they render in English whatever app language you have selected.

## What SimCrux does not have {#not-included}

Appearance covers color and the **Language** picker (English, 中文, 日本語,
한국어) — nothing else. SimCrux has no accent-color picker, no UI density
setting, and no font-size setting.
