import QtQuick
import qs.Commons
import qs.Ui

// Icon-only button that hands off to the stock Omarchy menu.
Item {
  id: root

  signal clicked()

  readonly property bool hot: mouseArea.containsMouse

  width: Style.spacing.controlHeight
  height: Style.spacing.controlHeight

  Rectangle {
    id: pill
    anchors.fill: parent
    radius: Math.max(2, height / 2)
    color: root.hot ? Style.hoverFill : "transparent"
    border.width: root.hot ? Math.max(1, Style.space(1)) : 0
    border.color: Color.menu.border

    Text {
      anchors.centerIn: parent
      text: "\ue900"
      font.family: "omarchy"
      font.pixelSize: Style.font.icon
      color: Color.foreground
      verticalAlignment: Text.AlignVCenter
    }
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    onClicked: root.clicked()
  }
}