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
  // itself. It is loaded blocking, which is what makes `visible` correct on
  // the first frame (an async read would flash the icon and pull it a beat
  // later), and watchChanges inside the store picks up Apply instantly.
  SettingsStore {
    id: barStore
  }

  // ...but a QFileSystemWatcher cannot arm on a path that does not exist yet,
  // and on a fresh install obscure.json only appears on the first Apply. A
  // slow blocking re-read of a 200-byte file keeps the icon honest forever
  // (no process, no other polling).
  Timer {
    interval: 4000
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
