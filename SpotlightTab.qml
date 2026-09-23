import QtQuick
import qs.Commons
import qs.Ui

// Small pill button used for the APPS / FILES tabs.
Item {
  id: root

  property string text: ""
  property bool active: false
  signal clicked()

  readonly property bool hot: mouseArea.containsMouse

  width: label.implicitWidth + Style.space(26)
  height: Style.spacing.controlHeight

  Rectangle {
    id: pill
    anchors.fill: parent
    radius: Math.max(2, height / 2)
    color: root.active ? Color.menu.selectedBackground : (root.hot ? Style.hoverFill : "transparent")
    border.width: root.active ? Math.max(1, Style.space(1)) : 0
    border.color: Color.menu.border

    Text {
      id: label
      anchors.centerIn: parent
      text: root.text
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: root.active
      color: root.active ? Color.accent : Color.foreground
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