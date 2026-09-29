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
  // mode -> placeholder text for every web mode, supplied by Spotlight's live
  // flag registry. Read first so an overridden or user-defined flag shows its
  // own name instead of the hardcoded switch below.
  property var customPlaceholder: ({})
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
  signal popRawToken()
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
    } else if (event.key === Qt.Key_Backspace && root.selectedText.length === 0 && root.cursorPosition === 0) {
      if (root.filterActive) {
        root.popFilter()
      } else if (root.leadingToken() !== "") {
        root.popRawToken()
      }
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

  // The leading edge "-token" chunk of the field text while it is still raw
  // (no chip filter). At caret position 0 Backspace removes it as a whole unit
  // so a mis-typed flag ("-ss", "-s") can't strand as uneditable text.
  function leadingToken() {
    var m = root.text.match(/^\s*-[a-z.]+(?:[ \t]+|$)/)
    return m ? m[0] : ""
  }

  function placeholderFor() {
    if (root.multiRequest) return "Multi-search..."
    if (root.rawMode !== "auto") {
      // Every web mode (built-in or config) lands here first; the switch below
      // keeps the non-web modes (run/opencode/menu/dirs/files/apps).
      var cp = root.customPlaceholder[root.rawMode]
      if (cp) return cp
      switch (root.rawMode) {
      case "run": return "Run a command..."
      case "opencode": return "Ask opencode..."
      case "menu": return "Search Omarchy menu..."
      case "dirs": return "Search directories..."
      case "files": return "Search files..."
      case "apps": return "Search apps..."
      }
    }
    // The flag list used to live here as a parenthetical; it was long enough
    // to push the line out of view, and it is documented in the help page
    // anyway. The "CTRL+H for help..." nudge is a separate right-aligned Text
    // in Spotlight.qml (queryHelpHint) — a single placeholder can only ever be
    // one left-aligned string.
    if (root.tabMode === "files") return "Search files..."
    return "Obscure..."
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