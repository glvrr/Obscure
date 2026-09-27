import QtQuick
import Quickshell
import Quickshell.Io

// Persistent settings for the Obscure launcher. Values live in
// ~/.config/omarchy/obscure.json (kept out of the plugin checkout and the
// package-owned shell.json). Read blocking at startup (FileView below); each
// change calls save() which debounces a write through a short-lived Process.
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
  property string defaultFlags: ""
  property bool ready: false

  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/obscure.json"

  // Single-quote a string for use inside sh -lc. JSON only ever contains
  // double quotes, but encode the whole path anyway.
  function q(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
  }

  function load() {
    var t = file.text()
    var hasReload = (typeof file.reload === "function")
    if (hasReload) { try { file.reload() } catch (e) { console.log("[obscure-probe] reload threw: " + e) } }
    var t2 = file.text()
    var m = /"showBarIcon":(\w+)/.exec(t2 || "")
    console.log("[obscure-probe] hasReload=" + hasReload + " sameText=" + (t === t2) + " len=" + (t2 ? t2.length : -1) + " fileSays=" + (m ? m[1] : "absent") + " propIs=" + root.showBarIcon)
    root.apply(t2)
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
    // Kept verbatim (no trim): "-g " with its trailing space must stay so the
    // chip is already active the moment the card reopens.
    root.defaultFlags = String(o.defaultFlags || "")
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
        defaultFlags: root.defaultFlags
      }
      var file = root.configPath
      writeProc.command = ["sh", "-lc",
        "mkdir -p " + root.q(file.replace(/\/[^/]*$/, ""))
        + " && printf '%s\\n' " + root.q(JSON.stringify(o))
        + " > " + root.q(file)]
      writeProc.running = true
    }
  }

  // The config is a couple of hundred bytes, so it is read BLOCKING at
  // construction instead of through a `cat` process: the bar widget needs
  // showBarIcon on its very first frame (an async read would paint the icon
  // and then pull it a frame later), and the panel wants its settings before
  // the first open rather than one open late. watchChanges keeps every live
  // instance in step with writes from anywhere — the panel's own save()
  // included, which is harmless: apply() is idempotent and never calls save().
  FileView {
    id: file
    path: root.configPath
    blockLoading: true
    watchChanges: true
    onFileChanged: { console.log("[obscure-probe] watcher fired"); root.load() }
  }

  Process {
    id: writeProc
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) console.warn("[obscure] settings save exited " + exitCode)
    }
  }

  Component.onCompleted: root.load()
}