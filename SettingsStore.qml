import QtQuick
import Quickshell
import Quickshell.Io

// Persistent settings for the Obscure launcher. Values live in
// ~/.config/omarchy/obscure.json (kept out of the plugin checkout and the
// package-owned shell.json). Read blocking at startup (FileView below), and
// re-read on demand through load(); each change calls save() which debounces
// a write through a short-lived Process.
// Root is an invisible Item (not QtObject): Process must be a child of a
// type with a default `data` property.
Item {
  id: root

  visible: false

  // Effective settings, loaded from disk (defaults until ready).
  property string defaultMode: "auto" // "auto" | "apps" | "files"
  property bool showHidden: false
  property bool showO: true
  property bool showApps: true
  property bool showFiles: true
  property bool animations: true
  // How the APPS screen renders its matches: "grid" (icon grid, the original)
  // or "list" (one row per app, the same list the search dropdown uses).
  property string appsView: "grid"
  // Show the launcher's magnifier button in the top bar. The bar host zeroes
  // a slot whose widget is invisible (ModuleSlot implicitWidth checks
  // activeItem.visible), so hiding the root leaves no gap behind.
  property bool showBarIcon: true
  // Ask to press Enter a second time before running a shell command (-r /
  // Ctrl+0); off = execute instantly. Default ON: silent shell execution is
  // otherwise one keystroke away from a search typo.
  property bool confirmRun: true
  // Where a -r / Ctrl+0 command runs: "silent" spawns bash in the background
  // (invisible), "external" runs it in the system terminal via `omarchy launch
  // terminal` — the same channel the -oc flag uses.
  property string runTarget: "silent"
  property string defaultFlags: ""
  // How many past queries the resend dropdown keeps (HistoryStore trims to
  // this). 0 = the whole resend mechanism is off.
  property int historyLimit: 10
  property bool ready: false

  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/obscure.json"

  // Single-quote a string for use inside sh -lc. JSON only ever contains
  // double quotes, but encode the whole path anyway.
  function q(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
  }

  // History is a count, but the file is hand-editable and the settings field
  // is free-form: anything that is not a sane integer becomes the default,
  // and 0 stays meaningful (mechanism off) instead of falling back.
  function clampHistory(v) {
    var n = parseInt(v, 10)
    if (isNaN(n)) return 10
    if (n < 0) return 0
    if (n > 200) return 200
    return n
  }

  // Re-read the file. file.reload() is what makes this work at runtime: on
  // this host FileView's watchChanges never fires (QFileSystemWatcher stays
  // quiet even when the file is rewritten), and text() hands back the
  // construction-time snapshot until something asks for a re-read. reload()
  // refreshes it asynchronously, so the fresh content shows up on the next
  // call — the bar widget polls once a second, which keeps that invisible.
  function load() {
    file.reload()
    root.apply(file.text())
  }

  function apply(raw) {
    var o = {}
    try { o = JSON.parse(String(raw || "")) } catch (e) { o = {} }
    var m = o.defaultMode
    root.defaultMode = (m === "apps" || m === "files" || m === "auto") ? m : "auto"
    root.showHidden = !!o.showHidden
    root.showO = o.showO === undefined ? true : !!o.showO
    root.showApps = o.showApps === undefined ? true : !!o.showApps
    root.showFiles = o.showFiles === undefined ? true : !!o.showFiles
    root.animations = o.animations === undefined ? true : !!o.animations
    root.appsView = o.appsView === "list" ? "list" : "grid"
    root.showBarIcon = o.showBarIcon === undefined ? true : !!o.showBarIcon
    root.confirmRun = o.confirmRun === undefined ? true : !!o.confirmRun
    root.runTarget = o.runTarget === "external" ? "external" : "silent"
    // Kept verbatim (no trim): "-g " with its trailing space must stay so the
    // chip is already active the moment the card reopens.
    root.defaultFlags = String(o.defaultFlags || "")
    root.historyLimit = root.clampHistory(o.historyLimit)
    root.ready = true
  }

  function save() {
    if (debounce.running) {
      debounce.restart()
    } else {
      debounce.start()
    }
  }

  Timer {
    id: debounce
    interval: 200
    onTriggered: {
      var o = {
        defaultMode: root.defaultMode,
        showHidden: root.showHidden,
        showO: root.showO,
        showApps: root.showApps,
        showFiles: root.showFiles,
        animations: root.animations,
        appsView: root.appsView,
        showBarIcon: root.showBarIcon,
        confirmRun: root.confirmRun,
        runTarget: root.runTarget,
        defaultFlags: root.defaultFlags,
        historyLimit: root.historyLimit
      }
      var file = root.configPath
      // Write to a sibling and rename: the bar polls this file every second,
      // and a reader that lands between truncate and write would otherwise see
      // an empty file and fall back to defaults (icon blinking back on).
      var tmp = file + ".tmp"
      writeProc.command = ["sh", "-lc",
        "mkdir -p " + root.q(file.replace(/\/[^/]*$/, ""))
        + " && printf '%s\\n' " + root.q(JSON.stringify(o))
        + " > " + root.q(tmp) + " && mv " + root.q(tmp) + " " + root.q(file)]
      writeProc.running = true
    }
  }

  // The config is a couple of hundred bytes, so it is read BLOCKING at
  // construction instead of through a `cat` process: the bar widget needs
  // showBarIcon on its very first frame (an async read would paint the icon
  // and then pull it a frame later), and the panel wants its settings before
  // the first open rather than one open late.
  //
  // NO onFileChanged here, on purpose. QFileSystemWatcher is unreliable in
  // BOTH directions on this host: it stays quiet for external writes, but it
  // DOES fire for our own save() — and reload() is async, so the handler read
  // the PRE-save text and re-applied it over the values just written (caught
  // live: Apply set History 0, the watcher re-read the old file and put the
  // in-memory limit back to 10, and the resend list was trimmed to nothing on
  // the way). Live updates come from whoever polls (the bar widget, once a
  // second) or from the next construction; the panel's own copy is only ever
  // written by Apply.
  FileView {
    id: file
    path: root.configPath
    blockLoading: true
    watchChanges: false
  }

  Process {
    id: writeProc
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) console.warn("[obscure] settings save exited " + exitCode)
    }
  }

  Component.onCompleted: root.load()
}