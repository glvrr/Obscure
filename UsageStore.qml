import QtQuick
import Quickshell
import Quickshell.Io

// Most-recently-used app order for the "Most used first" setting.
//
// Deliberately tiny: an ordered array of desktop ids, newest first. No
// counters, no timestamps — "fresh" means "the last one you launched", full
// stop, and the whole file is small enough to hand-edit. It lives in the state
// dir next to history.json (~/.local/state/obscure/usage.json) so it survives
// shell restarts and stays out of the plugin checkout and obscure.json.
//
// Root is an invisible Item (not QtObject): Process must be a child of a type
// with a default `data` property.
Item {
  id: root

  visible: false

  // Newest first. `[]` until the file has been read.
  property var items: []
  // Hard cap. The oldest entries past it are dropped on the next write, so a
  // well-used machine cannot grow an unbounded list.
  property int limit: 100
  // Bound to the "Most used first" setting. Off = no recording and no
  // reordering (rankMap stays empty); the stored file is left exactly as it is,
  // so switching the toggle back on restores the previous order.
  property bool enabled: true
  property bool ready: false
  // Guards the one-time "file does not exist yet" seed.
  property bool seeded: false

  // appId -> 0-based recency rank, rebuilt from `items`. Spotlight's app sort
  // consults this map only; an id with no entry sorts AFTER every known one
  // (never rendered anyway: the entry must exist in the index to be a row).
  property var rankMap: ({})
  // Emitted whenever the order (or the enabled flag) changed, so the caller
  // can re-sort its app list and re-sync the row models.
  signal changed()

  readonly property string storePath: Quickshell.env("HOME") + "/.local/state/obscure/usage.json"

  // Single-quote a string for use inside sh -lc (the JSON holds double quotes,
  // but encode the whole path anyway).
  function q(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
  }

  // Read the stored list. Like HistoryStore this relies on the FileView's
  // BLOCKING construction read: it is already complete when a parent's
  // Component.onCompleted runs, and reload() is async on this host (it would
  // blank the view first), so text() is the only correct source.
  function load() {
    var raw = file.text()
    root.apply(raw)
    // First run: nothing has ever been written, and FileView warns on every
    // read of a missing path. Write an empty list once so later starts are
    // quiet. Only while the mechanism is on — at "off" the file is untouched.
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
      if (out.length >= root.limit) break
    }
    root.items = out
    root.rebuildRank()
    root.ready = true
  }

  function rebuildRank() {
    var m = {}
    if (root.enabled) {
      for (var i = 0; i < root.items.length; i++) m[root.items[i]] = i
    }
    root.rankMap = m
    root.changed()
  }

  // Record a launch: the app moves to the front of the list. A no-op while the
  // setting is off, so "off" genuinely stops tracking rather than just hiding
  // the effect, and a no-op when the app is already the freshest (no write).
  function touch(appId) {
    if (!root.enabled) return
    var id = String(appId || "").trim()
    if (id === "") return
    if (root.items.length > 0 && root.items[0] === id) return
    var out = [id]
    for (var i = 0; i < root.items.length && out.length < root.limit; i++) {
      if (root.items[i] === id) continue
      out.push(root.items[i])
    }
    root.items = out
    root.rebuildRank()
    root.save()
  }

  // Drop ids with no .desktop any more (uninstalled apps) and clamp to the cap.
  // Spotlight calls this once the app index is known, so the file never keeps
  // apps that can no longer appear. Invalid/empty input is ignored: an empty
  // index (not loaded yet) must NOT be read as "every app is gone".
  function prune(validIds) {
    if (!root.ready) return
    if (!validIds || validIds.length === 0) return
    var valid = {}
    for (var i = 0; i < validIds.length; i++) valid[String(validIds[i])] = true
    var out = []
    var dropped = 0
    for (var j = 0; j < root.items.length; j++) {
      if (valid[root.items[j]] && out.length < root.limit) out.push(root.items[j])
      else dropped++
    }
    if (dropped === 0 && out.length === root.items.length) return
    root.items = out
    root.rebuildRank()
    root.save()
  }

  function clear() {
    if (root.items.length === 0) return
    root.items = []
    root.rebuildRank()
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

  // Off/on flips the map: off clears it (so the app list falls back to the
  // alphabetical order without the caller touching anything), on rebuilds it
  // from the stored items.
  onEnabledChanged: root.rebuildRank()

  Timer {
    id: debounce
    interval: 200
    onTriggered: {
      var file = root.storePath
      // Same temp-file + rename dance as the other stores: a reader landing
      // between truncate and write would see an empty file.
      var tmp = file + ".tmp"
      writeProc.command = ["sh", "-lc",
        "mkdir -p " + root.q(file.replace(/\/[^/]*$/, ""))
        + " && printf '%s\\n' " + root.q(JSON.stringify(root.items))
        + " > " + root.q(tmp) + " && mv " + root.q(tmp) + " " + root.q(file)]
      writeProc.running = true
    }
  }

  // Read blocking, ONCE, at startup (same reasoning as HistoryStore): the
  // order has to be known before the first app sort. NO onFileChanged reload —
  // our own atomic save trips the watcher and reload() is async, so the handler
  // would re-read the pre-save text and clobber the touch that just happened.
  // Only we write this file, so the next shell start re-reads it.
  FileView {
    id: file
    path: root.storePath
    blockLoading: true
    watchChanges: false
    // A missing file is the normal first-run state (we seed it right after);
    // do not spam the journal with the expected "file does not exist".
    printErrors: false
  }

  Process {
    id: writeProc
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) console.warn("[obscure] usage save exited " + exitCode)
    }
  }

  Component.onCompleted: root.load()
}
