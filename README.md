# Obscure

A spotlight-style launcher for [Omarchy](https://omarchy.app) — a single
floating card over your desktop that searches apps, files and the web as you
type. Quickshell/QML plugin, no background service, no telemetry.

```
  ┌──────────────────────────────────────────────┐
  │ [O] [APPS] [FILES]  │  ⌨  type to search…    │
  │                     │  [google] cats         │
  │                     │  · Search Google       │
  └──────────────────────────────────────────────┘
```

## Screenshots

|  |  |
|---|---|
| <a href="https://raw.githubusercontent.com/glvrr/obcr_media/main/Screenshots/obsc_scrn-1.png"><img src="https://raw.githubusercontent.com/glvrr/obcr_media/main/Screenshots/obsc_scrn-1.png" width="480" alt="Obscure"></a> | <a href="https://raw.githubusercontent.com/glvrr/obcr_media/main/Screenshots/obsc_scrn-2.png"><img src="https://raw.githubusercontent.com/glvrr/obcr_media/main/Screenshots/obsc_scrn-2.png" width="480" alt="Obscure"></a> |
| <a href="https://raw.githubusercontent.com/glvrr/obcr_media/main/Screenshots/obsc_scrn-3.png"><img src="https://raw.githubusercontent.com/glvrr/obcr_media/main/Screenshots/obsc_scrn-3.png" width="480" alt="Obscure"></a> | <a href="https://raw.githubusercontent.com/glvrr/obcr_media/main/Screenshots/obsc_scrn-4.png"><img src="https://raw.githubusercontent.com/glvrr/obcr_media/main/Screenshots/obsc_scrn-4.png" width="480" alt="Obscure"></a> |
| <a href="https://raw.githubusercontent.com/glvrr/obcr_media/main/Screenshots/obsc_scrn-5.png"><img src="https://raw.githubusercontent.com/glvrr/obcr_media/main/Screenshots/obsc_scrn-5.png" width="480" alt="Obscure"></a> | <a href="https://raw.githubusercontent.com/glvrr/obcr_media/main/Screenshots/obsc_scrn-6.png"><img src="https://raw.githubusercontent.com/glvrr/obcr_media/main/Screenshots/obsc_scrn-6.png" width="480" alt="Obscure"></a> |

Images live in [glvrr/obcr_media](https://github.com/glvrr/obcr_media), so they
stay out of this repository (and out of every `git clone`).

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
validates the manifest and rescans the shell; the bar section comes from the
manifest (`barWidget.defaultSection: left`). For a scripted install (no
prompts, non-interactive shells):

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
omarchy-shell shell summon glvr.ninja.obscure '{}'                    # default flags prefill
omarchy-shell shell summon glvr.ninja.obscure '{"tab":"apps"}'        # straight to the app grid
omarchy-shell shell summon glvr.ninja.obscure '{"flag":"-a"}'        # app search, [apps] chip
omarchy-shell shell summon glvr.ninja.obscure '{"flag":"-g -p","query":"cats"}'
```

No Hyprland binding ships with the plugin. To get one, put any of the `summon`
lines above into your own config — `{}` for a plain open, `{"tab":…}` for a
screen, `{"flag":…}` for anything else:

```ini
bind = $mod, SPACE, exec, omarchy-shell shell summon glvr.ninja.obscure '{}'
bind = $mod, A,     exec, omarchy-shell shell summon glvr.ninja.obscure '{"flag":"-a"}'
bind = $mod, F,     exec, omarchy-shell shell summon glvr.ninja.obscure '{"flag":"-f"}'
bind = $mod, G,     exec, omarchy-shell shell summon glvr.ninja.obscure '{"flag":"-g"}'
```

## Update / remove

```sh
omarchy plugin update glvr.ninja.obscure   # fetch, show the diff, fast-forward
omarchy plugin update                      # every git-managed plugin
omarchy plugin remove glvr.ninja.obscure
```

`remove` deletes only the plugin checkout, so your settings survive a
reinstall. The data lives outside the checkout and is never touched:

```sh
~/.config/omarchy/obscure.json          # settings
~/.config/omarchy/obscure.flags.json    # custom web flags (see below)
~/.local/state/obscure/history.json     # resend-query history
```

Delete those three by hand if you want a clean slate.

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
| `-oc` | ask opencode in a terminal |
| `-g` | Google |
| `-p` | Pinterest |
| `-i` | Google Images |
| `-y` | YouTube |
| `-git`, `-ddg` | starter web flags (the file is created with these on first run, see below) |
| `-gpt`, `-as`, `-sf`, `-da`, … | your own web flags (add them to `obscure.flags.json`) |
| `-.` | show hidden files |

> The web flags are **configurable**: `-git` and `-ddg` are written to
> `~/.config/omarchy/obscure.flags.json` on the first run, and any web flag
> (built-ins included) can be rebound or renamed there — even `-g` to a
> different engine. See [Custom search flags](#custom-search-flags).

> Multiple request flags stack: `-g -p cats` opens Google **and** Pinterest from
> one query. View flags (`-a`, `-f`, `-d`) don't stack — the first one wins as
> the display mode. `-oc` never stacks (single mode by design); `-r` can join a
> request batch (`-g -r cats` runs the command and opens Google).

- **Chips** — confirmed flags render as pills inside the query line
  (`[google] cats`). Backspace at position 0 pops them one at a time; the field
  only ever edits the text after the chips. Unknown heads (`-ss`) never chip —
> they stay visible, editable text, and Backspace at the start removes one such
  raw token in a single press.
- **Keyboard first** — arrows switch mode, grid navigation, hotkeys, settings
  and help. Mouse optional.
- **Summonable into any mode** — a binding or script can open the card on a
  screen (`{"tab":"apps"}`) or with a flag already in the line
  (`{"flag":"-g"}`): web search, run, hidden files, multi-search, all reachable
  without touching the keyboard layout. See
  [Open modes](#open-modes-summon-payload).
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
- Run `-r` in — where a shell command runs: **Silent** (bash in the background,
  the default) or **External terminal** (the command runs in your system
  terminal via `omarchy launch terminal`, same channel as `-oc`; an interactive
  shell is left behind after the command so the window survives and you can
  inspect output — close it with `exit`/`Ctrl+D` when done). Silent mode still
  reports back in the status line: the card stays open while the command runs
  ("Running…"), then flashes **Done!** (accent) and closes itself, or shows
  **Error: \<output tail\>** (urgent) and stays open until you press `Esc` so
  the message can be read.
- Shell command warning — on by default: running a command via `-r` / `Ctrl+0`
  needs a second Enter (a flash in the hint line asks to confirm); off runs it
  instantly. Applies in both run modes.
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
- Config file — a labelled settings row (same chrome as the toggles around it):
  **Edit config** opens `~/.config/omarchy/obscure.flags.json` in the configured
  editor (creating it when it does not exist yet), **Reload flags** re-reads it
  live (no shell restart), so a hand-edited web flag appears in
  chips/placeholders instantly. Reload reports back in the status line:
  **Reloaded: Valid.** (accent) when every entry parsed, or
  **Reloaded: Invalid (\<labels\>)** (urgent) naming the entries that were
  skipped (bad token/label/URL, malformed JSON, or a reserved-mode hijack). On
  the keyboard the row is one target:
  `Left`/`Right` switch Edit ↔ Reload, `Enter` fires the lit one.

Persisted to `~/.config/omarchy/obscure.json` (the web-flag definitions live in
`~/.config/omarchy/obscure.flags.json`, the resend list in
`~/.local/state/obscure/history.json`).

## Custom search flags

The browser-dispatch flags (`-g`, `-p`, `-i`, `-y` built-ins plus anything the
file defines) come from a live registry: the built-in defaults merged with
`~/.config/omarchy/obscure.flags.json`, the file winning per token. The four
built-ins work out of the box, and on the **first run** the file is created for
you with a small starter set (`-git` GitHub and `-ddg` DuckDuckGo). An existing
file is never rewritten — not even an empty one — so the seed can only ever
happen once, on a machine that has no file at all.

Edit it in the settings panel: **Edit config** opens the path, **Reload flags**
picks the change up without a restart. Anything you like goes in there:

```json
{
  "flags": [
    { "token": "gpt", "label": "ChatGPT", "url": "https://chatgpt.com/?q={q}",
      "placeholder": "Ask ChatGPT...", "hint": "Ask ChatGPT: {q}", "detail": "Ask ChatGPT in the browser" },
    { "token": "ec", "label": "Ecosia", "url": "https://www.ecosia.org/search?q={q}" }
  ]
}
```

- `token` — 1..4 lowercase letters. Rebinding a built-in web flag keeps its
  mode but overrides its URL **and** label (a `-g` chip shows the new engine's
  name). A brand-new token is its own mode (`-ec cats` → Ecosia).
- `url` — `http(s)://` template; the `{q}` hole is the encoded query. Entries
  without a URL or a `{q}` hole are skipped.
- `label` — required; shown on the chip, placeholder and hints.
- `placeholder` / `hint` / `detail` — optional; defaults derive from `label`
  (literally `Search <label>...` and `Search <label> for "…"` texts, and a
  `<label> search` help entry).
- Built-in non-web flags (`-r -o -a -f -d -oc -.-`) are **reserved** and can't
  be overridden; an entry that would hijack a built-in mode is ignored. Invalid
  entries are skipped one at a time, so a typo never blanks the whole file.
- Removing a flag's entry removes the flag: its head returns to raw text, the
  chip stops appearing, and a stale default-flags prefill containing it is
  cleaned up on open.

Opened/edited from the settings panel (**Edit config**), reloaded in place with
**Reload flags** (also applied automatically on every shell start).

## Open modes (summon payload)

`open()` accepts a JSON payload, so you can summon the card straight into a
mode — like the system's `SUPER ALT+SPACE` → `omarchy-menu toggle apps`:

| Key | Value | Effect |
|-----|-------|--------|
| `tab` | `"apps"`, `"files"`, `"auto"` | which screen to open |
| `flag` | `"-a"`, `"-g -p"`, `"-."`, … | flags prefilled into the line; the mode follows from them |
| `query` | `"report"` | text after the flags |
| `settings` | `true` | open the settings view instead |

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
# hidden files, the same trick as typing "-."
omarchy-shell shell summon glvr.ninja.obscure '{"flag":"-."}'
```

A non-empty `flag` replaces the *Default search flags* setting for that open,
just like an explicit `tab` does. Given together, the flag wins the screen (the
flag's parsed mode is what the card shows); a non-string `flag` is ignored.

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
| `FlagsConfig.qml` | user web-flag registry (`~/.config/omarchy/obscure.flags.json`) |
| `SegmentedToggle.qml` | settings form-row control (Apps view, mode, run target) |
| `Search.js` | auto-mode routing + `{q}` URL templating for registry flags |
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
