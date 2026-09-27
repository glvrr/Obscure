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
  // Guards the one-time "the file does not exist yet" seed below.
  property bool seeded: false

  readonly property string historyPath: Quickshell.env("HOME") + "/.local/state/obscure/history.json"
  readonly property bool enabled: root.limit > 0

  // Single-quote a string for use inside sh -lc (JSON holds double quotes, but
  // encode the whole path anyway).
  function q(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
  }

  // Read the stored list. Called once, from Component.onCompleted, and only we
  // ever write this file — so the job is done by the FileView's BLOCKING
  // construction read, which is already finished by the time a parent's
  // Component.onCompleted runs.
  //
  // DO NOT call file.reload() before reading text(). On this host reload() is
  // asynchronous and blanks the view first, so `reload(); text()` returns ""
  // (verified live: the file held 3 entries, the store came up empty), and the
  // "first run" seed below then overwrote a perfectly good file with []. The
  // list stayed empty for the whole session — a false "Empty list" hint, no
  // persistence, and every recorded query clobbering the stored entries.
  function load() {
    var raw = file.text()
    root.apply(raw)
    // Belt: the setting can say "off" while a list sits on disk (an older
    // version left one behind, or the limit was lowered while the shell was
    // down). On THIS host the panel's SettingsStore applies its config AFTER
    // we load (measured: the store logs after the history load), so `limit` is
    // still the default 10 here and the wipe actually arrives a moment later
    // through the limit binding -> onLimitChanged. Kept as the direct path in
    // case that order ever flips.
    if (!root.enabled && root.entries.length > 0) {
      root.entries = []
      root.save()
    }
    // First run: nothing has ever been written, and FileView warns on EVERY
    // read of a missing path (twice per load, on top of the load itself).
    // Write an empty list once so later shell starts are quiet. Only while the
    // mechanism is on — at limit 0 the stored list stays untouched.
    if (root.enabled && String(raw || "").trim() === "" && !root.seeded) {
      root.seeded = true
      root.save()
    }
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
  // 0 is not a pause, it is an off switch that ERASES: the user asked for the
  // stored history to go with it, so switching it back on starts empty.
  onLimitChanged: {
    if (!root.ready) return
    // Test `limit`, never `enabled`: this handler can run BEFORE the `enabled`
    // binding is re-evaluated, so the derived flag still reads "on" here.
    if (root.limit <= 0) {
      if (root.entries.length > 0) {
        root.entries = []
        root.save()
      }
      return
    }
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

  // Read blocking, ONCE, at startup: the list has to be known before the first
  // Down is pressed. Deliberately NO onFileChanged reload here — our own
  // atomic save trips the watcher, and FileView.reload() is async, so the
  // handler would read the PRE-save text and clobber the entry that was just
  // added (verified: "loaded n=3" right after adding a 4th). The file is only
  // written by us, so the next shell start re-reads it.
  FileView {
    id: file
    path: root.historyPath
    blockLoading: true
    watchChanges: false
  }

  Process {
    id: writeProc
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) console.warn("[obscure] history save exited " + exitCode)
    }
  }

  Component.onCompleted: root.load()
}
