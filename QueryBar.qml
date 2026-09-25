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
  // Set by Spotlight from the full raw query: when a leading flag is
  // confirmed (followed by a space/text) the field edits only the part after
  // the chips, so parsing THIS field's text alone yields no flags.
  property bool filterActive: false
  property string rawMode: "auto"
  // True when the parent sees multiple dispatch-target flags; the placeholder
  // then advertises the combo instead of the first flag's label.
  property bool multiRequest: false
  readonly property var parsed: Flags.parseQuery(root.text)
  readonly property string flag: root.parsed.flag
  readonly property string stripped: root.parsed.query
  readonly property string mode: root.parsed.mode

  signal activate()
  signal tabComplete()
  signal cycleMode(int dir)
  signal navigateGrid(int dir)
  signal hotkey(string cmd)
  signal popFilter()
  signal escapeKey()

  // Default content origin (text/caret column) before chip offset kicks in.
  // Depends on the kit's private _borderSpec (Border.left); if the Ui kit ever
  // changes that accessor this one needs the same update.
  readonly property int defaultLeftPadding: Math.round(root.horizontalPadding + Border.left(root._borderSpec))

  placeholderText: root.placeholderFor()
  selectByMouse: true
  font.pixelSize: Style.font.heading
  onAccepted: root.activate()

  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Escape) {
      root.escapeKey()
      event.accepted = true
    } else if ((event.modifiers & Qt.ControlModifier) && Flags.ctrlCommand(event.key, true) !== "") {
      root.hotkey(Flags.ctrlCommand(event.key, true))
      event.accepted = true
    } else if (event.key === Qt.Key_Backspace && root.filterActive && root.cursorPosition === 0 && root.selectedText.length === 0) {
      root.popFilter()
      event.accepted = true
    } else if (root.text === "" && !root.filterActive && (event.key === Qt.Key_Left || event.key === Qt.Key_Right)) {
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
    if (root.multiRequest) return "Multi-search..."
    if (root.rawMode !== "auto") {
      switch (root.rawMode) {
      case "web": return "Search Google..."
      case "run": return "Run a command..."
      case "menu": return "Search Omarchy menu..."
      case "dirs": return "Search directories..."
      case "files": return "Search files..."
      case "apps": return "Search apps..."
      case "pinterest": return "Search Pinterest..."
      case "images": return "Google Images..."
      case "artstation": return "Search ArtStation..."
      case "sketchfab": return "Search Sketchfab..."
      case "youtube": return "Search YouTube..."
      case "ddg": return "Search DuckDuckGo..."
      }
    }
    if (root.tabMode === "files") return "Search files...  (-f file  -d dir  -g web  -p pinterest  -i images  -as artstation  -sf sketchfab  -y youtube  -ddg duckduckgo  -r run  -. hidden)"
    return "Search apps...  (-f file  -d dir  -g web  -p pinterest  -i images  -a apps  -o menu  -as artstation  -sf sketchfab  -y youtube  -ddg duckduckgo  -r run  -. hidden)"
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