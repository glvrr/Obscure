import QtQuick
import qs.Commons
import qs.Ui
import "Flags.js" as Flags

// The query line (TEXT_FIELD). Parses leading flags and re-exposes the
// result so Spotlight can route on it. Shows an inline autocomplete
// suggestion (the suffix after the caret) and completes it on Tab.
TextField {
  id: root

  property string tabMode: "apps"
  property string suggestion: ""
  property bool gridActive: false
  readonly property var parsed: Flags.parseQuery(root.text)
  readonly property string flag: root.parsed.flag
  readonly property string stripped: root.parsed.query
  readonly property string mode: root.parsed.mode

  signal activate()
  signal tabComplete()
  signal cycleMode(int dir)
  signal navigateGrid(int dir)

  placeholderText: root.placeholderFor()
  selectByMouse: true
  font.pixelSize: Style.font.subtitle
  onAccepted: root.activate()

  Keys.onPressed: function(event) {
    if (root.text === "" && (event.key === Qt.Key_Left || event.key === Qt.Key_Right)) {
      var dir = event.key === Qt.Key_Right ? 1 : -1
      if (root.gridActive) {
        root.navigateGrid(dir)
      } else {
        root.cycleMode(dir)
      }
      event.accepted = true
    } else if (event.key === Qt.Key_Tab && root.suggestion !== "" && root.suggestion !== root.text) {
      root.tabComplete()
      event.accepted = true
    }
  }

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
    if (root.tabMode === "files") return "Search files...  (-f file  -d dir  -g web  -p pinterest  -r run  -. hidden)"
    return "Search apps...  (-f file  -d dir  -g web  -p pinterest  -a apps  -o menu  -r run  -. hidden)"
  }

  // ---- inline autocomplete ----
  TextMetrics {
    id: tm
    font: root.font
    text: root.text
  }

  readonly property bool showSuggestion: {
    if (root.text === "" || root.suggestion === "") return false
    var t = root.text.toLowerCase()
    if (t === root.suggestion.toLowerCase()) return false
    return root.suggestion.toLowerCase().indexOf(t) === 0
  }
  readonly property string suggestionSuffix: {
    var t = root.text.toLowerCase()
    var s = root.suggestion.toLowerCase()
    if (s.indexOf(t) !== 0) return ""
    var start = s.indexOf(t) + t.length
    return root.suggestion.substring(start)
  }

  Text {
    visible: root.showSuggestion
    anchors.verticalCenter: parent.verticalCenter
    anchors.left: parent.left
    anchors.leftMargin: root.leftPadding + tm.width + Style.space(1)
    text: root.suggestionSuffix
    font: root.font
    color: Qt.darker(Color.menu.text, 1.4)
  }
}