import QtQuick
import qs.Commons
import qs.Ui

// Icon-only pill button for the APPS / FILES tabs (no sliding label).
Item {
  id: root

  property string icon: ""
  property string text: ""
  property bool active: false
  signal clicked()

  readonly property bool hot: mouseArea.containsMouse
  readonly property int iconSection: Style.space(34)

  width: root.iconSection
  height: root.iconSection

  Rectangle {
    id: pill
    anchors.fill: parent
    radius: Math.max(2, Style.cornerRadius)
    color: root.active ? Color.menu.selectedBackground : (root.hot ? Style.hoverFill : Style.normalFill)
    border.width: Math.max(1, Style.space(1))
    border.color: root.active ? Color.menu.border : (root.hot ? Style.hoverBorderColor : Style.normalBorderColor)
  }

  Text {
    id: glyph
    anchors.verticalCenter: parent.verticalCenter
    x: Math.round((root.iconSection - width) / 2)
    text: root.icon
    font.family: Style.font.menuFamily
    font.pixelSize: Style.font.heading + 4
    color: root.active ? Color.accent : (root.hot ? Color.foreground : Color.menu.text)
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    onClicked: root.clicked()
  }
}