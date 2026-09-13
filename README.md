# Launchpad

A full-screen application grid for [Omarchy](https://omarchy.org/)'s `omarchy-shell`, in the style of macOS Launchpad / the Ubuntu app drawer.

The grid mirrors the Super+Space menu's **Apps** section: same desktop-entry source, same fuzzy sort, and the same hidden-entry filtering. A first row surfaces recently and most-frequently launched apps; the rest of the library follows below.

## Install

Copy the plugin directory into your Omarchy shell plugins folder:

```sh
git clone https://github.com/xechoz/xechoz.launchpad ~/.config/omarchy/plugins/xechoz.launchpad
```

Then restart or reload the shell so it picks up the new plugin.

## Usage

Summon the pad:

```sh
omarchy-shell shell toggle xechoz.launchpad '{}'
```

Optional payload:

```json
{ "columns": 7, "recent": 4 }
```

- `columns` — number of grid columns (default `7`).
- `recent` — how many of the first row are the newest distinct apps; the row is filled to `columns` with the most frequently launched ones (default `-1`, i.e. fill by frequency only).

Launch counts are tracked locally while the pad is open and persisted to `~/.local/state/omarchy/launchpad-usage.json`.

Bind it in your Hyprland config, for example:

```
bind = SUPER, space, exec, omarchy-shell shell toggle xechoz.launchpad '{}'
```

## Files

- `Launchpad.qml` — the plugin implementation.
- `manifest.json` — Omarchy plugin manifest (`panel` + `menu` entry points, `keepLoaded`).
