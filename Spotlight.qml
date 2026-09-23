import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Flags.js" as Flags
import "Search.js" as Search

// Spotlight root. Host contract for a `menu` plugin: injected properties
// omarchyPath / shell / manifest plus open(payloadJson) / close() / ping().
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property string query: ""
  property string tabMode: "apps" // "apps" | "files"
  property bool opened: false
  property int selectedIndex: 0

  // ---- parsed query + mode resolution ----
  readonly property var parsed: Flags.parseQuery(root.query)
  readonly property string flag: root.parsed.flag
  readonly property string stripped: root.parsed.query
  readonly property string parsedMode: root.parsed.mode

  readonly property bool hasFlag: root.flag !== ""

  // Which provider backs the visible list. A typed flag wins over the tab;
  // -f / -d both land in "files".
  readonly property string listMode: {
    if (root.hasFlag) {
      if (root.parsedMode === "files" || root.parsedMode === "dirs") return "files"
      return ""
    }
    return root.tabMode
  }

  readonly property string hintText: {
    if (!root.hasFlag) return ""
    switch (root.parsedMode) {
    case "web": return "Search Google for \u201C" + root.stripped + "\u201D"
    case "run": return "Run: " + root.stripped
    case "menu": return "Open Omarchy menu and search"
    }
    return ""
  }

  // ---- data ----
  readonly property var appLibrary: root.shell ? root.shell.appLibrary : null

  property var appRows: ([])
  property var fileRows: ([])
  property string fileKind: "file"

  readonly property var displayRows: root.listMode === "apps" ? root.appRows : root.listMode === "files" ? root.fileRows : ([])
  readonly property int rowsCount: root.displayRows.length

  // ---- geometry / colors ----
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
  readonly property color scrimColor: Color.menu.scrim
  readonly property color cardColor: Color.menu.background
  readonly property color fgColor: Color.menu.text
  readonly property color dimColor: Qt.darker(Color.menu.text, 1.45)

  property int headerHeight: Math.max(Style.space(46), Style.spacing.controlHeight + Style.spacing.md * 2)
  property int rowHeight: Style.space(46)
  property int maxVisible: 10

  readonly property int visibleRows: Math.min(Math.max(0, root.rowsCount), root.maxVisible)
  readonly property bool showHint: root.hintText !== ""
  readonly property int listHeight: root.showHint ? Style.space(44) : root.visibleRows > 0 ? root.visibleRows * root.rowHeight : 0

  // ---- host lifecycle ----
  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    root.query = String(payload.query || "")
    root.tabMode = payload.tab === "files" ? "files" : "apps"
    root.selectedIndex = 0
    root.opened = true
    root.refreshResults()
    Qt.callLater(function() {
      queryField.forceActiveFocus()
      queryField.selectAll()
    })
  }

  function close() {
    fileSearch.cancel()
    root.opened = false
    root.selectedIndex = 0
  }

  function ping() { return "ok" }

  function refresh() {
    root.refreshResults()
    return "ok"
  }

  // ---- search ----
  function refreshResults() {
    root.selectedIndex = 0
    if (root.listMode === "apps") {
      fileSearch.cancel()
      root.appRows = root.loadApps(root.stripped)
    } else if (root.listMode === "files") {
      searchTimer.restart()
    }
  }

  function loadApps(q) {
    if (!root.appLibrary) return []
    var rows = root.appLibrary.sortedEntries(q)
    var out = []
    for (var i = 0; i < rows.length && out.length < 60; i++) {
      var entry = rows[i].entry
      var appId = String(entry && entry.id || "")
      if (!appId) continue
      var icon = String(entry.icon || "")
      out.push({
        kind: "app",
        appId: appId,
        label: root.appLibrary.entryName(entry),
        subtext: root.appLibrary.entrySubtext(entry),
        iconUrl: icon ? root.appLibrary.iconSource(icon) : ""
      })
    }
    return out
  }

  function runFileSearch() {
    root.fileKind = root.parsedMode === "dirs" ? "dir" : "file"
    fileSearch.search(root.fileKind, root.stripped)
  }

  // ---- activation ----
  function activate() {
    if (root.hasFlag) {
      root.runMode(root.parsedMode, root.stripped)
      return
    }
    if (!root.stripped) {
      root.close()
      return
    }
    var mode = Search.decide(root.tabMode, root.appRows.length, root.fileRows.length)
    root.runMode(mode, root.stripped)
  }

  function runMode(mode, q) {
    switch (mode) {
    case "apps": {
      var a = root.appRows[root.selectedIndex]
      if (!a) return
      if (root.appLibrary) root.appLibrary.launch(a.appId, a.label)
      root.close()
      break
    }
    case "files":
    case "dirs": {
      var f = root.fileRows[root.selectedIndex]
      if (!f) return
      Quickshell.execDetached(["xdg-open", f.path])
      root.close()
      break
    }
    case "web": {
      if (!q) return
      Quickshell.execDetached(["omarchy", "launch", "browser", Search.googleUrl(q)])
      root.close()
      break
    }
    case "run": {
      if (!q) return
      Quickshell.execDetached(["bash", "-lc", q])
      root.close()
      break
    }
    case "menu": {
      Quickshell.execDetached(["omarchy-shell", "shell", "toggle", "omarchy.menu", JSON.stringify({ menu: "root" })])
      root.close()
      break
    }
    }
  }

  function openOmarchy() {
    fileSearch.cancel()
    Quickshell.execDetached(["omarchy-shell", "shell", "toggle", "omarchy.menu", JSON.stringify({ menu: "root" })])
    root.close()
  }

  function setTab(mode) {
    root.tabMode = mode
    queryField.forceActiveFocus()
  }

  onOpenedChanged: if (root.opened) root.refreshResults()
  onQueryChanged: if (root.opened) root.refreshResults()
  onTabModeChanged: if (root.opened) root.refreshResults()

  Timer {
    id: searchTimer
    interval: 90
    repeat: false
    onTriggered: root.runFileSearch()
  }

  FileSearch {
    id: fileSearch
    onDone: {
      var rows = []
      var paths = fileSearch.results
      var isDir = root.fileKind === "dir"
      for (var i = 0; i < paths.length; i++) {
        rows.push({ kind: isDir ? "dir" : "file", path: paths[i] })
      }
      root.fileRows = rows
      root.selectedIndex = 0
    }
  }

  // ---- window ----
  PanelWindow {
    id: window
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "qs-spotlight"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrimColor
    }

    // Clicking the scrim dismisses the spotlight.
    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: Math.min(Style.space(620), window.width - Style.gapsOut * 2)
      height: root.headerHeight + (root.listHeight > 0 ? root.listHeight + Style.spacing.sm : 0) + Style.spacing.md * 2
      radius: Style.cornerRadius
      anchors.horizontalCenter: parent.horizontalCenter
      y: Math.max(Style.gapsOut, Math.round((window.height - card.height) / 2))
      color: root.cardColor
      borderSpec: root.borderSpec

      // Clicking empty card space returns focus to the query line.
      MouseArea {
        anchors.fill: parent
        onClicked: queryField.forceActiveFocus()
      }

      Item {
        id: keyCatcher
        anchors.fill: parent
        anchors.margins: Style.spacing.md

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.close()
            event.accepted = true
          } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
            var delta = event.key === Qt.Key_Down ? 1 : -1
            var n = root.rowsCount
            if (n > 0) {
              root.selectedIndex = (root.selectedIndex + delta + n) % n
              event.accepted = true
            }
          } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !queryField.activeFocus) {
            root.activate()
            event.accepted = true
          }
        }

        // ---- header: icon + tabs + query line ----
        RowLayout {
          id: header
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: root.headerHeight - Style.space(8)
          spacing: Style.spacing.sm

          OmarchyIcon {
            Layout.alignment: Qt.AlignVCenter
            onClicked: root.openOmarchy()
          }

          SpotlightTab {
            Layout.alignment: Qt.AlignVCenter
            text: "APPS"
            active: !root.hasFlag && root.tabMode === "apps"
            onClicked: root.setTab("apps")
          }

          SpotlightTab {
            Layout.alignment: Qt.AlignVCenter
            text: "FILES"
            active: !root.hasFlag && root.tabMode === "files"
            onClicked: root.setTab("files")
          }

          QueryBar {
            id: queryField
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            tabMode: root.tabMode
            text: root.query
            onTextChanged: root.query = queryField.text
            onActivate: root.activate()
          }
        }

        // ---- results list ----
        Column {
          id: listColumn
          anchors.top: header.bottom
          anchors.topMargin: Style.spacing.sm
          anchors.left: parent.left
          anchors.right: parent.right
          height: root.listHeight
          visible: height > 0

          Text {
            visible: root.showHint
            width: parent.width
            height: Style.space(44)
            text: root.hintText
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.subtitle
            color: root.dimColor
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideMiddle
          }

          ListView {
            visible: !root.showHint
            width: parent.width
            height: root.listHeight
            clip: true
            model: root.displayRows
            delegate: rowComponent
          }
        }
      }
    }
  }

  Component {
    id: rowComponent

    Item {
      id: rowItem
      readonly property bool isSelected: index === root.selectedIndex
      readonly property bool isApp: model && model.kind === "app"
      readonly property bool isDir: model && model.kind === "dir"
      readonly property string iconGlyph: rowItem.isDir ? "\uf07b" : "\uf15b"

      height: root.rowHeight
      width: ListView.view.width

      Rectangle {
        anchors.fill: parent
        radius: Math.max(2, (height - Style.space(4)) / 2)
        color: rowItem.isSelected ? Color.menu.selectedBackground : "transparent"
      }

      Image {
        visible: rowItem.isApp && model.iconUrl !== ""
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.rowPaddingX
        width: Style.space(24)
        height: Style.space(24)
        source: model.iconUrl
        asynchronous: true
        sourceSize.width: width * Screen.devicePixelRatio
        sourceSize.height: height * Screen.devicePixelRatio
      }

      Text {
        visible: !(rowItem.isApp && model.iconUrl !== "")
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.rowPaddingX
        width: Style.space(24)
        text: rowItem.isApp ? "\uf013" : rowItem.iconGlyph
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.iconLarge
        color: rowItem.isSelected ? root.selColor : root.fgColor
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }

      Text {
        id: titleText
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.leftMargin: Style.space(24) + Style.spacing.rowPaddingX * 2
        anchors.right: parent.right
        anchors.rightMargin: (rowItem.isApp && model.subtext !== "") ? Math.round(parent.width * 0.35) : Style.spacing.rowPaddingX
        text: rowItem.isApp ? model.label : model.path
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        color: rowItem.isSelected ? root.selColor : root.fgColor
        elide: Text.ElideMiddle
      }

      Text {
        visible: rowItem.isApp && model.subtext !== ""
        anchors.verticalCenter: parent.verticalCenter
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.rowPaddingX
        text: model.subtext
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        color: rowItem.isSelected ? Color.menu.selectedText : root.dimColor
        elide: Text.ElideLeft
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        onHoveredChanged: if (containsMouse) root.selectedIndex = index
        onClicked: {
          root.selectedIndex = index
          root.activate()
        }
      }
    }
  }

  readonly property color selColor: Color.menu.selectedText
}