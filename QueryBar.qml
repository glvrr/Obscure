import QtQuick
import qs.Commons
import qs.Ui
import "Flags.js" as Flags

// The query line (TEXT_FIELD). Parses leading flags and re-exposes the
// result so Spotlight can route on it.
TextField {
  id: root

  property string tabMode: "apps"
  readonly property var parsed: Flags.parseQuery(root.text)
  readonly property string flag: root.parsed.flag
  readonly property string stripped: root.parsed.query
  readonly property string mode: root.parsed.mode

  signal activate()

  placeholderText: root.placeholderFor()
  selectByMouse: true
  onAccepted: root.activate()

  function placeholderFor() {
    if (root.flag) {
      switch (root.mode) {
      case "web": return "Search Google..."
      case "run": return "Run a command..."
      case "menu": return "Search Omarchy menu..."
      case "dirs": return "Search directories..."
      case "files": return "Search files..."
      case "apps": return "Search apps..."
      }
    }
    if (root.tabMode === "files") return "Search files...  (-f file  -d dir  -g web  -r run)"
    return "Search apps...  (-f file  -d dir  -g web  -a apps  -o menu  -r run)"
  }
}