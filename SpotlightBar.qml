import QtQuick
import qs.Commons
import qs.Ui

// Bar launcher for the spotlight. A magnifier button toggles the overlay so
// the spotlight can be opened without a hotkey; right-click opens it already
// in the settings view. The whole widget hides itself when the user turns the
// bar icon off in the settings panel — the host zeroes a slot whose widget is
// invisible, so no gap is left in the bar.
BarWidget {
  id: root
  moduleName: "glvr.ninja.obscure"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  visible: barStore.showBarIcon

  // Own store instance: the panel's copy lives in another component tree and
  // child ids are not reachable across trees, so the bar reads the same JSON
  // itself. The blocking read is what makes `visible` correct on the first
  // frame — an async read would paint the icon and pull it a beat later.
  SettingsStore {
    id: barStore
  }

  // ...and it has to notice Apply while the panel is open. FileView's
  // watchChanges is dead on this host (QFileSystemWatcher never fires), so
  // poll instead: load() asks for a re-read, the fresh text lands on the
  // following tick, and a 180-byte file costs nothing once a second. The
  // first paint is unaffected either way — the blocking load above already
  // resolved `visible` before this timer ever fires.
  Timer {
    interval: 1000
    repeat: true
    running: true
    onTriggered: barStore.load()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf002"
    fontFamily: Style.font.menuFamily
    horizontalMargin: 7.5
    onPressed: function(mouseButton) {
      if (!root.bar) return
      var settings = mouseButton === Qt.RightButton ? '{"settings":true}' : "{}"
      root.bar.run("omarchy-shell shell toggle glvr.ninja.obscure '" + settings + "'")
    }
  }
}
