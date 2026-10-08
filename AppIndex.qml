import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Self-contained desktop-entry indexer. Mirrors the host AppLibrary facade so
// the spotlight's app grid works even when the shell does not hand a
// third-party menu plugin an appLibrary object. Parses the standard XDG
// application dirs, mirrors AppLibrary's filter/launch semantics.
// Root is an invisible Item (not QtObject): Process/SplitParser children need
// a default `data` property.
Item {
  id: root

  visible: false

  signal loaded()

property var apps: ([])
  property bool busy: false
  property var _seen: ({})
  property var _pending: ([])
  property double lastScan: 0

  function load() {
    // First run: nothing to show until the scan lands, so blank it up front.
    root.apps = []
    root._scan()
  }

  // Re-scan requested by the UI (panel open). A .desktop installed AFTER the
  // shell started is otherwise invisible forever: this index only ran at
  // startup and Spotlight.ensureApps() early-returns once the grid has
  // entries. Unlike load() the CURRENT list stays on screen — results collect
  // in _pending and only swap in onExited — so a refresh never blanks the
  // grid. Rate-limited, and busy-guarded so a burst of opens cannot stack
  // scans (a second run on the same Process would be dropped).
  function refresh() {
    if (root.busy) return
    if (Date.now() - root.lastScan < 5000) return
    root._scan()
  }

  function _scan() {
    if (root.busy) return
    root.busy = true
    root._seen = ({})
    root._pending = []
    proc.canceled = false
    proc.command = ["bash", "-c", root.cmd]
    proc.running = true
  }

// Matches AppLibrary.launch: keep the .desktop suffix so ids like
  // org.telegram.desktop resolve, under a graphical scope.
  function launch(appId) {
    Quickshell.execDetached(["uwsm-app", "--", "gtk-launch", String(appId) + ".desktop"])
  }

  readonly property string cmd:
// Application dirs, user overrides FIRST: the parser dedups by id on first
    // sight, so a user's own entry must win over the system one. The user
    // flatpak export dir is the one that is easy to forget — a flatpak app is
    // invisible here (but fine in the stock panel) if it is not listed.
    "dirs=\"$HOME/.local/share/applications $HOME/.local/share/flatpak/exports/share/applications /usr/share/applications /var/lib/flatpak/exports/share/applications\";\n" +
    "for d in $dirs; do [ -d \"$d\" ] || continue; find \"$d\" -maxdepth 1 -name '*.desktop' 2>/dev/null; done |\n" +
    "while read -r f; do\n" +
    "  id=\"$(basename \"$f\" .desktop)\"\n" +
    "  awk -F= -v file=\"$f\" -v id=\"$id\" '\n" +
    "    /^\\[Desktop Entry\\]$/ { sec=1; next }\n" +
    "    /^\\[/ { sec=0; next }\n" +
    "    sec != 1 { next }\n" +
    "    /^Type=/ { type=$2 }\n" +
    "    /^NoDisplay=/ { nod=$2 }\n" +
    "    /^Hidden=/ { hid=$2 }\n" +
    "    /^OnlyShowIn=/ { osi=$2 }\n" +
    "    /^NotShowIn=/ { nsi=$2 }\n" +
    "    /^Name=/ { name=$2 }\n" +
    "    /^Icon=/ { icon=$2 }\n" +
    "    END {\n" +
    "      if (type != \"Application\") exit\n" +
    "      if (nod == \"true\" || hid == \"true\") exit\n" +
    "      hide=0\n" +
    "      n=split(osi,a,\";\"); for (i=1;i<=n;i++) if (a[i]==\"KDE\") hide=1\n" +
    "      n=split(nsi,a,\";\"); for (i=1;i<=n;i++) if (a[i]==\"GNOME\"||a[i]==\"XFCE\") hide=1\n" +
    "      if (hide) exit\n" +
    "      if (name==\"\") name=id\n" +
    "      printf \"APP\\t%s\\t%s\\t%s\\n\", id, name, icon\n" +
    "    }' \"$f\"\n" +
    "done"

  Process {
    id: proc
    property bool canceled: false
    stdout: SplitParser {
      onRead: function(line) {
        // Line format: APP<tab>id<tab>name<tab>icon
        var parts = String(line).split("\t")
        if (parts.length < 4) return
        var id = parts[1]
        if (!id) return
        if (root._seen[id]) return
        root._seen[id] = true
        root._pending.push({
          appId: id,
          label: parts[2] || id,
          icon: parts[3] || ""
        })
      }
    }
    onExited: function(exitCode, exitStatus) {
      root.busy = false
      if (proc.canceled) return
      // Swap the whole list in at once: apps becomes a fresh array object on
      // every scan, so the property change notifies and nothing flickers
      // midway through a refresh.
      root.apps = root._pending
      root.lastScan = Date.now()
      root.loaded()
    }
  }
}