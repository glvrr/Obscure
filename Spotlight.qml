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
  // Header focus position when the query line is idle: "" (auto) | "apps" |
  // "files" | "omarchy". Arrows cycle through it; on "omarchy" the O island
  // highlights and Enter opens the stock omarchy menu.
  property string headerPos: ""
  // Settings view: opened via CTRL+K or a right-click on the bar icon
  // (payload {"settings":true}). The content area then shows the settings
  // panel. Edits are staged in the settingsDraft group below: nothing touches
  // the store until Apply commits them, Close discards them.
  property bool settingsOpen: false
  // ---- settings draft (staged until Apply) ----
  property bool draftShowO: true
  property bool draftShowApps: true
  property bool draftShowFiles: true
  property string draftDefaultMode: "auto"
  property bool draftShowHidden: false
  property string draftDefaultFlags: ""
  // Keyboard cursor over the settings controls (see settingsKeys).
  property int settingsIndex: 0

  // ---- parsed query + mode resolution ----
  readonly property var parsed: Flags.parseQuery(root.query)
  readonly property string flag: root.parsed.flag
  readonly property string stripped: root.parsed.query
  readonly property string parsedMode: root.parsed.mode
  readonly property bool hidden: root.parsed.hidden || store.showHidden

  readonly property bool hasFlag: root.flag !== ""

  // Confirmed leading flags (followed by a space/text) render as chips in
  // front of the query; the field then edits only the part after them.
  readonly property bool filterActive: Flags.swallowed(root.query, root.parsed)
  readonly property var chips: Flags.chipLabels(root.query, root.parsed)
  // The part the field should show: the query after the flags prefix, kept RAW
  // (trailing spaces included). Using the trimmed `stripped` here would make
  // the echo sync strip a just-typed trailing separator — deleting 'd' in
  // "cat dog" lands at "cat " and the guard then rewrites it to "cat",
  // swallowing the space together with the letter.
  readonly property string visiblePart: root.filterActive ? root.query.slice(Flags.prefix(root.query, root.parsed).length) : root.query

  // The query field is NOT bound to visiblePart: a live `text:` binding that
  // re-sets the text on every keystroke (via the onTextEdited write-back)
  // resets the field's internal edit state mid-input and duplicates the next
  // committed character. Sync is therefore write-on-difference only: while the
  // user types field.text == visiblePart, so nothing is pushed back in.
  onVisiblePartChanged: {
    if (queryField !== undefined && queryField.text !== root.visiblePart)
      queryField.text = root.visiblePart
  }

  function applyFieldText(part) {
    if (root.filterActive) {
      root.query = Flags.prefix(root.query, root.parsed) + part
    } else {
      root.query = part
    }
  }

  function removeFilter() {
    root.query = root.stripped
    queryField.cursorPosition = 0
  }

  // Chip colors stay theme-driven: the pill uses the accent and the label
  // text picks whichever of the two menu surfaces contrasts harder with it,
  // so both dark and light themes stay readable.
  function relLum(c) {
    var f = function(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b)
  }
  function contrastOf(a, b) {
    var la = root.relLum(a), lb = root.relLum(b)
    if (la < lb) { var t = la; la = lb; lb = t }
    return (la + 0.05) / (lb + 0.05)
  }
  // Theme-dependent but static for the whole session, so a read-only property
  // (computed once at load) is enough.
  readonly property color chipTextColor: (function() {
    var a = Color.accent
    var c1 = Color.menu.background, c2 = Color.menu.text
    return root.contrastOf(a, c1) >= root.contrastOf(a, c2) ? c1 : c2
  })()

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
      if (root.parsedMode === "pinterest") return "Search Pinterest for \u201C" + root.stripped + "\u201D"
      if (root.parsedMode === "images") return "Google Images for \u201C" + root.stripped + "\u201D"
      if (root.parsedMode === "artstation") return "Search ArtStation for \u201C" + root.stripped + "\u201D"
      if (root.parsedMode === "sketchfab") return "Search Sketchfab for \u201C" + root.stripped + "\u201D"
      if (root.parsedMode === "youtube") return "Search YouTube for \u201C" + root.stripped + "\u201D"
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

  // Column count is a fixed layout choice (rows wrap until 3 are visible);
  // the cells shrink with the panel width via cellWidth = width/gridCols, so
  // the icons never clip. 6 gives a comfortable 2-row glance at 1/2 of apps
  // on a 1080p panel.
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
        root.debugLog("ensureApps appLibrary threw: " + e)
        root.appIndexReady = false
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
  readonly property color scrimColor: Color.menu.scrim
  readonly property color cardColor: Color.menu.background
  readonly property color fgColor: Color.menu.text
  readonly property color dimColor: Qt.darker(Color.menu.text, 1.45)
  readonly property color selColor: Color.menu.selectedText

  property int headerHeight: Math.max(Style.space(50), Style.spacing.controlHeight + Style.spacing.md * 2)
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
    // Settings view replaces the search content entirely.
    if (root.settingsOpen) return root.settingsPanelHeight
    // Auto mode with an empty query is just the line.
    if (!root.searchMode && !root.inApps && !root.inFiles) return 0
    if (root.showHint) return Style.space(44)
    if (root.gridMode) return root.gridHeight
    return root.listHeight
  }

  // Height of the settings panel: header + 3 island toggles + separator +
  // default-mode row + show-hidden toggle + flags field + buttons row. Kept
  // derived from the real content so adding/removing a row can't overflow the
  // fixed-height card.
  readonly property int settingsPanelHeight: settingsControlCol.implicitHeight

  // ---- host lifecycle ----
  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    root._opening = false
    var q = String(payload.query || "")
    // Default search flags are prefilled on every open except the settings
    // entry (right-click/CTRL+K), which keeps a clean line. Storage stays
    // verbatim ("-p" or "-g "), but at open the flags get a single trailing
    // separator so the very first keystroke appends the query ("-p cats",
    // live chip) instead of glueing into the literal "-pcats".
    var fl = store.ready && !payload.settings ? String(store.defaultFlags || "") : ""
    if (/\S/.test(fl)) {
      fl = fl.replace(/\s+$/, "") + " "
    } else {
      fl = ""
    }
    root.query = q === "" ? fl : fl + q
    root.headerPos = ""
    var def = store.ready ? store.defaultMode : ""
    var wanted = payload.tab === "files" ? "files" : payload.tab === "apps" ? "apps" : ""
    if (wanted === "apps" && !store.showApps) wanted = ""
    if (wanted === "files" && !store.showFiles) wanted = ""
    if (def === "apps" && !store.showApps) def = ""
    if (def === "files" && !store.showFiles) def = ""
    root.activeTab = wanted === "" && (def === "apps" || def === "files") ? def : wanted
    root.settingsOpen = !!payload.settings
    root.selectedIndex = 0
    root.gridIndex = 0
    root.disarmPointer()
    root.ensureApps()
    root.opened = true
    root.refreshResults()
    Qt.callLater(function() {
      // The field outlives individual opens; make it show the fresh query
      // before focusing (the onVisiblePartChanged sync also covers this, but
      // the caret math below must run on the up-to-date text).
      if (queryField.text !== root.visiblePart) queryField.text = root.visiblePart
      if (!root.settingsOpen) {
        queryField.forceActiveFocus()
        // Prefilled default flags must stand: put the caret after them so the
        // first keystroke appends the query instead of replacing the flag.
        if (fl === "") queryField.selectAll()
        else queryField.cursorPosition = queryField.text.length
      }
    })
  }

  function close() {
    fileSearch.cancel()
    root.opened = false
    root.selectedIndex = 0
    root.gridIndex = 0
  }

  // ---- settings staging ----
  // Snapshot the store into the draft on every open; Apply copies the draft
  // back, Close just throws the draft away.
  function seedSettings() {
    root.draftShowO = store.showO
    root.draftShowApps = store.showApps
    root.draftShowFiles = store.showFiles
    root.draftDefaultMode = store.defaultMode
    root.draftShowHidden = store.showHidden
    root.draftDefaultFlags = store.defaultFlags
    root.settingsIndex = 0
  }

  function settingsMove(dir) {
    var n = 8 // toggles x3 + dropdown + hidden toggle + flags field + Close + Apply
    root.settingsIndex = (root.settingsIndex + dir + n) % n
  }

  function settingsActivate() {
    switch (root.settingsIndex) {
    case 0: showOToggle.clicked(); break
    case 1: showAppsToggle.clicked(); break
    case 2: showFilesToggle.clicked(); break
    case 3: defaultModeDropdown.toggle(); break
    case 4: showHiddenToggle.clicked(); break
    case 5:
      defaultFlagsField.forceActiveFocus()
      defaultFlagsField.cursorPosition = defaultFlagsField.text.length
      break
    case 6: root.exitSettings(); break
    case 7: root.settingsApply(); break
    }
  }

  // Commit the draft into the store; the panel stays open for more tweaking.
  function settingsApply() {
    store.showO = root.draftShowO
    store.showApps = root.draftShowApps
    store.showFiles = root.draftShowFiles
    store.defaultMode = root.draftDefaultMode
    store.showHidden = root.draftShowHidden
    // Kept verbatim (no trim): "-g " must survive so the chip is live on the
    // next open, same rule as SettingsStore.apply().
    store.defaultFlags = root.draftDefaultFlags
    store.save()
  }

  // Discard the draft and leave the settings view.
  function exitSettings() {
    if (!root.settingsOpen) return
    root.settingsOpen = false
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
    if (root.hasFlag || root.stripped !== "") root.headerPos = ""
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
    if (root.suggestionText === "") return
    if (root.filterActive) {
      root.query = Flags.prefix(root.query, root.parsed) + root.suggestionText
    } else {
      root.query = root.suggestionText
    }
  }

  function launchApp(g) {
    root.debugLog("launch " + g.appId)
    if (root.appLibrary) root.appLibrary.launch(g.appId, g.label)
    else appIndex.launch(g.appId)
  }

  // ---- mode switching ----
  function cycleMode(dir) {
    // Visual order of the enabled header islands: O -> APPS -> FILES, then
    // the idle query line ("auto"); the cycle wraps. Islands turned off in
    // the settings are skipped, and the query line can never be disabled.
    var order = []
    if (store.showO) order.push("omarchy")
    if (store.showApps) order.push("apps")
    if (store.showFiles) order.push("files")
    order.push("")
    if (order.length === 1) return
    var i = order.indexOf(root.headerPos)
    if (i < 0) i = 0
    root.gridEngaged = false
    root.headerPos = order[(i + dir + order.length) % order.length]
    if (root.headerPos === "apps") root.activeTab = "apps"
    else if (root.headerPos === "files") root.activeTab = "files"
    else root.activeTab = ""
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

  // In-card hotkeys (UI_SCHEME.md [Hotkeys] / [Alternate controls]):
  // CTRL+1 opens the standard omarchy menu, CTRL+2 forces the APPS tab,
  // CTRL+3/CTRL+F the FILES tab, CTRL+4/CTRL+G -g, CTRL+5/CTRL+P -p,
  // CTRL+6/CTRL+I -i, CTRL+0/CTRL+R -r, CTRL+D -d, CTRL+K toggles the
  // settings view. The flag ones prefill the query line so Enter hands the
  // typed query to the requested search.
  function onHotkey(cmd) {
    if (cmd === "menu") {
      root.openOmarchy()
      return
    }
    if (cmd === "apps") {
      root.setTab("apps")
      return
    }
    if (cmd === "files") {
      root.setTab("files")
      return
    }
    if (cmd === "settings") {
      // CTRL+K toggles the settings view; the draft is seeded and the panel
      // gets keyboard focus from onSettingsOpenChanged.
      root.settingsOpen = !root.settingsOpen
      return
    }
    root.query = "-" + cmd + " "
    queryField.forceActiveFocus()
    queryField.positionLength = 0
  }

  // ---- activation ----
  // Enter routes automatically: the selected app/file opens, and any mode
  // with no matches (or flag -g) falls back to a Google search.
  function activate() {
    if (root._opening) return
    if (root._activating) return
    // Enter on the highlighted O island hands off to the stock Omarchy menu,
    // exactly like its click. headerPos resets as soon as the user types, so
    // the query line is always idle here.
    if (root.headerPos === "omarchy") {
      root.openOmarchy()
      return
    }
    root._activating = true
    try {
      if (root.hasFlag) {
        var req = root.requestModes()
        if (req.length >= 2) {
          root.runRequests(req, root.stripped)
          return
        }
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

  // Flag tokens that fire an external action with the query, in typed order.
  readonly property var requestModeMap: ({ g: "web", p: "pinterest", i: "images", "as": "artstation", "sf": "sketchfab", y: "youtube", r: "run", o: "menu" })

  // Mode -> URL builder for every browser-dispatch mode. Used by BOTH the
  // single-mode runMode and the multi-flag runRequests so a new "-x" flag or
  // URL scheme only has to be registered here (mirror QueryBar.placeholderFor).
  readonly property var urlBuilders: ({
    web: Search.googleUrl,
    pinterest: Search.pinterestUrl,
    images: Search.imagesUrl,
    artstation: Search.artstationUrl,
    sketchfab: Search.sketchfabUrl,
    youtube: Search.youtubeUrl
  })

  function webLaunch(mode, q) {
    if (q) Quickshell.execDetached(["omarchy", "launch", "browser", root.urlBuilders[mode](q)])
  }

  function requestModes() {
    var out = []
    var fl = root.parsed.flags || []
    for (var i = 0; i < fl.length; i++) {
      var m = root.requestModeMap[fl[i]]
      if (m && out.indexOf(m) < 0) out.push(m)
    }
    return out
  }

  // Execute several external actions at once (e.g. "-g -p cats" opens Google
  // and Pinterest). The card closes once after all of them are dispatched.
  function runRequests(modes, q) {
    root._opening = true
    for (var i = 0; i < modes.length; i++) {
      if (root.urlBuilders[modes[i]]) {
        root.webLaunch(modes[i], q)
        continue
      }
      switch (modes[i]) {
      case "run":
        if (q) Quickshell.execDetached(["bash", "-lc", q])
        break
      case "menu":
        Quickshell.execDetached(["omarchy-shell", "shell", "toggle", "omarchy.menu", JSON.stringify({ menu: "root" })])
        break
      }
    }
    root.close()
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
    case "web":
    case "pinterest":
    case "images":
    case "artstation":
    case "sketchfab":
    case "youtube": {
      if (!q) return
      root._opening = true
      root.webLaunch(mode, q)
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
  onSettingsOpenChanged: {
    if (root.settingsOpen) {
      root.seedSettings()
      // Hands the panel the keyboard: the query line must NOT get focus while
      // settings are staged, or arrow keys would drive search instead of the
      // settings cursor.
      Qt.callLater(function() { settingsKeys.forceActiveFocus() })
    } else {
      // Close/Apply/Esc leave the settings view: back to the query line.
      root.headerPos = ""
      queryField.forceActiveFocus()
    }
  }
  onQueryChanged: {
    if (!root.opened) return
    // Any typing leaves the settings view back to search.
    if (root.settingsOpen && root.query !== "") root.settingsOpen = false
    root.refreshResults()
  }
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

  SettingsStore {
    id: store

    // A hidden island must not leave a mode selected with no way to leave it
    // by click; fall back to the idle line (keyboard cycling already skips
    // the disabled islands).
    onShowAppsChanged: {
      if (!store.showApps && root.activeTab === "apps") root.activeTab = ""
      if (root.opened) root.refreshResults()
    }
    onShowFilesChanged: {
      if (!store.showFiles && root.activeTab === "files") root.activeTab = ""
      if (root.opened) root.refreshResults()
    }
    onShowOChanged: {
      if (!store.showO && root.headerPos === "omarchy") root.headerPos = ""
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
      // The card carries the theme's popup border ([popups] border tokens, which
      // reference hyprland.active-border so the outline follows the theme and
      // Hyprland's active-window border like every other overlay plugin),
      // while the interior keeps the islands (O / APPS / FILES / query line)
      // as separate outlined controls.
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))

      // Clicking empty card space returns focus to the query line.
      MouseArea {
        anchors.fill: parent
        onClicked: queryField.forceActiveFocus()
      }

      Item {
        id: keyCatcher
        anchors.fill: parent
        // Same visual gutter on every edge. Inset top/bottom = spacing.md, and
        // the header/list rows add ~8px of vertical slack, so the sides use the
        // popup padding token to land on the same perceived distance from the
        // islands and the query line.
        anchors.topMargin: Style.spacing.md
        anchors.bottomMargin: Style.spacing.md
        anchors.leftMargin: Style.spacing.popupPadding
        anchors.rightMargin: Style.spacing.popupPadding

        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (root.settingsOpen) root.exitSettings()
            else root.close()
            event.accepted = true
          } else if ((event.modifiers & Qt.ControlModifier) && Flags.ctrlCommand(event.key, true) !== "") {
            root.onHotkey(Flags.ctrlCommand(event.key, true))
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
          height: root.headerHeight
          spacing: root.showTabs ? Style.spacing.lg : 0
          Behavior on spacing { NumberAnimation { duration: 180; easing.type: Easing.InOutQuad } }

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
                visible: store.showO
                active: root.headerPos === "omarchy"
                onClicked: root.openOmarchy()
              }

              SpotlightTab {
                id: appsTab
                text: "APPS"
                icon: "\uf00a"
                visible: store.showApps
                active: !root.hasFlag && root.activeTab === "apps"
                onClicked: root.toggleTab("apps")
              }

              SpotlightTab {
                id: filesTab
                text: "FILES"
                icon: "\uf07b"
                visible: store.showFiles
                active: !root.hasFlag && root.activeTab === "files"
                onClicked: root.toggleTab("files")
              }
            }
          }

          // Query line host. Once a leading flag is confirmed, the chips
          // render over the left edge of the field and the field edits only
          // the part after them; the full raw query stays root.query.
          Item {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredHeight: queryField.implicitHeight

            QueryBar {
              id: queryField
              anchors.fill: parent
              tabMode: root.activeTab
              gridActive: root.gridMode && root.gridEngaged
              filterActive: root.filterActive
              rawMode: root.parsedMode
              leftPadding: root.filterActive
                ? queryField.defaultLeftPadding + chipRow.width + Style.spacing.xs + Style.spacing.sm
                : queryField.defaultLeftPadding
              suggestion: root.suggestionText
              onTextEdited: root.applyFieldText(queryField.text)
              onActivate: root.activate()
              onTabComplete: root.completeSuggestion()
              onCycleMode: root.cycleMode(dir)
              onNavigateGrid: root.gridStep(dir)
              onHotkey: root.onHotkey(cmd)
              onRemoveFilter: root.removeFilter()
              onEscapeKey: {
                if (root.settingsOpen) root.exitSettings()
                else root.close()
              }
            }

            Row {
              id: chipRow
              visible: root.filterActive
              x: queryField.defaultLeftPadding
              y: Math.round((parent.height - height) / 2)
              spacing: Style.spacing.xs
              z: queryField.z + 1

              Repeater {
                model: root.chips
                delegate: Rectangle {
                  height: Math.round(Style.space(24))
                  width: chipText.implicitWidth + Style.space(14)
                  radius: Math.max(2, Style.cornerRadius)
                  color: Color.accent
                  border.width: Math.max(1, Style.space(1))
                  border.color: Util.alpha(root.chipTextColor, 0.30)

                  Text {
                    id: chipText
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Style.space(7)
                    anchors.rightMargin: Style.space(7)
                    text: modelData
                    font.family: Style.font.family
                    font.pixelSize: Style.font.title
                    color: root.chipTextColor
                    verticalAlignment: Text.AlignVCenter
                    horizontalAlignment: Text.AlignHCenter
                  }
                }
              }
            }

            // Clicking a chip moves the caret to the start of the query text
            // (no editing of the chip itself, no mode cycling).
            MouseArea {
              visible: chipRow.visible
              anchors.fill: chipRow
              z: chipRow.z + 1
              onClicked: function() {
                queryField.cursorPosition = 0
                queryField.forceActiveFocus()
              }
            }
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

          Item {
            id: settingsView
            visible: root.settingsOpen
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: root.settingsPanelHeight

            // Keyboard-driven panel: this own the keys whenever settings are
            // open. The cursor (settingsIndex + hasCursor) walks the controls
            // with Up/Down/j/k/Tab; Enter/Space activates the target; Esc
            // discards and closes. While the flags editor is focused or the
            // dropdown popup is open, keys go to them instead (blocked).
            PanelKeyCatcher {
              id: settingsKeys
              anchors.fill: parent
              focus: true
              blocked: defaultFlagsField.activeFocus || defaultModeDropdown.popupOpen
              onMoveRequested: function(dx, dy) { root.settingsMove(dy) }
              onTabRequested: function(dir) { root.settingsMove(dir) }
              onActivateRequested: root.settingsActivate()
              onCloseRequested: root.exitSettings()

              Column {
                id: settingsControlCol
                anchors.fill: parent
                spacing: Style.spacing.sm

                PanelSectionHeader {
                  width: parent.width
                  text: "UI elements"
                }

                Toggle {
                  id: showOToggle
                  width: parent.width
                  label: "Omarchy island"
                  description: "Show the O button that opens the Omarchy menu"
                  checked: root.draftShowO
                  hasCursor: root.settingsIndex === 0
                  onHovered: function(h) { if (h) root.settingsIndex = 0 }
                  onClicked: root.draftShowO = !root.draftShowO
                }

                Toggle {
                  id: showAppsToggle
                  width: parent.width
                  label: "Apps island"
                  description: "Show the APPS search button"
                  checked: root.draftShowApps
                  hasCursor: root.settingsIndex === 1
                  onHovered: function(h) { if (h) root.settingsIndex = 1 }
                  onClicked: root.draftShowApps = !root.draftShowApps
                }

                Toggle {
                  id: showFilesToggle
                  width: parent.width
                  label: "Files island"
                  description: "Show the FILES search button"
                  checked: root.draftShowFiles
                  hasCursor: root.settingsIndex === 2
                  onHovered: function(h) { if (h) root.settingsIndex = 2 }
                  onClicked: root.draftShowFiles = !root.draftShowFiles
                }

                PanelSeparator {
                  width: parent.width
                }

                Dropdown {
                  id: defaultModeDropdown
                  width: parent.width
                  label: "Default search mode"
                  options: [
                    { value: "auto", label: "Auto" },
                    { value: "apps", label: "Apps" },
                    { value: "files", label: "Files" }
                  ]
                  value: root.draftDefaultMode
                  hasCursor: root.settingsIndex === 3
                  onHovered: function(h) { if (h) root.settingsIndex = 3 }
                  onChanged: root.draftDefaultMode = value
                }

                Toggle {
                  id: showHiddenToggle
                  width: parent.width
                  label: "Show hidden by default"
                  description: "Include dotfiles in file and directory searches"
                  checked: root.draftShowHidden
                  hasCursor: root.settingsIndex === 4
                  onHovered: function(h) { if (h) root.settingsIndex = 4 }
                  onClicked: root.draftShowHidden = !root.draftShowHidden
                }

                TextField {
                  id: defaultFlagsField
                  width: parent.width
                  placeholderText: "Flags prefilled on open  e.g. -g -. -p"
                  onTextChanged: {
                    // Guarded: never echo an external set back into the draft,
                    // so the caret is not yanked around while typing.
                    if (root.draftDefaultFlags !== text)
                      root.draftDefaultFlags = text
                  }
                  Connections {
                    target: root
                    function onDraftDefaultFlagsChanged() {
                      if (defaultFlagsField.text !== root.draftDefaultFlags && !defaultFlagsField.activeFocus)
                        defaultFlagsField.text = root.draftDefaultFlags
                    }
                  }
                  Keys.onEscapePressed: function(event) {
                    // First Esc drops out of the editor back to the settings
                    // cursor (the panel's own Esc then closes settings).
                    event.accepted = true
                    settingsKeys.forceActiveFocus()
                  }
                }

                Row {
                  width: parent.width
                  layoutDirection: Qt.RightToLeft
                  spacing: Style.spacing.md
                  Button {
                    id: applyButton
                    text: "Apply"
                    selected: true
                    hasCursor: root.settingsIndex === 7
                    onHovered: function(h) { if (h) root.settingsIndex = 7 }
                    onClicked: root.settingsApply()
                  }
                  Button {
                    id: closeButton
                    text: "Close"
                    hasCursor: root.settingsIndex === 6
                    onHovered: function(h) { if (h) root.settingsIndex = 6 }
                    onClicked: root.exitSettings()
                  }
                }
              }
            }
          }

          Text {
            visible: root.showHint && !root.settingsOpen
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: Style.space(48)
            text: root.hintText
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.title
            color: root.dimColor
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideMiddle
          }

          GridView {
            id: appGrid
            visible: root.gridMode && !root.showHint && !root.settingsOpen
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
            visible: !root.gridMode && !root.showHint && !root.settingsOpen
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
          font.pixelSize: Style.font.body
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