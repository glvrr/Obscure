# Obscure

A spotlight-style launcher for [Omarchy](https://omarchy.app) — a single
floating card over your desktop that searches apps, files and the web as you
type. Quickshell/QML plugin, no background service, no telemetry.

```
  ┌──────────────────────────────────────────────┐
  │ [O] [APPS] [FILES]  │  ⌨  type to search…    │
  │                      │ [google] cats         │
  │                      │  · Search Google       │
  └──────────────────────────────────────────────┘
```

## Requirements

- Omarchy with the Quickshell-based `omarchy-shell` (the plugin system;
  `omarchy plugin list` must exist).
- `fd` — powers file and directory search.
- Everything else (`uwsm-app`, `omarchy launch`, `bash`) ships with Omarchy.

## Install

```sh
omarchy plugin add https://github.com/glvrr/Obscure --enable
```

The installer clones into `~/.config/omarchy/plugins/glvr.ninja.obscure`,
validates the manifest, rescans the shell and — because this plugin is both a
`menu` and a `bar-widget` — asks which bar section the magnifier icon should go
into. For a scripted install (no prompts, non-interactive shells):

```sh
omarchy plugin add https://github.com/glvrr/Obscure --enable --yes
```

If the bar icon does **not** show up after installing, the plugin ended up in
`plugins[]` instead of the bar layout. Move it explicitly:

```sh
omarchy plugin disable glvr.ninja.obscure
omarchy bar put glvr.ninja.obscure --section left --index <n>
```

## Open it

- **Click** the magnifier icon in the bar.
- **Right-click** it for settings.
- Or summon it from anywhere, with or without a keybinding:

```sh
omarchy-shell shell summon glvr.ninja.obscure '{}'            # default flags prefill
omarchy-shell shell summon glvr.ninja.obscure '{"tab":"apps"}' # straight to the app grid
```

No Hyprland binding ships with the plugin. To get one, put any of the `summon`
lines above into your own config:

```ini
bind = $mod, SPACE, exec, omarchy-shell shell summon glvr.ninja.obscure '{}'
```

## Update / remove

```sh
omarchy plugin update glvr.ninja.obscure   # fetch, show the diff, fast-forward
omarchy plugin update                      # every git-managed plugin
omarchy plugin remove glvr.ninja.obscure
```

## Features

- **One card, zero latency** — the card opens as a floating layer over
  everything; start typing and the islands make room.
- **App grid** — self-indexing launcher over the XDG `.desktop` files, with
  inline filter and keyboard navigation (no trusted shell API required). Grid or
  one-row-per-app list view.
- **File & directory search** — instant `fd`-backed results, dotfile-aware
  (`-.`).
- **Query history** — `Down` on an empty line resends a past query, flags
  included. Stored in `~/.local/state/obscure/history.json`; the size is a
  setting, and `0` switches the mechanism off *and erases* the list.
- **Smart query line** — the mode is detected automatically, or pick it with a
  flag:

| Flag | Action |
|------|--------|
| `-f` | file search |
| `-d` | directory search |
| `-a` | app search |
| `-o` | Omarchy menu |
| `-r` | run shell command |
| `-g` | Google |
| `-p` | Pinterest |
| `-i` | Google Images |
| `-as` | ArtStation |
| `-sf` | Sketchfab |
| `-y` | YouTube |
| `-ddg` | DuckDuckGo |
| `-da` | DeviantArt |
| `-.` | show hidden files |

> Multiple request flags stack: `-g -p cats` opens Google **and** Pinterest from
> one query. View flags (`-a`, `-f`, `-d`) don't stack — the first one wins as
> the display mode.

- **Chips** — confirmed flags render as pills inside the query line
  (`[google] cats`). Backspace at position 0 pops them one at a time; the field
  only ever edits the text after the chips. Unknown heads (`-ss`) never chip —
> they stay visible, editable text, and Backspace at the start removes one such
  raw token in a single press.
- **Keyboard first** — arrows switch mode, grid navigation, hotkeys, settings
  and help. Mouse optional.
- **Local** — nothing leaves the machine except the search URL you explicitly
  launch, which opens in your browser via `omarchy launch browser`.

## Hotkeys (while the card is focused)

| Hotkey | Action |
|--------|--------|
| `Ctrl+1` | Omarchy menu |
| `Ctrl+2` | Apps search |
| `Ctrl+3` | File search |
| `Ctrl+4` | Google |
| `Ctrl+5` | Pinterest |
| `Ctrl+6` | Google Images |
| `Ctrl+0` | Run command |
| `Ctrl+F` / `Ctrl+D` | Files / directories |
| `Ctrl+G` | Google |
| `Ctrl+P` / `Ctrl+I` | Pinterest / Images |
| `Ctrl+O` / `Ctrl+R` | Omarchy menu / run |
| `Ctrl+K` | Settings |
| `Ctrl+H` | Help |
| `Ctrl+S` | Save the current query flags (or none) as the default prefill |

## Settings

Open with `Ctrl+K` inside the card, or **right-click** the bar icon.

- Toggle the `O` / `APPS` / `FILES` islands individually (the query line can't
  be turned off).
- Default search mode (Auto / Apps / Files).
- Apps view (Grid / List) — the `APPS` screen shows either the icon grid or one
  row per app (same rows and keys as the auto dropdown: `Down` selects, `Enter`
  launches, the wheel scrolls).
- Show hidden by default (equivalent to typing `-.` each time).
- Animations — master toggle: smooth panel resize and content transitions; off
  makes everything instant.
- Shell command warning — on by default: running a command via `-r` / `Ctrl+0`
  needs a second Enter (a flash in the hint line asks to confirm); off runs it
  instantly.
- Bar icon — off hides the magnifier button in the top bar; the bar slot
  collapses without leaving a gap and all hotkeys keep working (use
  `omarchy bar put glvr.ninja.obscure …` if you ever remove the widget itself).
- Query history — how many past queries `Down` can resend (default 10, `0`
  switches the mechanism off **and erases the stored list**, so switching it
  back on starts empty). `Down` on an empty line opens the list under the field,
  `Up`/`Down` walk it, `Enter` **inserts** the picked query (flags/prefill stay)
  and typing or `Esc` closes it. An empty list still opens and says so
  (`Empty list — nothing to resend yet`). Not on the APPS/FILES screens, where
  `Down` still walks the rows. Only the plain text is stored (flags are dropped,
  `-r` commands never), duplicates move to the top. The list lives in
  `~/.local/state/obscure/history.json` and survives restarts.
- Default search flags — text prefilled into the query line on every open; they
  behave exactly like typed flags, backspace-poppable included.

Persisted to `~/.config/omarchy/obscure.json` (the resend list is separate:
`~/.local/state/obscure/history.json`).

## Open modes (summon payload)

`open()` accepts a JSON payload, so you can summon the card straight into a
mode — like the system's `SUPER ALT+SPACE` → `omarchy-menu toggle apps`:

```sh
# plain open with the default flags prefill (default behavior)
omarchy-shell shell summon glvr.ninja.obscure '{}'
# app grid, no default-flags prefill (an explicit route always wins)
omarchy-shell shell summon glvr.ninja.obscure '{"tab":"apps"}'
# file list filtered by a query
omarchy-shell shell summon glvr.ninja.obscure '{"tab":"files","query":"report"}'
# bare line mode
omarchy-shell shell summon glvr.ninja.obscure '{"tab":"auto"}'
# settings view (bar-icon right-click / Ctrl+K)
omarchy-shell shell summon glvr.ninja.obscure '{"settings":true}'
```

`tab` covers the three screens. For everything a tab cannot express — a web
search, a run, hidden files, a multi search — use `flag`, which prefills the
query line exactly as if you had typed it (the flag shows up as a chip and the
mode follows from it):

```sh
# the apps screen with a visible [apps] chip
omarchy-shell shell summon glvr.ninja.obscure '{"flag":"-a"}'
# a file search already carrying the query
omarchy-shell shell summon glvr.ninja.obscure '{"flag":"-f","query":"report"}'
# two request flags at once: nothing dispatches until you press Enter
omarchy-shell shell summon glvr.ninja.obscure '{"flag":"-g -p","query":"cats"}'
# the apps grid pre-filtered, Enter launches the highlighted one
omarchy-shell shell summon glvr.ninja.obscure '{"flag":"-a","query":"firefox"}'
```

A non-empty `flag` replaces the *Default search flags* setting for that open,
just like an explicit `tab` does.

## Under the hood

| File | Role |
|------|------|
| `Spotlight.qml` | the card — menu entry point |
| `SpotlightBar.qml` | magnifier icon — bar-widget entry point |
| `QueryBar.qml` | query line, chips, caret handling |
| `Flags.js` | flag parsing / ranking, chip semantics |
| `AppIndex.qml` | self-indexed `.desktop` launcher (XDG dirs) |
| `IconResolver.qml` | icon theme index for the grid |
| `FileSearch.qml` | `fd`-backed file / directory search |
| `HistoryStore.qml` | query history (`~/.local/state/obscure/history.json`) |
| `SettingsStore.qml` | settings (`~/.config/omarchy/obscure.json`) |
| `open-file.sh` | opener used for file results |

The plugin hot-reloads on save; a full shell restart guarantees a clean reload:

```sh
omarchy plugin validate ~/.config/omarchy/plugins/glvr.ninja.obscure
omarchy restart shell
```

> Plugins run as unsandboxed code inside the long-lived `omarchy-shell`
> process. Read the code before you enable it.

## License

[MIT](LICENSE) — copy it, fork it, ship it; keep the copyright line.
