import QtQuick
import Quickshell
import Quickshell.Io

// Persistent settings for the Obscure launcher. Values live in
// ~/.config/omarchy/obscure.json (kept out of the plugin checkout and the
// package-owned shell.json). Loaded once at startup; each change calls save()
// which debounces a write through a short-lived Process.
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
  property bool ready: false

  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/obscure.json"
  property string _buf: ""

  // Single-quote a string for use inside sh -lc. JSON only ever contains
  // double quotes, but encode the whole path anyway.
  function q(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
  }

  function load() {
    proc.command = ["sh", "-lc", "cat " + root.q(root.configPath) + " 2>/dev/null || true"]
    proc.running = true
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
        showFiles: root.showFiles
      }
      var file = root.configPath
      writeProc.command = ["sh", "-lc",
        "mkdir -p " + root.q(file.replace(/\/[^/]*$/, ""))
        + " && printf '%s\\n' " + root.q(JSON.stringify(o))
        + " > " + root.q(file)]
      writeProc.running = true
    }
  }

  Process {
    id: proc
    stdout: SplitParser {
      onRead: function(line) {
        root._buf += String(line) + "\n"
      }
    }
    onExited: function(exitCode, exitStatus) {
      root.apply(root._buf)
      root._buf = ""
    }
  }

  Process {
    id: writeProc
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) console.warn("[obscure] settings save exited " + exitCode)
    }
  }

  Component.onCompleted: {
    console.log("[obscure] settings store booted")
    Qt.callLater(root.load)
  }
}