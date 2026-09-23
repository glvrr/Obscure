import QtQuick
import qs.Commons
import qs.Ui

// Bar launcher for the spotlight. A magnifier button toggles the overlay so
// the spotlight can be opened without a hotkey.
BarWidget {
  id: root
  moduleName: "glvr.ninja.spotlight"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf002"
    fontFamily: Style.font.menuFamily
    horizontalMargin: 7.5
    onPressed: function(button) {
      if (!root.bar) return
      root.bar.run("omarchy-shell shell toggle glvr.ninja.spotlight '{}'")
    }
  }
}