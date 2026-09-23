import QtQuick
import Quickshell
import Quickshell.Io

// Async fd-based file/dir search. Paths come back line-by-line through a
// SplitParser; a fresh search cancels whatever is still running.
QtObject {
  id: root

  signal done()

  property var results: ([])
  property bool searching: false
  property string kind: "file" // "file" | "dir"

  // kind: "file" | "dir". Empty query -> recent, shallow files.
  function search(kind, query) {
    root.kind = kind
    root.canceled = false

    var target = kind === "dir" ? "d" : "f"
    var args = ["fd", "-t", target, "-H", "--max-results", "60"]
    args.push("-E", "node_modules", "-E", ".git", "-E", ".cache")
    var q = String(query || "").trim()
    if (q) {
      args.push(q)
    } else {
      args.push("--max-depth", "2", "--changed-within", "7d")
    }
    args.push(Quickshell.env("HOME"))

    proc.canceled = false
    proc.command = args
    root.results = []
    root.searching = true
    proc.running = true
  }

  function cancel() {
    proc.canceled = true
    if (proc.running) proc.signal(9)
    root.searching = false
  }

  Process {
    id: proc
    property bool canceled: false
    stdout: SplitParser {
      onRead: function(line) {
        if (proc.canceled) return
        var path = String(line).trim()
        if (path) root.results = root.results.concat([path])
      }
    }
    onExited: function(exitCode, exitStatus) {
      root.searching = false
      if (!proc.canceled) root.done()
    }
  }
}