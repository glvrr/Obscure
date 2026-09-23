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
//    active; the mode is detected automatically.
//  - Opening shows ONLY the query line (+ header icons). No slots, no grid.
//  - Typing in auto mode opens a unified dropdown: app matches on top, files
//    below. Enter launches the selected row, or falls back to Google.
//  - Clicking APPS (or -a) shows the icon grid; the query line keeps working
//    as the grid filter. Clicking FILES (or -f/-d) shows the fd-backed list.
//  - The header islands (O / APPS / FILES) collapse in width while typing or
//    under a flag, and the query line grows to the full card width in the
//    same animation, so the caret never shifts or overlaps.
//  - Left/Right on an empty query cycle the mode, Up/Down navigate the active
//    list/grid, Tab completes the inline autocomplete, Enter activates.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property string query: ""
  property string activeTab: "" // "" (auto) | "apps" | "files"
  property bool opened: false
  property int selectedIndex: 0 // list rows (FILES / flags / dropdown)
  property int gridIndex: 0     // APPS grid cell
  property bool _activating: false
  // Latch set the moment a launch/open is dispatched. The card starts closing
  // instantly and the list reflows beneath the cursor, so the releasing half
  // of a single physical click can land on a different row and activate it a
  // second time. Open() clears the latch for the next summon.
  property bool _opening: false
  // Two-level keyboard model for the app grid: with an empty query, landing on
  // the APPS tab only highlights the mode; Down enters the grid (first cell
  // selected) and Up on the first row returns to mode cycling. Left/Right move
  // cells only while engaged, otherwise they keep cycling APPS/FILES.
  property bool gridEngaged: false

  // ---- parsed query + mode resolution ----
  readonly property var parsed: Flags.parseQuery(root.query)
  readonly property string flag: root.parsed.flag
  readonly property string stripped: root.parsed.query
  readonly property string parsedMode: root.parsed.mode
  readonly property bool hidden: root.parsed.hidden

  readonly property bool hasFlag: root.flag !== ""

  // A flag wins over the tab; otherwise the tab decides.
  readonly property bool inApps: root.hasFlag
    ? root.parsedMode === "apps"
    : root.activeTab === "apps"
  readonly property bool inFiles: root.hasFlag
    ? (root.parsedMode === "files" || root.parsedMode === "dirs")
    : root.activeTab === "files"
  readonly property bool inAuto: !root.hasFlag && root.activeTab === ""

  // Typing without a flag in auto mode opens the unified dropdown.
  readonly property bool searchMode: root.inAuto && root.stripped !== ""

  // Header islands (O / APPS / FILES) collapse away while typing or while a
  // flag is active; the query line grows to the full card width in sync.
  readonly property bool showTabs: root.query === "" && !root.hasFlag

  readonly property string listMode: root.inFiles ? "files" : ""

  readonly property bool appsLoading: root.allApps.length === 0

  readonly property string hintText: {
    if (root.hasFlag) {
      if (root.parsedMode === "web") return "Search Google for \u201C" + root.stripped + "\u201D"
      if (root.parsedMode === "run") return "Run: " + root.stripped
      if (root.parsedMode === "menu") return "Open Omarchy menu and search"
      if (root.parsedMode === "apps" && root.stripped !== "" && root.gridItems.length === 0)
        return "No app matches \u2014 Enter to search Google"
      return ""
    }
    if (root.appsLoading) return ""
    if (root.inFiles) return ""
    if (root.searchMode && root.stripped !== "" && root.searchRows.length === 0)
      return "No matches \u2014 Enter to search Google"
    if (root.inApps && root.stripped !== "" && root.gridItems.length === 0)
      return "No app matches \u2014 Enter to search Google"
    return ""
  }

  // ---- data ----
  // Host facade for app entries. Some host builds never hand a scoped
  // appLibrary to third-party menu plugins (null here), so the plugin falls
  // back to the self-contained AppIndex (.desktop scanner) + IconResolver
  // (our own icon-theme index).
  readonly property var appLibrary: root.shell ? root.shell.appLibrary : null
  property bool appIndexReady: false

  function debugLog(msg) {
    if (Quickshell.env("OMARCHY_SPOTLIGHT_DEBUG") === "1") console.log("[spotlight] " + msg)
  }

  property var allApps: ([])                 // preloaded apps for grid/dropdown
  property var fileRows: ([])                // fd-backed file rows
  property string fileKind: "file"

  // ---- app matching ----
  // Opens files with their default handler; routes Terminal=true handlers
  // into the configured terminal (see open-file.sh).
  readonly property string openScript: String(Qt.resolvedUrl("open-file.sh")).replace(/^file:\/\//, "")

  readonly property int gridCols: 6
  readonly property int gridVisibleRows: 3

  readonly property var gridItems: root.appMatches(root.stripped, root.allApps.length)

  function appMatches(q, cap) {
    var limit = cap || root.allApps.length
    var ql = String(q || "").toLowerCase().split(/\s+/).filter(function(w) { return w !== "" })
    var out = []
    for (var i = 0; i < root.allApps.length && out.length < limit; i++) {
      var a = root.allApps[i]
      if (ql.length === 0) { out.push(a); continue }
      var label = String(a.label).toLowerCase()
      var hit = true
      for (var w = 0; w < ql.length; w++) {
        if (label.indexOf(ql[w]) < 0) { hit = false; break }
      }
      if (hit) out.push(a)
    }
    return out
  }

  function buildGridApps(list) {
    var out = []
    for (var i = 0; i < list.length; i++) {
      var it = list[i]
      var appId = String(it.appId || (it.entry && it.entry.id) || "")
      if (!appId) continue
      var label = String(it.label || (root.appLibrary && it.entry && root.appLibrary.entryName(it.entry)) || appId)
      var icon = String(it.icon || (it.entry && it.entry.icon) || "")
      out.push({
        kind: "app",
        appId: appId,
        label: label,
        subtext: "",
        iconUrl: it.iconUrl || iconResolver.resolve(icon)
      })
    }
    return out
  }

  function ensureApps() {
    root.debugLog("ensureApps shell=" + (root.shell !== null) + " appLibrary=" + (root.appLibrary !== null)
      + " allApps=" + root.allApps.length + " appIndexReady=" + root.appIndexReady + " busy=" + appIndex.busy)
    if (root.allApps.length > 0) return
    if (root.appLibrary) {
      root.appIndexReady = true
      try {
        root.allApps = root.buildGridApps(root.appLibrary.sortedEntries(""))
        root.sortApps()
        if (root.allApps.length > 0) return
      } catch (e) {
        appIndexReady = false
      }
    }
    if (!root.appIndexReady) {
      if (!appIndex.busy) appIndex.load()
      return
    }
    root.allApps = root.buildGridApps(appIndex.apps)
    root.sortApps()
    if (root.allApps.length === 0) appRetry.restart()
  }

  function sortApps() {
    root.allApps.sort(function(a, b) {
      return String(a.label).localeCompare(String(b.label))
    })
  }

  // ---- unified auto dropdown (apps + files) ----
  readonly property var appDropRows: root.appMatches(root.stripped, 6)
  readonly property var searchRows: {
    var rows = []
    var apps = root.appDropRows
    for (var i = 0; i < apps.length; i++) rows.push(apps[i])
    for (var j = 0; j < root.fileRows.length && rows.length < 12; j++) rows.push(root.fileRows[j])
    return rows
  }

  readonly property var displayRows: root.searchMode ? root.searchRows : (root.inFiles ? root.fileRows : ([]))
  readonly property int rowsCount: root.displayRows.length

  readonly property bool gridMode: root.inApps && !root.showHint

  // ---- autocomplete ----
  readonly property int safeGridIndex: root.gridItems.length === 0 ? 0 : Math.max(0, Math.min(root.gridIndex, root.gridItems.length - 1))
  readonly property int safeListIndex: root.rowsCount === 0 ? 0 : Math.max(0, Math.min(root.selectedIndex, root.rowsCount - 1))
  readonly property int gridCursor: root.gridEngaged ? root.safeGridIndex : -1

  readonly property string suggestionText: {
    if (!root.stripped) return ""
    if (root.gridMode) {
      var g = root.gridItems[root.safeGridIndex]
      if (g && g.label.toLowerCase().indexOf(root.stripped.toLowerCase()) === 0) return g.label
      return ""
    }
    var r = root.displayRows[root.safeListIndex]
    if (r) {
      if (r.kind === "app" && r.label.toLowerCase().indexOf(root.stripped.toLowerCase()) === 0) return r.label
      if (r.path && r.path.toLowerCase().indexOf(root.stripped.toLowerCase()) === 0) return r.path
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
  property int rowHeight: Style.space(50)
  property int maxVisible: 10

  readonly property int cellHeight: Style.space(110)
  readonly property int gridRowsVisible: root.gridItems.length === 0 ? 0 : Math.min(root.gridVisibleRows, Math.ceil(root.gridItems.length / root.gridCols))
  readonly property int gridHeight: root.gridRowsVisible === 0 ? 0 : root.gridRowsVisible * root.cellHeight

  readonly property int visibleRows: Math.min(Math.max(0, root.rowsCount), root.maxVisible)
  readonly property bool showHint: root.hintText !== ""
  readonly property int rowSpacing: Style.spacing.xs
  readonly property int listHeight: root.visibleRows > 0 ? root.visibleRows * root.rowHeight + (root.visibleRows - 1) * root.rowSpacing : 0
  readonly property int contentHeight: {
    // Auto mode with an empty query is just the line.
    if (!root.searchMode && !root.inApps && !root.inFiles) return 0
    if (root.showHint) return Style.space(44)
    if (root.gridMode) return root.gridHeight
    return root.listHeight
  }

  // ---- host lifecycle ----
  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    root._opening = false
    root.query = String(payload.query || "")
    root.activeTab = payload.tab === "files" ? "files" : payload.tab === "apps" ? "apps" : ""
    root.selectedIndex = 0
    root.gridIndex = 0
    root.disarmPointer()
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
    root.debugLog("refresh search=" + root.searchMode + " apps=" + root.inApps + " files=" + root.inFiles
      + " stripped=\"" + root.stripped + "\" allApps=" + root.allApps.length
      + " gridItems=" + root.gridItems.length + " rows=" + root.rowsCount + " fileRows=" + root.fileRows.length)
    root.gridEngaged = false
    root.selectedIndex = 0
    root.disarmPointer()
    root.syncViews()
    if (root.inApps || root.searchMode) root.ensureApps()
    if (root.searchMode || root.inFiles) {
      root.gridIndex = 0
      searchTimer.restart()
    } else {
      fileSearch.cancel()
      root.fileRows = []
      if (root.gridItems.length === 0) root.gridIndex = 0
    }
    root.syncViews()
  }

  // The views consume a real QML ListModel (roles), not a raw JS array:
  // on this host roles arrived as undefined through model.<key>, leaving
  // every delegate blank while the JS-side counts were healthy.
  function syncViews() {
    root.syncGrid()
    root.syncResults()
  }

  function syncGrid() {
    gridModel.clear()
    var items = root.gridItems
    for (var i = 0; i < items.length; i++) {
      var g = items[i]
      gridModel.append({
        kind: g.kind,
        label: g.label,
        subtext: g.subtext || "",
        iconUrl: g.iconUrl || ""
      })
    }
  }

  function syncResults() {
    resultsModel.clear()
    var rows = root.displayRows
    for (var i = 0; i < rows.length; i++) {
      var r = rows[i]
      resultsModel.append({
        kind: r.kind,
        label: r.label || "",
        path: r.path || "",
        iconUrl: r.iconUrl || ""
      })
    }
  }

  function runFileSearch() {
    root.fileKind = root.inFiles && root.parsedMode === "dirs" ? "dir" : "file"
    fileSearch.search(root.fileKind, root.stripped, root.hidden)
  }

  function completeSuggestion() {
    if (root.suggestionText !== "") root.query = root.suggestionText
  }

  function launchApp(g) {
    root.debugLog("launch " + g.appId)
    if (root.appLibrary) root.appLibrary.launch(g.appId, g.label)
    else appIndex.launch(g.appId)
  }

  // ---- mode switching ----
  function cycleMode(dir) {
    var order = ["", "apps", "files"]
    var i = order.indexOf(root.activeTab)
    if (i < 0) i = 0
    root.gridEngaged = false
    root.activeTab = order[(i + dir + order.length) % order.length]
    queryField.forceActiveFocus()
  }

  function setTab(mode) {
    root.gridEngaged = false
    root.activeTab = mode
    queryField.forceActiveFocus()
  }

  function toggleTab(mode) {
    root.gridEngaged = false
    root.activeTab = root.activeTab === mode ? "" : mode
    queryField.forceActiveFocus()
  }

  // ---- activation ----
  // Enter routes automatically: the selected app/file opens, and any mode
  // with no matches (or flag -g) falls back to a Google search.
  function activate() {
    if (root._opening) return
    if (root._activating) return
    root._activating = true
    try {
      if (root.hasFlag) {
        root.runMode(root.parsedMode, root.stripped)
        return
      }
      if (!root.stripped) {
        if (root.inFiles && root.rowsCount > 0) {
          root.runMode("files", "")
          return
        }
        // The grid launches only once it has been entered (Down or a click);
        // an Enter with the query line still on the mode level just closes.
        if (root.inApps && root.gridEngaged) {
          var g0 = root.gridItems[root.safeGridIndex]
          if (g0) {
            root._opening = true
            root.launchApp(g0)
            root.close()
            return
          }
        }
        root.close()
        return
      }
      if (root.inApps) {
        var g = root.gridItems[root.safeGridIndex]
        if (g) {
          root._opening = true
          root.launchApp(g)
          root.close()
        } else {
          root.runMode("web", root.stripped)
        }
        return
      }
      var r = root.displayRows[root.safeListIndex]
      if (r) {
        root._opening = true
        if (r.kind === "app") {
          root.launchApp(r)
        } else {
          Quickshell.execDetached([root.openScript, r.path])
        }
        root.close()
      } else {
        root.runMode("web", root.stripped)
      }
    } finally {
      root._activating = false
    }
  }

  function runMode(mode, q) {
    switch (mode) {
    case "apps": {
      var g = root.gridItems[root.safeGridIndex]
      if (!g) return
      root._opening = true
      root.launchApp(g)
      root.close()
      break
    }
    case "files":
    case "dirs": {
      var f = root.fileRows[root.safeListIndex]
      if (!f) return
      root._opening = true
      Quickshell.execDetached([root.openScript, f.path])
      root.close()
      break
    }
    case "web": {
      if (!q) return
      root._opening = true
      Quickshell.execDetached(["omarchy", "launch", "browser", Search.googleUrl(q)])
      root.close()
      break
    }
    case "run": {
      if (!q) return
      root._opening = true
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
  Component.onCompleted: {
    Qt.callLater(root.ensureApps)
    Qt.callLater(iconResolver.start)
    iconResolver.indexed.connect(root.rebuildIcons)
  }

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
        if (root.opened) root.refreshResults()
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
      root.debugLog("fileSearch done rows=" + fileSearch.results.length + " kind=" + root.fileKind)
      var rows = []
      var paths = fileSearch.results
      var isDir = root.fileKind === "dir"
      for (var i = 0; i < paths.length; i++) {
        rows.push({ kind: isDir ? "dir" : "file", path: paths[i] })
      }
      root.fileRows = rows
      root.selectedIndex = 0
      root.syncResults()
    }
  }

  // Self-contained desktop-entry index, used when the host leaves the
  // appLibrary facade null (third-party menu plugins).
  AppIndex {
    id: appIndex
    onLoaded: {
      root.debugLog("appIndex loaded apps=" + appIndex.apps.length)
      root.appIndexReady = true
      root.ensureApps()
      if (root.allApps.length === 0) return
      appRetry.stop()
      if (root.opened) root.refreshResults()
    }
  }

  // Self-contained icon-theme index (app grid + dropdown icons). The index
  // may finish after the app list is built, so rebuild entries once it's ready
  // to attach real themed icon paths.
  IconResolver {
    id: iconResolver
  }

  function rebuildIcons() {
    if (!iconResolver.ready) return
    if (!root.appIndexReady) return
    if (root.allApps.length === 0) { root.ensureApps(); return }
    root.allApps = root.buildGridApps(appIndex.apps)
    root.debugLog("iconResolver rebuilt allApps=" + root.allApps.length)
    if (root.opened) root.refreshResults()
  }

  // ---- window ----
  ListModel { id: gridModel }
  ListModel { id: resultsModel }

  // Filters synthetic hover churn: when the query refreshes and rows reflow
  // beneath a stationary pointer, each relocated delegate spuriously fires
  // hover. Selection follows the cursor only after real pointer travel, and
  // keyboard/query actions disarm the gate so a resting mouse can't hijack it.
  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  function disarmPointer() { pointerGate.reset() }

  function selectFromRow(item, index, mouse) {
    if (pointerGate.moved(item, mouse)) root.selectedIndex = index
  }

  function selectGridFromPointer(item, index, mouse) {
    if (pointerGate.moved(item, mouse)) {
      root.gridEngaged = true
      root.gridIndex = index
    }
  }

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
      // No enclosing outline: every control (O / APPS / FILES / query line)
      // carries its own border, so the panel reads as separate outlined
      // islands on the plain surface, not one bordered window.
      borderSpec: Border.none()

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
            if (root.inApps) {
              root.gridKeys(event)
            } else {
              root.listKeys(event)
            }
            event.accepted = true
          } else if (root.searchMode || root.inFiles) {
            root.listKeys(event)
            event.accepted = true
          } else if (root.inApps) {
            root.gridKeys(event)
            event.accepted = true
          } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
            root.cycleMode(event.key === Qt.Key_Right ? 1 : -1)
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
          spacing: Style.spacing.lg

          // Header islands. Each icon is its own capsule; typing or a flag
          // collapses the whole cluster in width while the query line takes
          // the freed space in the same animation (no overlap, text stays
          // pinned to the left edge).
          Item {
            id: tabCluster
            Layout.preferredWidth: root.showTabs ? tabClusterRow.width : 0
            Layout.preferredHeight: tabClusterRow.height
            Layout.alignment: Qt.AlignVCenter
            clip: true
            opacity: root.showTabs ? 1 : 0
            enabled: root.showTabs
            Behavior on Layout.preferredWidth { NumberAnimation { duration: 180; easing.type: Easing.InOutQuad } }
            Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutQuad } }

            RowLayout {
              id: tabClusterRow
              spacing: Style.spacing.lg

              OmarchyIcon {
                Layout.alignment: Qt.AlignVCenter
                onClicked: root.openOmarchy()
              }

              SpotlightTab {
                id: appsTab
                text: "APPS"
                icon: "\uf00a"
                active: !root.hasFlag && root.activeTab === "apps"
                onClicked: root.toggleTab("apps")
              }

              SpotlightTab {
                id: filesTab
                text: "FILES"
                icon: "\uf07b"
                active: !root.hasFlag && root.activeTab === "files"
                onClicked: root.toggleTab("files")
              }
            }
          }

          QueryBar {
            id: queryField
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            tabMode: root.activeTab
            gridActive: root.gridMode && root.gridEngaged
            text: root.query
            suggestion: root.suggestionText
            onTextChanged: root.query = queryField.text
            onActivate: root.activate()
            onTabComplete: root.completeSuggestion()
            onCycleMode: root.cycleMode(dir)
            onNavigateGrid: root.gridStep(dir)
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
            interactive: true
            boundsBehavior: Flickable.StopAtBounds
            width: parent.width
            height: root.gridHeight
            cellWidth: Math.floor(width / root.gridCols)
            cellHeight: root.cellHeight
            model: gridModel
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
              spacing: root.rowSpacing
              model: resultsModel
              delegate: rowDelegate
            }
          }
        }
      }
    }
  }

  function gridKeys(event) {
    root.disarmPointer()
    if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
      var cols = root.gridCols
      if (event.key === Qt.Key_Down) {
        if (!root.gridEngaged) {
          // First Down leaves the mode level and selects the first cell.
          root.gridEngaged = true
          root.gridIndex = 0
          appGrid.positionViewAtIndex(0, GridView.Contain)
          return
        }
        var next = root.safeGridIndex + cols
        root.gridIndex = Math.max(0, Math.min(next, root.gridItems.length - 1))
        appGrid.positionViewAtIndex(root.gridIndex, GridView.Contain)
      } else {
        if (!root.gridEngaged) return
        if (root.safeGridIndex < cols) {
          // Up on the first row returns to the mode level.
          root.gridEngaged = false
          root.gridIndex = 0
          return
        }
        root.gridIndex = Math.max(0, root.safeGridIndex - cols)
        appGrid.positionViewAtIndex(root.gridIndex, GridView.Contain)
      }
    } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
      root.gridStep(event.key === Qt.Key_Right ? 1 : -1)
    } else if (event.key === Qt.Key_Tab) {
      root.completeSuggestion()
    } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !queryField.activeFocus) {
      root.activate()
    }
  }

  function gridStep(dir) {
    root.disarmPointer()
    if (!root.gridEngaged) return
    if (root.gridItems.length === 0) return
    var next = root.safeGridIndex + dir
    if (next === root.gridIndex) return
    root.gridIndex = Math.max(0, Math.min(next, root.gridItems.length - 1))
    appGrid.positionViewAtIndex(root.gridIndex, GridView.Contain)
  }

  function listKeys(event) {
    root.disarmPointer()
    if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
      var n = root.rowsCount
      if (n > 0) root.selectedIndex = (root.safeListIndex + (event.key === Qt.Key_Down ? 1 : -1) + n) % n
    } else if (event.key === Qt.Key_Tab) {
      root.completeSuggestion()
    } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !queryField.activeFocus) {
      root.activate()
    }
  }

  // ---- app grid cell ----
  Component {
    id: gridDelegate

    Item {
      id: gridCell
      required property int index
      required property string kind
      required property string label
      required property string iconUrl
      property bool isSelected: index === root.gridCursor

      width: appGrid.cellWidth
      height: appGrid.cellHeight

      Column {
        anchors.fill: parent
        anchors.margins: Style.space(6)
        spacing: Style.space(4)

        Item {
          width: parent.width
          height: Style.space(64)

          Rectangle {
            anchors.centerIn: parent
            width: Style.space(64)
            height: Style.space(64)
            radius: Math.max(2, Style.cornerRadius)
            color: gridCell.isSelected ? Color.menu.selectedBackground : "transparent"
            Behavior on color { ColorAnimation { duration: 120 } }
          }

          Image {
            anchors.centerIn: parent
            width: Style.space(40)
            height: Style.space(40)
            source: gridCell.iconUrl
            asynchronous: true
            sourceSize.width: width * Screen.devicePixelRatio
            sourceSize.height: height * Screen.devicePixelRatio
            fillMode: Image.PreserveAspectFit
          }
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          width: parent.width
          text: gridCell.label
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          color: gridCell.isSelected ? root.selColor : root.fgColor
          elide: Text.ElideMiddle
          horizontalAlignment: Text.AlignHCenter
        }
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        onPositionChanged: function(mouse) { root.selectGridFromPointer(gridCell, index, mouse) }
        onClicked: {
          root.gridEngaged = true
          root.gridIndex = index
          root.activate()
        }
      }
    }
  }

  // ---- result row (apps in dropdown, files, flags) ----
  Component {
    id: rowDelegate

    Item {
      id: rowItem
      required property int index
      required property string kind
      required property string label
      required property string path
      required property string iconUrl
      property bool isSelected: index === root.safeListIndex
      property bool isApp: rowItem.kind === "app"
      property bool isDir: rowItem.kind === "dir"
      property string iconGlyph: rowItem.isDir ? "\uf07b" : "\uf15b"

      height: root.rowHeight
      width: ListView.view.width

      Rectangle {
        anchors.fill: parent
        radius: Math.max(2, Style.cornerRadius)
        color: rowItem.isSelected ? Color.menu.selectedBackground : "transparent"
        Behavior on color { ColorAnimation { duration: 120 } }
      }

      // App rows show the themed icon; files show a glyph.
      Image {
        visible: rowItem.isApp
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.rowPaddingX
        width: Style.space(36)
        height: Style.space(36)
        source: rowItem.isApp ? rowItem.iconUrl : ""
        asynchronous: true
        sourceSize.width: width * Screen.devicePixelRatio
        sourceSize.height: height * Screen.devicePixelRatio
        fillMode: Image.PreserveAspectFit
      }

      Text {
        visible: !rowItem.isApp
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        anchors.leftMargin: Style.spacing.rowPaddingX
        width: Style.space(36)
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
        anchors.leftMargin: Style.spacing.rowPaddingX + Style.space(36) + Style.spacing.labelGap
        anchors.right: parent.right
        anchors.rightMargin: Style.spacing.rowPaddingX
        text: rowItem.isApp ? rowItem.label : rowItem.path
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.weight: Font.Medium
        color: rowItem.isSelected ? root.selColor : root.fgColor
        elide: Text.ElideMiddle
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        onPositionChanged: function(mouse) { root.selectFromRow(rowItem, index, mouse) }
        onClicked: {
          root.selectedIndex = index
          root.activate()
        }
      }
    }
  }
}