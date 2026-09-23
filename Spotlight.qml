import QtQuick
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
//
// Interaction model (UI_SCHEME.md):
//  - activeTab is a mode: "" (auto), "apps", "files". By default no tab is
//    active; what you type decides the mode automatically (apps/files/Google).
//  - Auto mode renders the APPS icon grid; it becomes a live filter while
//    typing. Picking FILES switches to an fd-backed list.
//  - The header icons/tabs fade away as soon as the user types.
//  - Empty query: Left/Right arrows cycle the mode; typing: Up/Down navigate
//    the grid or list, Tab completes the inline autocomplete, Enter activates.
//  - Enter in auto mode launches the selected app; with no matches anywhere
//    (or flag -g) it falls back to a Google search.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property string query: ""
  property string activeTab: "" // "" (auto) | "apps" | "files"
  property bool opened: false
  property int selectedIndex: 0 // list rows (FILES / flags)
  property int gridIndex: 0     // APPS grid cell
  property bool _activating: false

  // ---- parsed query + mode resolution ----
  readonly property var parsed: Flags.parseQuery(root.query)
  readonly property string flag: root.parsed.flag
  readonly property string stripped: root.parsed.query
  readonly property string parsedMode: root.parsed.mode

  readonly property bool hasFlag: root.flag !== ""
  readonly property bool fileMode: root.activeTab === "files"

  // Header icon/tabs only stay while the query line is empty.
  readonly property bool showTabs: root.query === ""

  // Auto mode (and the APPS tab) render the icon grid; FILES renders a list.
  readonly property bool gridMode: !root.hasFlag && root.activeTab !== "files"

  // Which provider backs the visible list. A typed flag wins over the tab;
  // -f / -d both land in "files".
  readonly property string listMode: {
    if (root.hasFlag) {
      if (root.parsedMode === "files" || root.parsedMode === "dirs") return "files"
      return ""
    }
    return root.fileMode ? "files" : ""
  }

  readonly property string hintText: {
    if (root.gridMode) {
      if (root.stripped !== "" && root.gridItems.length === 0)
        return "No app matches \u2014 Enter to search Google"
      return ""
    }
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

  property var allApps: ([])                 // preloaded for the grid
  property var fileRows: ([])                // fd-backed list
  property string fileKind: "file"
  readonly property var fileList: root.listMode === "files" ? root.fileRows : ([])

  // ---- grid ----
  readonly property int gridCols: 6
  readonly property int maxGridRows: 3
  readonly property int gridCap: root.gridCols * root.maxGridRows

  readonly property var gridItems: root.gridItemsFor(root.stripped)

  function gridItemsFor(q) {
    if (!root.gridMode) return []
    if (!q) return root.allApps.slice(0, root.gridCap)
    var ql = String(q).toLowerCase().split(/\s+/).filter(function(w) { return w !== "" })
    var out = []
    for (var i = 0; i < root.allApps.length && out.length < root.gridCap; i++) {
      var a = root.allApps[i]
      var label = String(a.label).toLowerCase()
      var hit = true
      for (var w = 0; w < ql.length; w++) {
        if (label.indexOf(ql[w]) < 0) { hit = false; break }
      }
      if (hit) out.push(a)
    }
    return out
  }

  function ensureApps() {
    if (!root.appLibrary) return
    if (root.allApps.length > 0) return
    root.allApps = root.loadApps("", root.gridCap * 4)
    if (root.allApps.length === 0) appRetry.restart()
  }

  // ---- list rows ----
  readonly property var displayRows: root.fileList
  readonly property int rowsCount: root.displayRows.length

  // ---- autocomplete ----
  readonly property int safeGridIndex: root.gridItems.length === 0 ? 0 : Math.max(0, Math.min(root.gridIndex, root.gridItems.length - 1))
  readonly property int safeListIndex: root.rowsCount === 0 ? 0 : Math.max(0, Math.min(root.selectedIndex, root.rowsCount - 1))

  readonly property string suggestionText: {
    if (!root.stripped) return ""
    if (root.gridMode) {
      var a = root.gridItems[root.safeGridIndex]
      if (!a) return ""
      if (a.label.toLowerCase().indexOf(root.stripped.toLowerCase()) === 0) return a.label
      return ""
    }
    if (root.listMode === "files") {
      var f = root.fileRows[root.safeListIndex]
      if (!f) return ""
      if (f.path.toLowerCase().indexOf(root.stripped.toLowerCase()) === 0) return f.path
    }
    return ""
  }

  // ---- geometry / colors ----
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))
  readonly property color scrimColor: Color.menu.scrim
  readonly property color cardColor: Color.menu.background
  readonly property color fgColor: Color.menu.text
  readonly property color dimColor: Qt.darker(Color.menu.text, 1.45)
  readonly property color selColor: Color.menu.selectedText

  property int headerHeight: Math.max(Style.space(46), Style.spacing.controlHeight + Style.spacing.md * 2)
  property int rowHeight: Style.space(46)
  property int maxVisible: 10

  readonly property int cellHeight: Style.space(96)
  readonly property int gridHeight: root.gridItems.length === 0 ? 0 : Math.ceil(Math.min(root.gridItems.length, root.gridCap) / root.gridCols) * root.cellHeight

  readonly property int visibleRows: Math.min(Math.max(0, root.rowsCount), root.maxVisible)
  readonly property bool showHint: root.hintText !== ""
  readonly property int listHeight: root.visibleRows > 0 ? root.visibleRows * root.rowHeight : 0
  readonly property int contentHeight: {
    if (root.showHint) return Style.space(44)
    if (root.gridMode) return root.gridHeight
    return root.listHeight
  }

  // ---- host lifecycle ----
  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    root.query = String(payload.query || "")
    root.activeTab = payload.tab === "files" ? "files" : payload.tab === "apps" ? "apps" : ""
    root.selectedIndex = 0
    root.gridIndex = 0
    root.ensureApps()
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
    root.gridIndex = 0
  }

  function ping() { return "ok" }

  function refresh() {
    root.refreshResults()
    return "ok"
  }

  // ---- search ----
  function refreshResults() {
    root.selectedIndex = 0
    if (root.gridMode) root.ensureApps()
    if (root.hasFlag && (root.parsedMode === "files" || root.parsedMode === "dirs")) {
      root.gridIndex = 0
      searchTimer.restart()
    } else if (root.listMode === "files") {
      root.gridIndex = 0
      searchTimer.restart()
    } else {
      fileSearch.cancel()
      root.fileRows = []
      if (root.gridItems.length === 0) root.gridIndex = 0
    }
  }

  function loadApps(q, cap) {
    if (!root.appLibrary) return []
    var rows = root.appLibrary.sortedEntries(q)
    var out = []
    var max = cap || 60
    for (var i = 0; i < rows.length && out.length < max; i++) {
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

  function completeSuggestion() {
    if (root.suggestionText !== "") root.query = root.suggestionText
  }

  // ---- mode switching ----
  function cycleMode(dir) {
    var order = ["", "apps", "files"]
    var i = order.indexOf(root.activeTab)
    if (i < 0) i = 0
    root.activeTab = order[(i + dir + order.length) % order.length]
    queryField.forceActiveFocus()
  }

  function setTab(mode) {
    root.activeTab = mode
    queryField.forceActiveFocus()
  }

  // ---- activation ----
  // Enter routes automatically: apps/files open their selection, and any
  // mode with no matches (or flag -g) falls back to a Google search.
  function activate() {
    if (root._activating) return
    root._activating = true
    try {
      if (root.hasFlag) {
        root.runMode(root.parsedMode, root.stripped)
        return
      }
      if (!root.stripped) {
        if (root.listMode === "files" && root.rowsCount > 0) {
          root.runMode("files", "")
        } else {
          root.close()
        }
        return
      }
      if (root.gridMode) {
        var g = root.gridItems[root.safeGridIndex]
        if (g) {
          if (root.appLibrary) root.appLibrary.launch(g.appId, g.label)
          root.close()
        } else {
          root.runMode("web", root.stripped)
        }
        return
      }
      var mode = Search.decide(root.activeTab, 0, root.fileRows.length)
      root.runMode(mode, root.stripped)
    } finally {
      root._activating = false
    }
  }

  function runMode(mode, q) {
    switch (mode) {
    case "apps":
    case "files":
    case "dirs": {
      if (root.gridMode) {
        var g = root.gridItems[root.safeGridIndex]
        if (!g) return
        if (root.appLibrary) root.appLibrary.launch(g.appId, g.label)
        root.close()
        break
      }
      var f = root.fileRows[root.safeListIndex]
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

  onOpenedChanged: if (root.opened) root.refreshResults()
  onQueryChanged: if (root.opened) root.refreshResults()
  onActiveTabChanged: if (root.opened) root.refreshResults()
  onShellChanged: if (root.shell) Qt.callLater(root.ensureApps)
  Component.onCompleted: Qt.callLater(root.ensureApps)

  Timer {
    id: appRetry
    interval: 300
    onTriggered: {
      if (root.allApps.length > 0) { appRetry.stop(); return }
      root.ensureApps()
      if (root.allApps.length === 0) {
        appRetry.start()
      } else {
        appRetry.stop()
        if (root.gridMode) root.refreshResults()
      }
    }
  }

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
      height: root.headerHeight + (root.contentHeight > 0 ? root.contentHeight + Style.spacing.sm : 0) + Style.spacing.md * 2
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
          } else if (root.hasFlag) {
            if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
              var fdelta = event.key === Qt.Key_Down ? 1 : -1
              var fn = root.rowsCount
              if (fn > 0) {
                root.selectedIndex = (root.safeListIndex + fdelta + fn) % fn
                event.accepted = true
              }
            } else if (event.key === Qt.Key_Tab) {
              root.completeSuggestion()
              event.accepted = true
            }
          } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
            root.cycleMode(event.key === Qt.Key_Right ? 1 : -1)
            event.accepted = true
          } else if (root.gridMode) {
            if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
              var cols = root.gridCols
              var next = (event.key === Qt.Key_Down ? root.safeGridIndex + cols : root.safeGridIndex - cols)
              root.gridIndex = Math.max(0, Math.min(next, root.gridItems.length - 1))
              event.accepted = true
            } else if (event.key === Qt.Key_Tab) {
              root.completeSuggestion()
              event.accepted = true
            } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !queryField.activeFocus) {
              root.activate()
              event.accepted = true
            }
          } else {
            if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
              var delta = event.key === Qt.Key_Down ? 1 : -1
              var n = root.rowsCount
              if (n > 0) {
                root.selectedIndex = (root.safeListIndex + delta + n) % n
                event.accepted = true
              }
            } else if (event.key === Qt.Key_Tab) {
              root.completeSuggestion()
              event.accepted = true
            } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !queryField.activeFocus) {
              root.activate()
              event.accepted = true
            }
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

          // Icon + tabs collapse (with animation) once the user types.
          Item {
            id: tabCluster
            Layout.preferredWidth: root.showTabs ? tabClusterRow.width : 0
            Layout.preferredHeight: tabClusterRow.height
            Layout.alignment: Qt.AlignVCenter
            opacity: root.showTabs ? 1 : 0
            enabled: root.showTabs
            clip: true
            Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutQuad } }
            Behavior on Layout.preferredWidth { NumberAnimation { duration: 200; easing.type: Easing.OutQuad } }

            RowLayout {
              id: tabClusterRow
              spacing: Style.spacing.sm

              OmarchyIcon {
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.openOmarchy()
              }

              SpotlightTab {
                id: appsTab
                text: "APPS"
                icon: "\uf00a"
                active: !root.hasFlag && root.activeTab === "apps"
                onClicked: root.setTab("apps")
              }

              SpotlightTab {
                id: filesTab
                text: "FILES"
                icon: "\uf07b"
                active: !root.hasFlag && root.activeTab === "files"
                onClicked: root.setTab("files")
              }
            }
          }

          QueryBar {
            id: queryField
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            tabMode: root.activeTab
            text: root.query
            suggestion: root.suggestionText
            onTextChanged: root.query = queryField.text
            onActivate: root.activate()
            onTabComplete: root.completeSuggestion()
            onCycleMode: root.cycleMode(dir)
          }
        }

        // ---- content: app grid or result list ----
        Item {
          id: contentArea
          anchors.top: header.bottom
          anchors.topMargin: Style.spacing.sm
          anchors.left: parent.left
          anchors.right: parent.right
          height: root.contentHeight
          visible: root.contentHeight > 0

          Text {
            visible: root.showHint
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: Style.space(44)
            text: root.hintText
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.subtitle
            color: root.dimColor
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideMiddle
          }

          GridView {
            id: appGrid
            visible: root.gridMode && !root.showHint
            clip: true
            interactive: false
            width: parent.width
            height: root.gridHeight
            cellWidth: Math.floor(width / root.gridCols)
            cellHeight: root.cellHeight
            model: root.gridItems
            delegate: gridDelegate

            add: Transition {
              NumberAnimation { properties: "opacity,scale"; from: 0; to: 1; duration: 150; easing.type: Easing.OutQuad }
            }
            remove: Transition {
              NumberAnimation { property: "opacity"; to: 0; duration: 120 }
            }
            displaced: Transition {
              NumberAnimation { properties: "x,y"; duration: 160; easing.type: Easing.OutQuad }
            }
            populate: Transition {
              NumberAnimation { properties: "opacity,scale"; from: 0; to: 1; duration: 220; easing.type: Easing.OutQuad }
            }
          }

          Column {
            id: listColumn
            visible: !root.gridMode && !root.showHint
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: root.listHeight

            ListView {
              width: parent.width
              height: root.listHeight
              clip: true
              model: root.displayRows
              delegate: rowDelegate
            }
          }
        }
      }
    }
  }

  // ---- app grid cell ----
  Component {
    id: gridDelegate

    Item {
      id: gridCell
      readonly property bool isSelected: index === root.safeGridIndex

      width: appGrid.cellWidth
      height: appGrid.cellHeight

      Column {
        anchors.fill: parent
        anchors.margins: Style.space(6)
        spacing: Style.space(4)

        Item {
          width: parent.width
          height: Style.space(52)

          Rectangle {
            anchors.centerIn: parent
            width: Style.space(52)
            height: Style.space(52)
            radius: Math.max(2, (height - Style.space(4)) / 2)
            color: gridCell.isSelected ? Color.menu.selectedBackground : "transparent"
            Behavior on color { ColorAnimation { duration: 120 } }
          }

          Image {
            anchors.centerIn: parent
            width: Style.space(36)
            height: Style.space(36)
            source: model.iconUrl !== "" ? model.iconUrl : ""
            asynchronous: true
            sourceSize.width: width * Screen.devicePixelRatio
            sourceSize.height: height * Screen.devicePixelRatio
            fillMode: Image.PreserveAspectFit
          }
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          width: parent.width
          text: model.label
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: gridCell.isSelected ? root.selColor : root.fgColor
          elide: Text.ElideMiddle
          horizontalAlignment: Text.AlignHCenter
        }
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        onHoveredChanged: if (containsMouse) root.gridIndex = index
        onClicked: {
          root.gridIndex = index
          root.activate()
        }
      }
    }
  }

  // ---- result list row (files / flags) ----
  Component {
    id: rowDelegate

    Item {
      id: rowItem
      readonly property bool isSelected: index === root.safeListIndex
      readonly property bool isDir: model && model.kind === "dir"
      readonly property string iconGlyph: rowItem.isDir ? "\uf07b" : "\uf15b"

      height: root.rowHeight
      width: ListView.view.width

      Rectangle {
        anchors.fill: parent
        radius: Math.max(2, (height - Style.space(4)) / 2)
        color: rowItem.isSelected ? Color.menu.selectedBackground : "transparent"
        Behavior on color { ColorAnimation { duration: 120 } }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.rowPaddingX
        width: Style.space(24)
        text: rowItem.iconGlyph
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
        anchors.rightMargin: Style.spacing.rowPaddingX
        text: model && model.path ? model.path : ""
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        color: rowItem.isSelected ? root.selColor : root.fgColor
        elide: Text.ElideMiddle
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
}