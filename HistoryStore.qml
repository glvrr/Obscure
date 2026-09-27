import QtQuick
import Quickshell
import Quickshell.Io

// Resent queries ("history") for the spotlight. Deliberately NOT part of
// obscure.json: that file is polled by the bar widget and holds plain settings,
// while this is a growing list, so it lives on its own in the state dir
// (~/.local/state/obscure/history.json) and survives shell restarts.
//
// Only the plain query text is stored — flags are dropped on purpose (see
// Spotlight.addHistory) — newest first, no duplicates: re-submitting an entry
// moves it back to the top instead of growing a second copy.
// Root is an invisible Item (not QtObject): Process must be a child of a type
// with a default `data` property.
Item {
  id: root

  visible: false

  // Newest first. `[]` until the file has been read.
  property var entries: []
  // How many entries to keep. Bound to the "History" setting by the caller;
  // 0 switches the whole mechanism off (no dropdown, no recording) and leaves
  // the file on disk alone, so turning it back on restores the old list.
  property int limit: 10
  property bool ready: false

  readonly property string historyPath: Quickshell.env("HOME") + "/.local/state/obscure/history.json"
  readonly property bool enabled: root.limit > 0

  // Single-quote a string for use inside sh -lc (JSON holds double quotes, but
  // encode the whole path anyway).
  function q(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
  }

  function load() {
    file.reload()
    root.apply(file.text())
  }

  function apply(raw) {
    var arr = []
    try {
      var parsed = JSON.parse(String(raw || ""))
      if (Array.isArray(parsed)) arr = parsed
    } catch (e) {
      arr = []
    }
    var out = []
    var seen = {}
    for (var i = 0; i < arr.length; i++) {
      var t = String(arr[i] === null || arr[i] === undefined ? "" : arr[i]).trim()
      if (t === "" || seen[t]) continue
      seen[t] = true
      out.push(t)
      if (root.limit > 0 && out.length >= root.limit) break
    }
    root.entries = out
    root.ready = true
  }

  // Record a submitted query. Ignored while the mechanism is off, for blank
  // text, and for anything longer than a sane line (a pasted wall of text is
  // not a query worth resending).
  function add(text) {
    if (!root.enabled) return
    var t = String(text || "").trim()
    if (t === "" || t.length > 120) return
    var out = []
    out.push(t)
    for (var i = 0; i < root.entries.length; i++) {
      if (root.entries[i] === t) continue
      out.push(root.entries[i])
      if (out.length >= root.limit) break
    }
    root.entries = out
    root.save()
  }

  // Drop everything (not wired to any key yet — kept so a future "clear
  // history" action does not have to touch the file format).
  function clear() {
    if (root.entries.length === 0) return
    root.entries = []
    root.save()
  }

  function save() {
    if (!root.ready) return
    if (debounce.running) {
      debounce.restart()
    } else {
      debounce.start()
    }
  }

  // A limit lowered in the settings panel must bite at once, not after the
  // next restart; the trimmed list is written back so the file agrees.
  onLimitChanged: {
    if (!root.ready) return
    if (!root.enabled) return
    if (root.entries.length > root.limit) {
      root.entries = root.entries.slice(0, root.limit)
      root.save()
    }
  }

  Timer {
    id: debounce
    interval: 200
    onTriggered: {
      var file = root.historyPath
      // Same temp-file + rename dance as the settings store: a reader landing
      // between truncate and write would see an empty file and wipe the list.
      var tmp = file + ".tmp"
      writeProc.command = ["sh", "-lc",
        "mkdir -p " + root.q(file.replace(/\/[^/]*$/, ""))
        + " && printf '%s\\n' " + root.q(JSON.stringify(root.entries))
        + " > " + root.q(tmp) + " && mv " + root.q(tmp) + " " + root.q(file)]
      writeProc.running = true
    }
  }

  // Read blocking: the list is only consulted when Down is pressed, and the
  // first card paint must already know whether entries exist (otherwise the
  // header islands would pop out a frame late). Same FileView caveats as
  // SettingsStore: watchChanges never fires on this host, so load() reloads
  // explicitly.
  FileView {
    id: file
    path: root.historyPath
    blockLoading: true
    watchChanges: true
    onFileChanged: root.load()
  }

  Process {
    id: writeProc
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) console.warn("[obscure] history save exited " + exitCode)
    }
  }

  Component.onCompleted: root.load()
}
