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
  // Reveal the selected list row, rolling the list along with keyboard
  // arrows and pointer hovering. Hovering rows that are already visible is a
  // no-op (Contain only scrolls when the row is off-screen).
  onSelectedIndexChanged: {
    if (root.selectedIndex >= 0) Qt.callLater(root.revealListSelection)
  }
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
  // Help view: opened via CTRL+H. Same content-area swap as settings, but
  // read-only: Esc leaves it (card stays), Enter/typing/down-arrows dismiss
  // it, Esc on 'omarchy' etc. do not run anything underneath.
  property bool helpOpen: false
  // When non-empty, a shell command was armed by the first Enter (flash shown,
  // nothing run); the second Enter actually executes it. Cleared the moment
  // the query changes, settings open or the card closes, so only the IDENTICAL
  // follow-up Enter confirms. Empty = either confirm off or command already run.
  property string runPendingCmd: ""
  // ---- settings draft (staged until Apply) ----
  property bool draftShowO: true
  property bool draftShowApps: true
  property string draftAppsView: "grid"
  property bool draftShowFiles: true
  property string draftDefaultMode: "auto"
  property bool draftShowHidden: false
  property bool draftAnimations: true
  property bool draftConfirmRun: true
  property string draftRunTarget: "silent"
  property bool draftBarIcon: true
  // History cap as free text while editing ("0" .. "200"), parsed on Apply.
  property string draftHistory: "10"
  property string draftDefaultFlags: ""
  // Keyboard cursor over the settings controls (see settingsKeys).
  property int settingsIndex: 0
  // Transient confirmation shown in the hint line after CTRL+S saves the
  // default flags; cleared by flashTimer.
  property string flashNote: ""
  readonly property bool flashActive: root.flashNote !== ""
  // Silent -r run feedback state. _runTracked = an untracked silent run is in
  // flight (the card must not auto-close until it finishes); _runOut holds the
  // capped tail of its combined output; _resultGood (null | true | false) tags
  // the current flashNote as a run result so the status line can colour it;
  // _runSeq is a generation counter — a stale process exit (the user Esc'd,
  // reopened or re-ran meanwhile) must not flash/close a card that moved on.
  property bool _runTracked: false
  property string _runOut: ""
  property int _runSeq: 0
  property var _resultGood: null

  // ---- resend query (history dropdown) ----
  // Down on an empty line pops the list of past queries; Up/Down walk it and
  // Enter INSERTS the highlighted one into the field (it does not run it — one
  // more Enter does that). Esc or any typing closes it again. The highlight is
  // the ordinary selectedIndex, so the delegate, the scroll reveal and the
  // scrollbar all work unchanged.
  property bool historyOpen: false

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

  // Backspace on the chip column removes ONE flag (the most recently typed);
  // only the last remaining flag falls back to removeFilter (clear all).
  // The trailing space after the kept flags is mandatory or the leftover
  // would glue into the text ("-gcats") and stop being a chip.
  function popFilter() {
    var p = Flags.prefix(root.query, root.parsed)
    if (p.trim().split(/\s+/).length <= 1) {
      root.removeFilter()
      return
    }
    var m = p.match(/[ \t]*-[a-z.]+[ \t]*$/)
    root.query = (m ? p.slice(0, m.index) + " " : "") + root.stripped
    queryField.cursorPosition = 0
  }

  // Backspace at caret 0 on a RAW (non-chip) leading "-token": removes it as a
  // whole unit instead of stranding it. Only fires when filterActive is false
  // (the field text then equals the whole query), so the token is the true
  // leading edge of the string.
  function popRawToken() {
    var m = root.query.match(/^\s*-[a-z.]+(?:[ \t]+|$)/)
    if (m) {
      root.query = root.query.slice(m[0].length).replace(/^\s+/, "")
      queryField.cursorPosition = 0
    }
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

  // Master animation gate backed by the "Animations" settings toggle. When it
  // is off every duration collapses to 0 so the whole UI reacts instantly.
  readonly property bool animationsEnabled: store.animations
  function animMs(ms) {
    return root.animationsEnabled ? ms : 0
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
  // The islands are also individually switchable, so the cluster may be EMPTY
  // (every toggle off) while the query is still empty — that case must count
  // as collapsed too, otherwise the cluster sits at width 0 and leaves its 8px
  // RowLayout gap behind, which pushes the query line off-centre for good.
  readonly property bool anyIslandVisible: store.showO || store.showApps || store.showFiles
  readonly property bool showTabs: root.query === "" && !root.hasFlag && root.anyIslandVisible

  readonly property string listMode: root.inFiles ? "files" : ""

  readonly property bool appsLoading: root.allApps.length === 0

  readonly property string hintText: {
    if (root.historyOpen) {
      // Nothing recorded yet: say so instead of showing an empty box. The
      // list itself is zero-height, so the hint slot is the whole dropdown.
      if (root.rowsCount === 0) return "Empty list \u2014 nothing to resend yet"
      return "Resend " + (root.safeListIndex + 1) + "/" + root.rowsCount
        + " \u2014 Enter to insert, Esc to close"
    }
    if (root.hasFlag) {
      // Multiple request flags dispatch together (runRequests); that beats the
      // single-mode hint. Driven by requestModes() (the actual dispatch
      // targets), NOT by chips/swallowed, so it works even with an empty
      // query part where chips haven't formed yet. View flags (-f/-d/-a) are
      // not dispatch targets and never make this "multi".
      if (root.multiRequest) {
        var mLabels = root.requestLabels()
        if (mLabels.length > 0) return "Multi-search: " + mLabels.join(" + ")
      }
      if (root.parsedMode === "web") return "Search Google for \u201C" + root.stripped + "\u201D"
      if (root.parsedMode === "gpt") return "Ask ChatGPT: " + root.stripped
      if (root.parsedMode === "pinterest") return "Search Pinterest for \u201C" + root.stripped + "\u201D"
      if (root.parsedMode === "images") return "Google Images for \u201C" + root.stripped + "\u201D"
      if (root.parsedMode === "artstation") return "Search ArtStation for \u201C" + root.stripped + "\u201D"
      if (root.parsedMode === "sketchfab") return "Search Sketchfab for \u201C" + root.stripped + "\u201D"
      if (root.parsedMode === "youtube") return "Search YouTube for \u201C" + root.stripped + "\u201D"
      if (root.parsedMode === "ddg") return "Search DuckDuckGo for \u201C" + root.stripped + "\u201D"
      if (root.parsedMode === "deviantart") return "Search DeviantArt for \u201C" + root.stripped + "\u201D"
      if (root.parsedMode === "run") return "Run: " + root.stripped
      if (root.parsedMode === "opencode") return "Ask opencode: " + root.stripped
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

  // ---- resend query rows ----
  // The dropdown only offers itself when the mechanism is on and the line has
  // nothing typed in it. Flags do NOT block it (a defaultFlags prefill like
  // "-p " still counts as empty), but the APPS and FILES screens are left
  // alone — there Down already walks the rows and hijacking it would strand
  // the list behind the keyboard. An EMPTY list still opens: it explains
  // itself with the "Empty list" hint instead of doing nothing on Down.
  readonly property bool historyEligible: root.stripped === ""
    && !root.inApps && !root.inFiles
    && history.enabled
  readonly property var historyRows: history.entries.map(function(e) {
    return { kind: "history", label: e, path: e, iconUrl: "" }
  })

  readonly property var displayRows: root.historyOpen ? root.historyRows
    : (root.searchMode ? root.searchRows
    : (root.inFiles ? root.fileRows : (root.appsListMode ? root.gridItems : ([]))))
  readonly property int rowsCount: root.displayRows.length

  // APPS screen: the icon grid by default, or a plain one-row-per-app list
  // when the "Apps view" setting says so. appsScreen is the shared parent so
  // exactly one of the two renders (and contentHeight picks the right height:
  // gridHeight, or the list path that already yields listHeight).
  readonly property bool appsScreen: root.inApps && !root.showHint
  readonly property bool appsListMode: root.appsScreen && store.appsView === "list"
  readonly property bool gridMode: root.appsScreen && store.appsView !== "list"

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
  // Card gutter, the single source for the inner padding of the card: the
  // vertical edges take md (6) and the sides take 11 — the sides are
  // deliberately roomier than the top/bottom, which is what the layout wants.
  readonly property int cardPadY: Style.spacing.md
  readonly property int cardPadX: Style.space(11)
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
    // Settings/help views replace the search content entirely.
    if (root.settingsOpen) return root.settingsPanelHeight
    if (root.helpOpen) return root.helpPanelHeight
    if (root.catVisible) return root.catPanelHeight
    // The resend dropdown fills the content area even though the query is
    // empty — without this the "empty line" early return below would collapse
    // the card to nothing while the list is up. Unlike the search hint, the
    // resend hint does NOT replace the content: the "Resend n/m" line sits
    // above the list (the list is offset by the same slot height), because
    // that hint is what tells you Enter inserts instead of running.
    if (root.historyOpen) {
      var slot = (root.showHint || root.flashActive) ? Style.space(48) : 0
      return slot + root.listHeight
    }
    // Auto mode with an empty query is just the line; the CTRL+S flash keeps
    // the hint slot open briefly even when there is nothing else to show.
    if (!root.searchMode && !root.inApps && !root.inFiles)
      return root.flashActive ? Style.space(44) : 0
    if (root.showHint || root.flashActive) return Style.space(44)
    if (root.gridMode) return root.gridHeight
    return root.listHeight
  }

  // Card height is animated through a single source of truth: both card.height
  // AND the centering y read cardHeightAnim, so expanding and re-centering move
  // together every frame. (Two chained Behaviors on height+y retarget y from
  // the new target each frame and lag behind — the panel visibly shuffles to
  // its new position only after it finished growing.)
  readonly property int targetCardHeight: root.headerHeight + (root.contentHeight > 0 ? root.contentHeight + Style.spacing.sm : 0) + Style.spacing.md * 2
  property real cardHeightAnim: root.targetCardHeight
  Behavior on cardHeightAnim {
    NumberAnimation { duration: root.animMs(200); easing.type: Easing.OutCubic }
  }

  // Height of the settings panel: header + 3 island toggles + separator +
  // default-mode row + show-hidden toggle + animations toggle + run-warning
  // toggle + flags field + buttons row. Kept derived from the real content so
  // adding/removing a row can't overflow the fixed-height card.
  readonly property int settingsPanelHeight: settingsControlCol.implicitHeight

  // Height of the help view: section header + row list (capped, scrolls when
  // longer) + hint footer, all derived from real content.
  readonly property int helpPanelHeight: helpControlCol.implicitHeight

  // Static help content shown by the [CTRL+H] page, mirroring help_exmpl.md.
  // Row kinds: "banner" (plugin title + tagline), "header" (section title) or
  // "row" ("[label]" followed by what it does).
  readonly property var helpRows: [
    { kind: "banner", label: "Obscure", detail: "Hardly opinionated search-run bar." },
    { kind: "header", label: "Flags", detail: "" },
    { kind: "row", label: "-r <Query>", detail: "Run shell command" },
    { kind: "row", label: "-oc <Query>", detail: "Ask opencode in a terminal" },
    { kind: "row", label: "-f <Query>", detail: "Force file search" },
    { kind: "row", label: "-d <Query>", detail: "Directory search" },
    { kind: "row", label: "-a <Query>", detail: "App launcher" },
    { kind: "row", label: "-o <Query>", detail: "Omarchy menu search" },
    { kind: "row", label: "-g <Query>", detail: "Google search" },
    { kind: "row", label: "-gpt <Query>", detail: "Ask ChatGPT in the browser" },
    { kind: "row", label: "-p <Query>", detail: "Pinterest search" },
    { kind: "row", label: "-i <Query>", detail: "Google Images search" },
    { kind: "row", label: "-as <Query>", detail: "ArtStation search" },
    { kind: "row", label: "-sf <Query>", detail: "Sketchfab search" },
    { kind: "row", label: "-y <Query>", detail: "YouTube search" },
    { kind: "row", label: "-ddg <Query>", detail: "DuckDuckGo search" },
    { kind: "row", label: "-da <Query>", detail: "DeviantArt search" },
    { kind: "row", label: "-.", detail: "Show hidden results" },
    { kind: "header", label: "HotKeys", detail: "" },
    { kind: "row", label: "CTRL+1", detail: "Omarchy menu" },
    { kind: "row", label: "CTRL+2", detail: "Apps search" },
    { kind: "row", label: "CTRL+3", detail: "Files search" },
    { kind: "row", label: "CTRL+4", detail: "Google search" },
    { kind: "row", label: "CTRL+5", detail: "Pinterest search" },
    { kind: "row", label: "CTRL+6", detail: "Google Images search" },
    { kind: "row", label: "CTRL+0", detail: "Run shell command" },
    { kind: "row", label: "CTRL+F", detail: "Files search" },
    { kind: "row", label: "CTRL+D", detail: "Directory search" },
    { kind: "row", label: "CTRL+G", detail: "Google search" },
    { kind: "row", label: "CTRL+P", detail: "Pinterest search" },
    { kind: "row", label: "CTRL+I", detail: "Google Images search" },
    { kind: "row", label: "CTRL+O", detail: "Omarchy menu" },
    { kind: "row", label: "CTRL+R", detail: "Run shell command" },
    { kind: "row", label: "CTRL+K", detail: "Settings menu" },
    { kind: "row", label: "CTRL+S", detail: "Save current flags as default" },
    { kind: "row", label: "CTRL+H", detail: "Help page" },
    { kind: "row", label: "DOWN", detail: "Past queries (Enter to insert)" }
  ]
  readonly property int helpRowH: Style.space(30)
  // Cap the visible list so the card never grows off-screen; the tail rows are
  // reached by scrolling (helpMove).
  readonly property int helpVisibleRows: Math.min(root.helpRows.length, 13)

  // --- easter egg (unadvertised) ---
  // A leading "-cat" phrase makes the lower part of the card spread open to
  // show the ASCII cat for about a second, then collapse back. The art lives
  // HERE (mirrored from an untracked local cat_ee.txt); runtime never reads a
  // file. Deliberately absent from every help page, scheme and backlog doc.
  property bool catVisible: false
  property string catArt: "  /\\___/| C\\\n {>. o  )  ))\n  (=$==(  ))\n  ((__. _)}_"
  readonly property int catPanelHeight: Style.space(80)

  // ---- host lifecycle ----
  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    root._opening = false
    root.runPendingCmd = ""
    root.historyOpen = false
    // A fresh card is a fresh session for silent -r feedback: forget any
    // in-flight run's tracking and stale result note so a background process
    // can't flash onto the newly opened card.
    root._runSeq++
    root._runTracked = false
    root._runOut = ""
    root._resultGood = null
    root.flashNote = ""
    var q = String(payload.query || "")
    // Summon routes: payload.tab picks the mode the card opens in —
    // "apps" (grid), "files" (file list) or "auto" (empty line). An explicit
    // route mirrors the system's `omarchy-menu toggle apps`: it must WIN over
    // the default-flags prefill, otherwise a prefill like "-p " would break
    // out of the requested mode into a Pinterest chip. Only the plain open
    // (no tab) gets the default flags.
    var route = String(payload.tab || "")
    // payload.flag prefills the LINE with a flag instead of a route — the only
    // way to reach from a binding what a tab cannot express: a web search
    // (-g), a run (-r), hidden files (-.), a multi request (-g -p) or any
    // word flag (-as/-sf/-ddg/-da). It replaces the stored default flags for
    // the same reason an explicit tab does (a standing "-p " prefill would
    // otherwise ride along), and a non-string value is ignored rather than
    // stringified into the query. The mode itself needs no code: with a flag
    // in the line inApps/inFiles already resolve from parseQuery's mode.
    var f = typeof payload.flag === "string" ? payload.flag : ""
    var fl = f
    if (!/\S/.test(fl) && store.ready && !payload.settings && route === "") {
      fl = String(store.defaultFlags || "")
    }
    if (/\S/.test(fl)) {
      fl = fl.replace(/\s+$/, "") + " "
    } else {
      fl = ""
    }
    if (route === "apps" && !store.showApps) route = ""
    if (route === "files" && !store.showFiles) route = ""
    root.query = q === "" ? fl : fl + q
    root.headerPos = ""
    var def = store.ready ? store.defaultMode : ""
    var wanted = route === "files" ? "files" : route === "apps" ? "apps" : ""
    if (def === "apps" && !store.showApps) def = ""
    if (def === "files" && !store.showFiles) def = ""
    root.activeTab = wanted === "" && (def === "apps" || def === "files") ? def : wanted
    root.settingsOpen = !!payload.settings
    root.helpOpen = false
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
    root.runPendingCmd = ""
    root.historyOpen = false
    root.catVisible = false
    root.selectedIndex = 0
    root.gridIndex = 0
  }

  // ---- settings staging ----
  // Snapshot the store into the draft on every open; Apply copies the draft
  // back, Close just throws the draft away.
  function seedSettings() {
    root.draftShowO = store.showO
    root.draftShowApps = store.showApps
    root.draftAppsView = store.appsView
    root.draftShowFiles = store.showFiles
    root.draftDefaultMode = store.defaultMode
    root.draftShowHidden = store.showHidden
    root.draftAnimations = store.animations
    root.draftConfirmRun = store.confirmRun
    root.draftRunTarget = store.runTarget
    root.draftBarIcon = store.showBarIcon
    root.draftHistory = String(store.historyLimit)
    root.draftDefaultFlags = store.defaultFlags
    root.settingsIndex = 0
  }

  // Vertical walk (Up/Down + j/k). The bottom buttons row is ONE vertical
  // target: Down from the last field enters it (landing on Apply), Down while
  // inside is a no-op (nothing sits below and Down must never pick a button —
  // switching Apply/Close is Left/Right only), Up leaves back to the field.
  // Above the fields the walk is bounded to 0..10, no wrap.
  function settingsMove(dir) {
    if (root.settingsIndex > 11) {
      if (dir < 0) root.settingsIndex = 11
    } else {
      var next = root.settingsIndex + dir
      if (next > 11) root.settingsIndex = 12
      else root.settingsIndex = Math.max(0, next)
    }
  }

  // Tab/Shift+Tab still visit EVERY control including both buttons, so keyboard
  // users can reach Close directly with the tab chain (vertical walk treats
  // the row as a single unit).
  function settingsTab(dir) {
    var n = 14 // toggles x7 + segmented rows x3 + 2 text fields + Apply + Close
    root.settingsIndex = (root.settingsIndex + dir + n) % n
  }

  // Left/Right (+ h/l) act on the control the cursor stands on: toggles flip,
  // the dropdowns step their options, the bottom row switches between
  // Apply/Close, the text fields do nothing (the editor gets the caret arrows
  // while focused).
  function settingsHorizontal(dir) {
    if (dir === 0) return
    if (root.settingsIndex >= 12) {
      root.settingsIndex = root.settingsIndex === 12 ? 13 : 12
      return
    }
    if (root.settingsIndex === 2) {
      root.draftAppsView = root.dropdownStep(appsViewToggle.options, root.draftAppsView, dir)
      return
    }
    if (root.settingsIndex === 4) {
      root.draftDefaultMode = root.dropdownStep(defaultModeToggle.options, root.draftDefaultMode, dir)
      return
    }
    if (root.settingsIndex === 7) {
      root.draftRunTarget = root.dropdownStep(runModeToggle.options, root.draftRunTarget, dir)
      return
    }
    // Toggle rows flip like Enter; anything else is a no-op for horizontal.
    switch (root.settingsIndex) {
    case 0: showOToggle.clicked(); break
    case 1: showAppsToggle.clicked(); break
    case 3: showFilesToggle.clicked(); break
    case 5: showHiddenToggle.clicked(); break
    case 6: animationsToggle.clicked(); break
    case 8: confirmRunToggle.clicked(); break
    case 9: showBarIconToggle.clicked(); break
    }
  }

  // Next (previous) option value of a segmented option list, wrapping around.
  // The kit's SegmentedToggle/ButtonGroup only reports changes when a chip is
  // clicked, so the keyboard path writes the draft itself and the value
  // binding follows; the same step drives the Dropdown keyboard path.
  function dropdownStep(options, current, dir) {
    if (options.length === 0) return current
    var idx = 0
    for (var i = 0; i < options.length; i++)
      if (options[i].value === current) { idx = i; break }
    return options[(idx + dir + options.length) % options.length].value
  }

  function settingsActivate() {
    switch (root.settingsIndex) {
    case 0: showOToggle.clicked(); break
    case 1: showAppsToggle.clicked(); break
    case 2: root.draftAppsView = root.dropdownStep(appsViewToggle.options, root.draftAppsView, 1); break
    case 3: showFilesToggle.clicked(); break
    case 4: root.draftDefaultMode = root.dropdownStep(defaultModeToggle.options, root.draftDefaultMode, 1); break
    case 5: showHiddenToggle.clicked(); break
    case 6: animationsToggle.clicked(); break
    case 7: root.draftRunTarget = root.dropdownStep(runModeToggle.options, root.draftRunTarget, 1); break
    case 8: confirmRunToggle.clicked(); break
    case 9: showBarIconToggle.clicked(); break
    case 10:
      historyField.forceActiveFocus()
      // Six digits wide, so the old value is almost always replaced whole:
      // select it instead of parking the caret after it, otherwise the user
      // has to backspace through "10" before typing a new number.
      historyField.selectAll()
      break
    case 11:
      defaultFlagsField.forceActiveFocus()
      defaultFlagsField.cursorPosition = defaultFlagsField.text.length
      break
    case 12:
      root.settingsApply(); break
    case 13:
      root.exitSettings(); break
    }
  }

  // Commit the draft into the store; the panel stays open for more tweaking.
  function settingsApply() {
    store.showO = root.draftShowO
    store.showApps = root.draftShowApps
    store.appsView = root.draftAppsView
    store.showFiles = root.draftShowFiles
    store.defaultMode = root.draftDefaultMode
    store.showHidden = root.draftShowHidden
    store.animations = root.draftAnimations
    store.confirmRun = root.draftConfirmRun
    store.runTarget = root.draftRunTarget
    store.showBarIcon = root.draftBarIcon
    store.historyLimit = store.clampHistory(root.draftHistory)
    root.draftHistory = String(store.historyLimit)
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

  // Leave the help view; the card itself stays open (focus returns to the
  // query line via onHelpOpenChanged).
  function exitHelp() {
    if (!root.helpOpen) return
    root.helpOpen = false
  }

  // Easter egg trigger: a query that STARTS with the raw "-cat" token (it is
  // not a real flag, so it can never collide) pops the cat panel open and
  // re-arms its one-second timer; dropping the phrase collapses it at once.
  function checkCat() {
    if (root.query.match(/^\s*-cat(?:\s+|$)/)) {
      root.catVisible = true
      catEeTimer.restart()
    } else if (root.catVisible) {
      root.catVisible = false
    }
  }

  // Fires a shell command with an optional Enter-twice gate. Returns true when
  // the command was executed (the caller closes the card) and false when it
  // was only ARMED (the caller must keep the card open and show the flash).
  // The gate is `store.confirmRun`; an already-armed identical command skips
  // straight to execution. Any edit to the query (onQueryChanged) or card
  // close clears the arm, so the second Enter can never fire a stale command.
  function runShell(q) {
    if (store.confirmRun && root.runPendingCmd !== q) {
      root.runPendingCmd = q
      root.flashNote = "Run in shell? Press Enter again to confirm"
      flashTimer.restart()
      return false
    }
    root.runPendingCmd = ""
    root.dispatchShell(q)
    return true
  }

// The -r / Ctrl+0 delivery channel, honouring the runTarget setting:
// "silent" runs bash in the background and reports the outcome in the status
// line: the card stays open ("Running… (Esc to dismiss)") until the command
// exits, then flashes "Done!" (accent) and auto-closes, or "Error: <output>"
// (urgent) and waits for Esc so the message can be read. "external" opens a
// terminal so the command + its output are visible (same terminal path as
// -oc, and like it the query is one argv element — no shell quoting
// involved). In external mode an interactive shell is handed over after the
// command, otherwise the window would close the instant bash exits and there
// would be nothing to look at. The handover is a fresh "\nexec bash" line — a
// stray ";" after the newline would be "syntax error near unexpected token
// `;'" (a newline already terminates the command), and "\n" also trims a rare
// "# comment" query tail.
function dispatchShell(q) {
  if (store.runTarget === "external") {
    Quickshell.execDetached(["omarchy", "launch", "terminal", "bash", "-lc", q + "\nexec bash"])
    return
  }
  root._runSeq++
  silentRun.seq = root._runSeq
  root._runTracked = true
  root._runOut = ""
  root._resultGood = null
  silentRun.command = ["bash", "-lc", q]
  silentRun.running = true
  root.flashNote = "Running… (Esc to dismiss)"
}

// One-line summary of a failed silent run's output for the status line.
function runErrorTail() {
  var s = String(root._runOut || "").replace(/\s+/g, " ").trim()
  if (s === "") return "non-zero exit"
  if (s.length > 120) s = "…" + s.slice(s.length - 120)
  return s
}

  // CTRL+S: remember the current flag chips (or their absence) as the default
  // prefill for future opens. The prefix only ever contains REAL chip tokens
  // (Flags.prefix stops at the first non-flag), so a mis-typed "-p -s" saves
  // exactly "-p". The draft is synced too, otherwise a later settings Apply
  // would overwrite this with a stale draft. Stored trimmed: open() re-pads
  // the single trailing space so the chip is live on the next summon.
  function saveDefaultFlags() {
    var p = Flags.prefix(root.query, root.parsed).trim()
    store.defaultFlags = p
    root.draftDefaultFlags = p
    store.save()
    root.flashNote = "Default flags saved: " + (p === "" ? "none" : p)
    flashTimer.restart()
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

  // Both row sources are bindings that hand back a FRESH array on every
  // re-evaluation, so watching them covers every path that swaps the content
  // without touching the query line: switching to the APPS tab by click or
  // CTRL+2, toggling the "Apps view" setting live, apps finishing their async
  // index load. Without this, resultsModel kept the rows of the PREVIOUS mode
  // (empty when coming from auto) and the apps-as-list screen rendered nothing
  // until the first keystroke ran refreshResults().
  onGridItemsChanged: root.syncGrid()
  onDisplayRowsChanged: root.syncResults()

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
    root.debugLog("syncResults rows=" + root.displayRows.length
      + " grid=" + root.gridItems.length
      + " gridMode=" + root.gridMode + " appsList=" + root.appsListMode)
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
    // Fresh results must start with the selection in view (selectedIndex is
    // already reset), otherwise a leftover contentY keeps showing old rows.
    Qt.callLater(root.revealListSelection)
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

  // Switching islands is a content change like any other: the row models are
  // refilled by the displayRows/gridItems watchers, and the list selection
  // starts from the top (the query line may hold no text at all).
  function setTab(mode) {
    root.gridEngaged = false
    root.activeTab = mode
    root.selectedIndex = 0
    queryField.forceActiveFocus()
  }

  function toggleTab(mode) {
    root.gridEngaged = false
    root.activeTab = root.activeTab === mode ? "" : mode
    root.selectedIndex = 0
    queryField.forceActiveFocus()
  }

  // In-card hotkeys (UI_SCHEME.md [Hotkeys] / [Alternate controls]):
  // CTRL+1 opens the standard omarchy menu, CTRL+2 forces the APPS tab,
  // CTRL+3/CTRL+F the FILES tab, CTRL+4/CTRL+G -g, CTRL+5/CTRL+P -p,
  // CTRL+6/CTRL+I -i, CTRL+0/CTRL+R -r, CTRL+D -d, CTRL+K toggles the
  // settings view, CTRL+S saves the current flags as the default prefill.
  // The flag ones prefill the query line so Enter hands the typed query to
  // the requested search.
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
      // gets keyboard focus from onSettingsOpenChanged. The resend list
      // cannot live under the panel, so it goes away with it.
      root.historyOpen = false
      root.settingsOpen = !root.settingsOpen
      return
    }
    if (cmd === "help") {
      // CTRL+H toggles the help view (see onHelpOpenChanged for focus).
      root.historyOpen = false
      root.helpOpen = !root.helpOpen
      return
    }
    if (cmd === "saveflags") {
      root.saveDefaultFlags()
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
    // Any real submission with a query in it goes on the resend list. The
    // early returns below (empty query, the O island) never reach this.
    if (root.stripped !== "") root.addHistory(root.stripped)
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
      if (root.inApps && root.appsListMode) {
        // Apps-as-list: the selection lives in selectedIndex (displayRows ==
        // gridItems here), so the generic row branch below would already do
        // the right thing — launch the highlighted app, else fall back to a
        // web search. Only the empty-query case needs its own guard: the list
        // shows every app then, and Enter must not launch row 0 blindly.
        if (!root.stripped) {
          root.close()
          return
        }
        var al = root.displayRows[root.safeListIndex]
        if (al && al.kind === "app") {
          root._opening = true
          root.launchApp(al)
          root.close()
        } else {
          root.runMode("web", root.stripped)
        }
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
  readonly property var requestModeMap: ({ g: "web", gpt: "gpt", p: "pinterest", i: "images", "as": "artstation", "sf": "sketchfab", y: "youtube", ddg: "ddg", da: "deviantart", r: "run", o: "menu" })

  // True when more than one dispatch-target flag is present ("-g -p cats").
  // Independent of chips/swallowed so the hint stays correct while typing.
  readonly property bool multiRequest: root.requestModes().length >= 2

  // Mode -> short display label for the multi-search hint.
  readonly property var requestLabelMap: ({
    web: "google", gpt: "chatgpt", pinterest: "pinterest", images: "images",
    artstation: "artstation", sketchfab: "sketchfab", youtube: "youtube",
    ddg: "ddg", deviantart: "deviantart", run: "run", menu: "omarchy"
  })

  function requestLabels() {
    var ms = root.requestModes()
    var out = []
    for (var i = 0; i < ms.length; i++) {
      var l = root.requestLabelMap[ms[i]]
      if (l && out.indexOf(l) < 0) out.push(l)
    }
    return out
  }

  // Mode -> URL builder for every browser-dispatch mode. Used by BOTH the
  // single-mode runMode and the multi-flag runRequests so a new "-x" flag or
  // URL scheme only has to be registered here (mirror QueryBar.placeholderFor).
  readonly property var urlBuilders: ({
    web: Search.googleUrl,
    gpt: Search.chatgptUrl,
    pinterest: Search.pinterestUrl,
    images: Search.imagesUrl,
    artstation: Search.artstationUrl,
    sketchfab: Search.sketchfabUrl,
    youtube: Search.youtubeUrl,
    ddg: Search.ddgUrl,
    deviantart: Search.deviantartUrl
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
  // When "-r" is among them the whole batch is gated: the first Enter only
  // arms it (flash, card stays open) and NOTHING dispatches until the second
  // Enter — a partial fire (web tabs opening first with the shell still
  // pending) would leave half the request already gone.
  function runRequests(modes, q) {
    if (modes.indexOf("run") >= 0 && store.confirmRun && root.runPendingCmd !== q) {
      root.runPendingCmd = q
      root.flashNote = "Run in shell? Press Enter again to confirm"
      flashTimer.restart()
      return
    }
    root.runPendingCmd = ""
    root._opening = true
    for (var i = 0; i < modes.length; i++) {
      if (root.urlBuilders[modes[i]]) {
        root.webLaunch(modes[i], q)
        continue
      }
      switch (modes[i]) {
      case "run":
        if (q) root.dispatchShell(q)
        break
      case "menu":
        Quickshell.execDetached(["omarchy-shell", "shell", "toggle", "omarchy.menu", JSON.stringify({ menu: "root" })])
        break
      }
    }
    if (root._runTracked) {
      // A silent run went out in the batch: the web tabs above already fired,
      // but the card stays open for the run feedback and closes only when the
      // command reports (onExited) instead of right here.
      root._opening = false
      return
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
    case "gpt":
    case "pinterest":
    case "images":
    case "artstation":
    case "sketchfab":
    case "youtube":
    case "ddg":
    case "deviantart": {
      if (!q) return
      root._opening = true
      root.webLaunch(mode, q)
      root.close()
      break
    }
    case "run": {
      if (!q) return
      // First Enter with the confirm gate armed only shows the flash and keeps
      // the card open; the identical second Enter (runShell below) executes.
      if (!root.runShell(q)) return
      if (root._runTracked) {
        // Silent + feedback: the card stays open for "Running…" and the
        // result; onExited reports it and (on success) closes the card.
        root._opening = false
        break
      }
      root._opening = true
      root.close()
      break
    }
    // Query-type flag (single-mode by design — NOT in requestModeMap, like -r
    // the user must pick the programs deliberately). The terminal gets the
    // query as ONE argv element through xdg-terminal-exec's `exec "$@"`, so no
    // shell quoting is needed: spaces/quotes/$() reach opencode verbatim.
    case "opencode": {
      if (!q) return
      root._opening = true
      Quickshell.execDetached(["omarchy", "launch", "terminal", "opencode", "--agent", "plan", "--prompt", q])
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
      if (root.helpOpen) root.helpOpen = false
      root.runPendingCmd = ""
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
  onHelpOpenChanged: {
    if (root.helpOpen) {
      if (root.settingsOpen) root.settingsOpen = false
      root.runPendingCmd = ""
      root.disarmPointer()
      Qt.callLater(function() { helpView.forceActiveFocus() })
    } else {
      queryField.forceActiveFocus()
    }
  }
  onQueryChanged: {
    if (!root.opened) return
    // Any typing leaves the settings/help views back to search.
    if (root.settingsOpen && root.query !== "") root.settingsOpen = false
    if (root.helpOpen && root.query !== "") root.helpOpen = false
    if (root.historyOpen && root.stripped !== "") root.historyOpen = false
    // A different query invalidates any armed shell command.
    if (root.runPendingCmd !== "") root.runPendingCmd = ""
    root.checkCat()
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

  Timer {
    id: flashTimer
    interval: 1600
    onTriggered: root.flashNote = ""
  }

  // Success splash for a silent -r run: show "Done!" briefly, then close.
  // Errors keep the card open (Esc) so the message can be read — flashTimer is
  // stopped there on purpose to NOT wipe the error text after 1.6 s.
  Timer {
    id: runCloseTimer
    interval: 1100
    onTriggered: root.close()
  }

  // Silent -r delivery (dispatchShell). Root is an Item, so the Process child
  // has a default `data` property to live in (Quickshell.Io). Output tails are
  // accumulated into root._runOut; onExited reports via the flashNote status
  // line. seq / root._runSeq keep a stale exit (user Esc'd, reopened or ran
  // another command meanwhile) from flashing onto or closing the current card.
  Process {
    id: silentRun
    property int seq: -1
    stdout: SplitParser {
      onRead: function(text) {
        root._runOut += String(text || "")
        if (root._runOut.length > 600) root._runOut = root._runOut.slice(-600)
      }
    }
    stderr: SplitParser {
      onRead: function(text) {
        root._runOut += String(text || "")
        if (root._runOut.length > 600) root._runOut = root._runOut.slice(-600)
      }
    }
    onExited: function(exitCode, exitStatus) {
      if (silentRun.seq !== root._runSeq) return
      root._runTracked = false
      // QProcess::ExitStatus: 0 = NormalExit, anything else = crash/killed.
      var ok = exitCode === 0 && exitStatus === 0
      root._resultGood = ok
      if (ok) {
        root.flashNote = "Done!"
        flashTimer.restart()
        runCloseTimer.restart()
      } else {
        root.flashNote = "Error: " + root.runErrorTail()
        flashTimer.stop()
      }
    }
  }

  Timer {
    id: catEeTimer
    interval: 1500
    onTriggered: root.catVisible = false
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

  // Resend queries. The list lives in HistoryStore (~/.local/state/obscure/
  // history.json, survives restarts); the cap is the "History" setting, so
  // changing it in the panel trims the list right away.
  HistoryStore {
    id: history
    limit: store.historyLimit
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
    // The resend list is a keyboard dropdown: while it is up the highlight
    // belongs to the arrows, and a click inserts that row directly. Hover
    // selection would fight the keyboard here — the card's own appear/grow
    // animation slides the rows under a stationary mouse, and each of those
    // synthetic samples lands in the gate as a "real" move, so the highlight
    // would end up wherever the cursor happens to be instead of on row 0.
    if (root.historyOpen) return
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
      // Fixed card width (clamped on narrow screens). The inner content box is
      // width - 2*cardPadX; the app grid divides THAT by gridCols, so any width
      // change moves the cell size with it.
      width: Math.min(Style.space(624), window.width - Style.gapsOut * 2)
      // Both dimensions derive from cardHeightAnim: the height animates and y
      // re-centers from the SAME animated value, so growing and moving happen
      // simultaneously (no chained behavior lag).
      height: root.cardHeightAnim
      radius: Style.cornerRadius
      anchors.horizontalCenter: parent.horizontalCenter
      y: Math.max(Style.gapsOut, Math.round((window.height - root.cardHeightAnim) / 2))
      color: root.cardColor
      // Children (grid/list/settings) lay out at their full target height but
      // must not paint while the card is still growing: clip reveals them as
      // the border spreads instead of drawing the content full-size first.
      clip: true
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
        // The card's inner gutter. cardPadX/cardPadY are the only place the
        // card padding is defined; everything below (header, list, grid,
        // settings, help) fills this box and inherits it.
        anchors.topMargin: root.cardPadY
        anchors.bottomMargin: root.cardPadY
        anchors.leftMargin: root.cardPadX
        anchors.rightMargin: root.cardPadX

        Keys.onPressed: function(event) {
          // Resend list first: it owns the arrows, Enter and Esc while it is
          // up (Esc must close the list, not the whole card), and Down on an
          // empty line opens it. This branch has to sit above `hasFlag` — with
          // a flag like -p the line is empty, rowsCount is 0 and listKeys
          // would swallow Down before we ever get here.
          if (root.historyOpen && (event.key === Qt.Key_Down || event.key === Qt.Key_Up
              || event.key === Qt.Key_Return || event.key === Qt.Key_Enter
              || event.key === Qt.Key_Escape)) {
            root.historyKeys(event)
            event.accepted = true
          } else if (root.historyEligible && event.key === Qt.Key_Down) {
            root.openHistory()
            event.accepted = true
          } else if (event.key === Qt.Key_Escape) {
            if (root.settingsOpen) root.exitSettings()
            else if (root.helpOpen) root.exitHelp()
            else root.close()
            event.accepted = true
          } else if ((event.modifiers & Qt.ControlModifier) && Flags.ctrlCommand(event.key, true) !== "") {
            root.onHotkey(Flags.ctrlCommand(event.key, true))
            event.accepted = true
          } else if (root.hasFlag) {
            if (root.inApps && !root.appsListMode) {
              root.gridKeys(event)
            } else {
              root.listKeys(event)
            }
            event.accepted = true
          } else if (root.searchMode || root.inFiles) {
            root.listKeys(event)
            event.accepted = true
          } else if (root.inApps) {
            // The apps screen as a list navigates exactly like the other
            // lists (first Down selects row 0, Enter launches) — no grid
            // "engage" level.
            if (root.appsListMode) root.listKeys(event)
            else root.gridKeys(event)
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
          Behavior on spacing { NumberAnimation { duration: root.animMs(180); easing.type: Easing.InOutQuad } }

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
            Behavior on Layout.preferredWidth { NumberAnimation { duration: root.animMs(180); easing.type: Easing.InOutQuad } }
            Behavior on opacity { NumberAnimation { duration: root.animMs(140); easing.type: Easing.OutQuad } }

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
              multiRequest: root.multiRequest
              leftPadding: root.filterActive
                ? queryField.defaultLeftPadding + chipRow.width + Style.spacing.xs + Style.spacing.sm
                : queryField.defaultLeftPadding
              suggestion: root.suggestionText
              onTextEdited: root.applyFieldText(queryField.text)
              onActivate: {
                // Enter lands HERE, not in the keyCatcher: a focused text
                // field consumes Return/Enter and never lets them bubble. With
                // the resend list up it must insert the highlighted entry —
                // activating instead would run the empty query behind it (with
                // a standing prefill: a browser tab).
                if (root.historyOpen) root.insertHistory(root.safeListIndex)
                else root.activate()
              }
              onTabComplete: root.completeSuggestion()
              onCycleMode: function(dir) { root.cycleMode(dir) }
              onNavigateGrid: function(dir) { root.gridStep(dir) }
              onHotkey: function(cmd) { root.onHotkey(cmd) }
              onPopFilter: root.popFilter()
             onPopRawToken: root.popRawToken()
              onEscapeKey: {
                // Same reason as onActivate: Esc is consumed by the focused
                // field, so the resend list has to close itself here or the
                // first Esc tears the whole card down.
                if (root.historyOpen) root.closeHistory()
                else if (root.settingsOpen) root.exitSettings()
                else root.close()
              }
            }

            // "CTRL+H for help..." rides the right edge of the field. A
            // TextField placeholder can only be one left-aligned string, and
            // the flag list that used to sit there was long enough to crowd
            // out the query line — the help page documents the flags anyway.
            // Sibling (not a child) of the field, so its own padding/background
            // logic stays untouched; rightMargin mirrors the field's padding.
            Text {
              id: queryHelpHint
              anchors.right: queryField.right
              anchors.rightMargin: queryField.rightPadding
              anchors.verticalCenter: queryField.verticalCenter
              // Only while the line is empty: otherwise it would sit under the
              // typed text (and under the inline autocomplete suffix).
              visible: queryField.text === ""
              z: queryField.z + 1
              text: "CTRL+H for help..."
              font.family: queryField.font.family
              font.pixelSize: queryField.font.pixelSize
              // "A touch lighter than the field fill": the fill is a faint
              // translucent light, so a low-alpha foreground lands just above
              // it — dimmer than the kit's placeholder (Qt.darker(foreground,
              // 1.6)), which keeps the eye on the query line. 0.24 is the knob.
              color: Util.alpha(queryField.foreground, 0.24)
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
            // discards and closes. While the editor fields are focused, keys
            // go to them instead (blocked).
            PanelKeyCatcher {
              id: settingsKeys
              anchors.fill: parent
              focus: true
              blocked: historyField.activeFocus || defaultFlagsField.activeFocus
              onMoveRequested: function(dx, dy) {
                if (dx !== 0) root.settingsHorizontal(dx)
                else root.settingsMove(dy)
              }
              onTabRequested: function(dir) { root.settingsTab(dir) }
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

                SegmentedToggle {
                  id: appsViewToggle
                  width: parent.width
                  label: "Apps view"
                  options: [
                    { value: "grid", label: "Grid" },
                    { value: "list", label: "List" }
                  ]
                  value: root.draftAppsView
                  hasCursor: root.settingsIndex === 2
                  onHovered: function(h) { if (h) root.settingsIndex = 2 }
                  onChanged: function(value) { root.draftAppsView = value }
                }

                Toggle {
                  id: showFilesToggle
                  width: parent.width
                  label: "Files island"
                  description: "Show the FILES search button"
                  checked: root.draftShowFiles
                  hasCursor: root.settingsIndex === 3
                  onHovered: function(h) { if (h) root.settingsIndex = 3 }
                  onClicked: root.draftShowFiles = !root.draftShowFiles
                }

                PanelSeparator {
                  width: parent.width
                }

                SegmentedToggle {
                  id: defaultModeToggle
                  width: parent.width
                  label: "Default search mode"
                  options: [
                    { value: "auto", label: "Auto" },
                    { value: "apps", label: "Apps" },
                    { value: "files", label: "Files" }
                  ]
                  value: root.draftDefaultMode
                  hasCursor: root.settingsIndex === 4
                  onHovered: function(h) { if (h) root.settingsIndex = 4 }
                  onChanged: function(value) { root.draftDefaultMode = value }
                }

                Toggle {
                  id: showHiddenToggle
                  width: parent.width
                  label: "Show hidden by default"
                  description: "Include dotfiles in file and directory searches"
                  checked: root.draftShowHidden
                  hasCursor: root.settingsIndex === 5
                  onHovered: function(h) { if (h) root.settingsIndex = 5 }
                  onClicked: root.draftShowHidden = !root.draftShowHidden
                }

                Toggle {
                  id: animationsToggle
                  width: parent.width
                  label: "Animations"
                  description: "Smooth panel resize, island collapse, fades and color shifts; off = instant response"
                  checked: root.draftAnimations
                  hasCursor: root.settingsIndex === 6
                  onHovered: function(h) { if (h) root.settingsIndex = 6 }
                  onClicked: root.draftAnimations = !root.draftAnimations
                }

                SegmentedToggle {
                  id: runModeToggle
                  width: parent.width
                  label: "Run -r in"
                  options: [
                    { value: "silent", label: "Silent" },
                    { value: "external", label: "External terminal" }
                  ]
                  value: root.draftRunTarget
                  hasCursor: root.settingsIndex === 7
                  onHovered: function(h) { if (h) root.settingsIndex = 7 }
                  onChanged: function(value) { root.draftRunTarget = value }
                }

                Toggle {
                  id: confirmRunToggle
                  width: parent.width
                  label: "Shell command warning"
                  description: "Press Enter twice to run -r / Ctrl+0 commands instead of running them instantly"
                  checked: root.draftConfirmRun
                  hasCursor: root.settingsIndex === 8
                  onHovered: function(h) { if (h) root.settingsIndex = 8 }
                  onClicked: root.draftConfirmRun = !root.draftConfirmRun
                }

                Toggle {
                  id: showBarIconToggle
                  width: parent.width
                  label: "Bar icon"
                  description: "Show the magnifier button in the top bar (hotkeys keep working)"
                  checked: root.draftBarIcon
                  hasCursor: root.settingsIndex === 9
                  onHovered: function(h) { if (h) root.settingsIndex = 9 }
                  onClicked: root.draftBarIcon = !root.draftBarIcon
                }

                // Resend-query cap. A labelled number box, NOT another
                // full-width field: the value is 0..200, so six digits is
                // plenty and the row reads like a label + control pair
                // instead of stretching the input across the whole panel.
                Row {
                  width: parent.width
                  spacing: Style.spacing.rowPaddingX

                  Text {
                    id: historyLabel
                    // Row titles elsewhere in this panel (Ui/Toggle) are
                    // bold + subtitle + foreground; match them exactly.
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: "Query history"
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.subtitle
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  TextField {
                    id: historyField
                    // Everything the label leaves, so the box runs to the
                    // panel's right edge. NOT a TextMetrics probe: that copies
                    // the kit font before it resolves and measured 0 here,
                    // which collapsed the field to a sliver.
                    width: Math.max(0, parent.width - historyLabel.implicitWidth - parent.spacing)
                    placeholderText: "10"
                    hasCursor: root.settingsIndex === 10
                    onHoveredChanged: if (historyField.hovered) root.settingsIndex = 10
                    onTextChanged: {
                      var digits = text.replace(/[^0-9]/g, "")
                      if (digits !== text) {
                        text = digits
                        cursorPosition = digits.length
                      }
                      if (root.draftHistory !== text) root.draftHistory = text
                    }
                    Connections {
                      target: root
                      function onDraftHistoryChanged() {
                        if (historyField.text !== root.draftHistory && !historyField.activeFocus)
                          historyField.text = root.draftHistory
                      }
                    }
                    // The field owns the keys while focused (settingsKeys is
                    // blocked): Up/Down leave the editor and keep walking the
                    // settings cursor, Enter jumps straight to Apply, Esc just
                    // drops back out — the same contract as the flags editor.
                    Keys.onDownPressed: function(event) {
                      event.accepted = true
                      settingsKeys.forceActiveFocus()
                      root.settingsMove(1)
                    }
                    Keys.onUpPressed: function(event) {
                      event.accepted = true
                      settingsKeys.forceActiveFocus()
                      root.settingsMove(-1)
                    }
                    Keys.onReturnPressed: function(event) {
                      event.accepted = true
                      settingsKeys.forceActiveFocus()
                      root.settingsIndex = 12
                    }
                    Keys.onEnterPressed: function(event) {
                      event.accepted = true
                      settingsKeys.forceActiveFocus()
                      root.settingsIndex = 12
                    }
                    Keys.onEscapePressed: function(event) {
                      event.accepted = true
                      settingsKeys.forceActiveFocus()
                    }
                  }
                }

                TextField {
                  id: defaultFlagsField
                  width: parent.width
                  placeholderText: "Flags prefilled on open  e.g. -g -. -p"
                  hasCursor: root.settingsIndex === 11
                  onHoveredChanged: if (defaultFlagsField.hovered) root.settingsIndex = 11
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
                  // The field owns the keys while focused (settingsKeys is
                  // blocked); a single-line editor has no use for Up/Down so
                  // they leave the editor and keep walking the settings
                  // cursor. Enter commits the flags by jumping straight to
                  // Apply; Esc just drops back out to the field's row.
                  Keys.onDownPressed: function(event) {
                    event.accepted = true
                    settingsKeys.forceActiveFocus()
                    root.settingsMove(1)
                  }
                  Keys.onUpPressed: function(event) {
                    event.accepted = true
                    settingsKeys.forceActiveFocus()
                    root.settingsMove(-1)
                  }
                  Keys.onReturnPressed: function(event) {
                    event.accepted = true
                    settingsKeys.forceActiveFocus()
                    root.settingsIndex = 12
                  }
                  Keys.onEnterPressed: function(event) {
                    event.accepted = true
                    settingsKeys.forceActiveFocus()
                    root.settingsIndex = 12
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
                    hasCursor: root.settingsIndex === 12
                    onHovered: function(h) { if (h) root.settingsIndex = 12 }
                    onClicked: root.settingsApply()

                    // Apply is permanently emphasized via `selected`, whose
                    // fill is STRONGER than the kit's hover-cursor fill — so
                    // the cursor landing on it used to look like the highlight
                    // vanished ("falls into empty space") and Close then made
                    // both buttons read as lit. Give the cursor an explicit
                    // accent ring so the walk target is always unambiguous.
                    Rectangle {
                      anchors.fill: parent
                      visible: applyButton.hasCursor
                      color: "transparent"
                      border.color: Color.accent
                      border.width: Math.max(1, Style.space(2))
                      radius: Math.max(0, Style.cornerRadius - 1)
                      Behavior on opacity { NumberAnimation { duration: root.animMs(120) } }
                    }
                  }
                  Button {
                    id: closeButton
                    text: "Close"
                    hasCursor: root.settingsIndex === 13
                    onHovered: function(h) { if (h) root.settingsIndex = 13 }
                    onClicked: root.exitSettings()
                  }
                }
              }
            }
          }

          Item {
            id: helpView
            visible: root.helpOpen
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: root.helpPanelHeight
            focus: true

            // Read-only help panel. Esc/Enter leave it (the card stays open);
            // Up/Down/j/k scroll the capped list; ANY text key dismisses help
            // and returns to the search line. It never dispatches the query
            // underneath, so the query (even a pending -r) stays a draft.
            //
            // The keys are owned HERE instead of a qs.Ui PanelKeyCatcher, and
            // that is deliberate: the catcher classifies Ctrl+letter as a plain
            // text key (its length-1 text branch sets no event.accepted), so
            // Ctrl+H dismissed help and then bubbled on to keyCatcher — which
            // read the very same press as a hotkey and toggled help straight
            // back open. Ctrl is therefore tested FIRST below, and every key
            // is accepted, so nothing here can leak into the search keys. The
            // panel is read-only, so the catcher's `blocked`/TextField
            // machinery bought nothing anyway.
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) {
              if (event.modifiers & Qt.ControlModifier) {
                var cmd = Flags.ctrlCommand(event.key, true)
                if (cmd !== "") {
                  // Ctrl+H is the same "toggle" it was on the search line, so
                  // it just leaves; every other hotkey leaves too and then
                  // applies (Ctrl+2 from help still switches to APPS).
                  root.exitHelp()
                  if (cmd !== "help") root.onHotkey(cmd)
                }
                event.accepted = true
                return
              }
              if (event.key === Qt.Key_Escape || event.key === Qt.Key_Return
                  || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                root.exitHelp()
              } else if (event.key === Qt.Key_Down || event.text === "j") {
                root.helpMove(1)
              } else if (event.key === Qt.Key_Up || event.text === "k") {
                root.helpMove(-1)
              } else if (event.text && event.text.length === 1) {
                root.exitHelp()
              }
              event.accepted = true
            }

            Column {
              id: helpControlCol
              anchors.fill: parent
              spacing: Style.spacing.xs

              PanelSectionHeader {
                width: parent.width
                text: "Help"
              }

              Item {
                id: helpListHost
                width: parent.width
                height: root.helpVisibleRows * root.helpRowH
                clip: true

                ListView {
                  id: helpList
                  anchors.fill: parent
                  clip: true
                  boundsBehavior: Flickable.StopAtBounds
                  model: root.helpRows
                  currentIndex: 0
                  delegate: helpDelegate
                }

                Rectangle {
                  id: helpScrollbar
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(2)
                  width: Style.spacing.hairline
                  radius: width
                  color: Util.alpha(root.dimColor, 0.55)
                  visible: helpList.contentHeight > helpList.height + 1
                  height: Math.max(Style.space(24),
                    parent.height * Math.min(1, helpList.height / helpList.contentHeight))
                  y: (parent.height - height) * Math.max(0, Math.min(1,
                    helpList.contentHeight > helpList.height
                      ? helpList.contentY / (helpList.contentHeight - helpList.height)
                      : 0))
                }
              }

              Text {
                width: parent.width
                height: Style.space(26)
                text: "Esc or Ctrl+H closes  -  arrows move  -  typing returns to the search"
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.caption
                color: Util.alpha(root.dimColor, 0.8)
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
              }
            }
          }

          Item {
            id: catView
            visible: root.catVisible
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: root.catPanelHeight

            Rectangle {
              anchors.fill: parent
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              radius: Style.cornerRadius
              color: Util.alpha(Color.menu.background, 0.55)
              border.color: Util.alpha(Color.accent, 0.35)
              border.width: Math.max(1, Style.spacing.hairline)

              Text {
                anchors.centerIn: parent
                text: root.catArt
                font.family: "monospace"
                font.pixelSize: Style.font.body
                color: root.fgColor
                horizontalAlignment: Text.AlignHCenter
              }
            }
          }

          Text {
            visible: (root.showHint || root.flashActive) && !root.settingsOpen && !root.helpOpen && !root.catVisible
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: Style.space(48)
            text: root.flashActive ? root.flashNote : root.hintText
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.title
            // A silent -r result is coloured: Done = accent, Error = urgent.
            color: root._resultGood === null ? root.dimColor
              : root._resultGood ? Color.accent : Color.urgent
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideMiddle
          }

          GridView {
            id: appGrid
            visible: root.gridMode && !root.showHint && !root.settingsOpen && !root.helpOpen && !root.catVisible
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
              NumberAnimation { properties: "opacity,scale"; from: 0; to: 1; duration: root.animMs(150); easing.type: Easing.OutQuad }
            }
            remove: Transition {
              NumberAnimation { property: "opacity"; to: 0; duration: root.animMs(120) }
            }
            displaced: Transition {
              NumberAnimation { properties: "x,y"; duration: root.animMs(160); easing.type: Easing.OutQuad }
            }
            populate: Transition {
              NumberAnimation { properties: "opacity,scale"; from: 0; to: 1; duration: root.animMs(220); easing.type: Easing.OutQuad }
            }
          }

          Item {
            id: listColumn
            visible: (!root.gridMode && !root.showHint && !root.settingsOpen && !root.helpOpen && !root.catVisible)
              || root.historyOpen
            anchors.top: parent.top
            // The hint line and this column both anchor to the top, so when
            // both are up (resend list) the column moves below the hint.
            anchors.topMargin: root.historyOpen && (root.showHint || root.flashActive) ? Style.space(48) : 0
            anchors.left: parent.left
            anchors.right: parent.right
            height: root.listHeight

            ListView {
              id: resultList
              width: parent.width
              height: root.listHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              spacing: root.rowSpacing
              model: resultsModel
              delegate: rowDelegate
            }

            // Thin scroll indicator on the right edge: shows the visible slice
            // of the result list and follows wheel, drag and keyboard scroll.
            // Pure QML, no QtQuick.Controls import. y/height are plain bindings
            // on the list's content metrics (auto-tracks on every scroll tick).
            Rectangle {
              id: listScrollbar
              anchors.right: parent.right
              anchors.rightMargin: Style.space(2)
              width: Style.spacing.hairline
              radius: width
              color: Util.alpha(root.dimColor, 0.55)
              visible: resultList.contentHeight > resultList.height + 1
              height: Math.max(Style.space(24),
                parent.height * Math.min(1, resultList.height / resultList.contentHeight))
              y: (parent.height - height) * Math.max(0, Math.min(1,
                resultList.contentHeight > resultList.height
                  ? resultList.contentY / (resultList.contentHeight - resultList.height)
                  : 0))
              Behavior on color { ColorAnimation { duration: root.animMs(120) } }
              Behavior on height { NumberAnimation { duration: root.animMs(120) } }
              Behavior on y { NumberAnimation { duration: root.animMs(120) } }
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

  function revealListSelection() {
    if (resultList === undefined) return
    if (root.rowsCount === 0) return
    resultList.positionViewAtIndex(root.safeListIndex, ListView.Contain)
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

  // ---- resend query (history dropdown) ----
  function openHistory() {
    if (!root.historyEligible) return
    root.historyOpen = true
    root.selectedIndex = 0
    // The list popping up (and the reveal scroll under it) fires a hover
    // sample whose mapToItem delta looks like a real pointer move, which drags
    // the highlight onto whatever row happens to sit under the mouse. Re-arm
    // the gate once the reveal settled, the same way listKeys disarms it on
    // every key: the keyboard highlight stays on row 0.
    Qt.callLater(function() {
      root.revealListSelection()
      Qt.callLater(root.disarmPointer)
    })
  }

  function closeHistory() {
    if (!root.historyOpen) return
    root.historyOpen = false
  }

  function historyKeys(event) {
    root.disarmPointer()
    var n = root.historyRows.length
    if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
      if (n === 0) return
      root.selectedIndex = (root.safeListIndex + (event.key === Qt.Key_Down ? 1 : -1) + n) % n
      Qt.callLater(root.revealListSelection)
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.insertHistory(root.safeListIndex)
    } else if (event.key === Qt.Key_Escape) {
      root.closeHistory()
    }
  }

  // Put the picked query back into the line and let the user run it. Flags
  // already standing (a defaultFlags prefill, chips) are kept — they chose the
  // mode, the history only supplies the text — so a bare "-p" (no trailing
  // space yet) gets one before the text lands.
  function insertHistory(index) {
    var entry = root.historyRows[index]
    if (!entry) return
    var p = Flags.prefix(root.query, root.parsed)
    if (p !== "" && !/\s$/.test(p)) p += " "
    root.historyOpen = false
    root.query = p + entry.label
    Qt.callLater(function() {
      queryField.forceActiveFocus()
      queryField.cursorPosition = queryField.text.length
    })
  }

  // Record a submitted query. Shell commands stay out of the list on purpose:
  // a `-r` line replayed from the dropdown would re-arm a shell run from
  // something that only looks like a search.
  function addHistory(text) {
    if (!history.enabled) return
    if (root.parsedMode === "run") return
    history.add(text)
  }

  // Scroll the (capped) help list: move the highlight and keep it in view.
  function helpMove(dir) {
    root.disarmPointer()
    var n = root.helpRows.length
    if (n === 0) return
    var next = Math.max(0, Math.min(helpList.currentIndex + dir, n - 1))
    helpList.currentIndex = next
    helpList.positionViewAtIndex(next, ListView.Contain)
  }

  // ---- help page row ----
  Component {
    id: helpDelegate

    Item {
      required property var modelData
      width: helpList.width
      height: modelData.kind === "banner" ? Style.space(66)
        : modelData.kind === "header" ? Style.space(30)
        : root.helpRowH

      // Banner: plugin title on top, tagline below (help_exmpl.md layout).
      // Generous bottom margin keeps a blank line between the tagline and the
      // first section header so the page does not read as a stuck blob.
      Column {
        anchors.fill: parent
        anchors.leftMargin: Style.space(7)
        anchors.rightMargin: Style.space(7)
        anchors.topMargin: Style.space(8)
        anchors.bottomMargin: Style.space(20)
        visible: modelData.kind === "banner"
        spacing: Style.space(1)

        Text {
          width: parent.width
          text: modelData.label
          font.family: Style.font.family
          font.pixelSize: Style.font.display
          font.bold: true
          color: Color.accent
        }

        Text {
          width: parent.width
          text: modelData.detail
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
          color: Util.alpha(root.dimColor, 0.85)
          elide: Text.ElideRight
        }
      }

      // Section header: HotKeys / Flags.
      Text {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(7)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(7)
        anchors.verticalCenter: parent.verticalCenter
        visible: modelData.kind === "header"
        font.family: Style.font.family
        font.pixelSize: Style.font.subtitle
        font.bold: true
        color: Color.accent
        text: modelData.label
        verticalAlignment: Text.AlignVCenter
      }

      // Row: "[label] - what it does", left-aligned.
      RowLayout {
        visible: modelData.kind === "row"
        anchors.left: parent.left
        anchors.leftMargin: Style.space(7)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(7)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xs

        Text {
          text: "[" + modelData.label + "]"
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.title
          color: root.fgColor
        }

        Text {
          text: "-"
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
          color: Util.alpha(root.dimColor, 0.5)
        }

        Text {
          Layout.fillWidth: true
          text: modelData.detail
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
          color: Util.alpha(root.dimColor, 0.85)
          elide: Text.ElideRight
          verticalAlignment: Text.AlignVCenter
        }
      }
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
            Behavior on color { ColorAnimation { duration: root.animMs(120) } }
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
      property bool isHistory: rowItem.kind === "history"
      // Folder / file / clock — the resend rows are the only ones that carry
      // their text in `label` without being an app.
      property string iconGlyph: rowItem.isDir ? "\uf07b" : (rowItem.isHistory ? "\uf017" : "\uf15b")

      height: root.rowHeight
      width: ListView.view.width

      Rectangle {
        anchors.fill: parent
        radius: Math.max(2, Style.cornerRadius)
        color: rowItem.isSelected ? Color.menu.selectedBackground : "transparent"
        Behavior on color { ColorAnimation { duration: root.animMs(120) } }
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
        text: (rowItem.isApp || rowItem.isHistory) ? rowItem.label : rowItem.path
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
          // A resend row fills the line instead of running straight away.
          if (rowItem.isHistory) root.insertHistory(index)
          else root.activate()
        }
      }
    }
  }
}