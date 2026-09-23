import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Self-contained icon-theme resolver. On this host a one-off
// Quickshell.iconPath() call does not resolve app icons, so we index the
// installed icon themes once (fd over the theme dirs) and map a lowercased
// basename to a real file. The engine lookup stays as a final resort.
// Source of truth for every Image.source in the plugin.
// Root is an invisible Item (not QtObject): Process/SplitParser need a
// default `data` property.
Item {
  id: root

  visible: false

  property var index: ({})
  property bool ready: false
  signal indexed()

  readonly property string generic: "application-x-executable"

  function start() {
    if (proc.running || root.ready) return
    proc.command = ["bash", "-c",
      "dirs=\"$HOME/.icons $HOME/.local/share/icons /usr/share/icons\";\n" +
      "for d in $dirs; do [ -d \"$d\" ] || continue; find \"$d\" -type f \\( -iname '*.png' -o -iname '*.svg' -o -iname '*.xpm' \\) 2>/dev/null; done"]
    proc.running = true
  }

  // Returns a file:// URL suitable for Image.source, never empty when the
  // generic icon is present in the themes we indexed.
  function resolve(iconName) {
    var value = String(iconName || "")
    if (value.length === 0) return root._fileFor(root.generic)
    if (value.indexOf("file://") === 0) return value
    if (value.charAt(0) === "/") return "file://" + value
    var found = root._fileFor(value)
    if (found) return found
    var generic = root._fileFor(root.generic)
    if (generic) return generic
    // Final resort: the engine's own themed lookup.
    var themed = Quickshell.iconPath(value, true)
    if (themed.length > 0) return themed
    var fb = Quickshell.iconPath(root.generic, true)
    if (fb.length > 0) return fb
    return ""
  }

  function _fileFor(name) {
    var key = String(name).toLowerCase()
    var found = root.index[key]
    if (found) return "file://" + found
    return ""
  }

  Process {
    id: proc
    stdout: SplitParser {
      onRead: function(line) {
        var path = String(line).trim()
        if (!path) return
        var slash = path.lastIndexOf("/")
        var base = slash >= 0 ? path.substring(slash + 1) : path
        var dot = base.lastIndexOf(".")
        if (dot > 0) base = base.substring(0, dot)
        var key = base.toLowerCase()
        if (key.length === 0) return
        if (!(key in root.index)) root.index[key] = path
      }
    }
    onExited: function(exitCode, exitStatus) {
      root.ready = true
      root.index[root.generic] = root.index[root.generic] || ""
      if (Quickshell.env("OMARCHY_SPOTLIGHT_DEBUG") === "1") {
        var count = 0
        for (var k in root.index) count++
        console.log("[spotlight] iconResolver ready index=" + count)
      }
      root.indexed()
    }
  }
}