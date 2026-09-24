import QtQuick
import qs.Commons
import qs.Ui

// Icon-only button that hands off to the stock Omarchy menu.
Item {
  id: root

  property bool active: false
  signal clicked()

  readonly property bool hot: mouseArea.containsMouse

  width: Style.space(34)
  height: Style.space(34)

  Rectangle {
    id: pill
    anchors.fill: parent
    radius: Math.max(2, Style.cornerRadius)
    color: root.active ? Color.menu.selectedBackground : (root.hot ? Style.hoverFill : Style.normalFill)
    border.width: Math.max(1, Style.space(1))
    border.color: root.active ? Color.menu.border : (root.hot ? Style.hoverBorderColor : Style.normalBorderColor)

    Text {
      anchors.centerIn: parent
      text: "\ue900"
      font.family: "omarchy"
      font.pixelSize: Style.font.heading + 4
      color: root.active ? Color.accent : (root.hot ? Color.foreground : Color.menu.text)
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