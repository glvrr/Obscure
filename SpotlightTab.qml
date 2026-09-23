import QtQuick
import qs.Commons
import qs.Ui

// Icon-only pill button for the APPS / FILES tabs. The label text slides
// out to the right when the tab is active (an explicit mode is selected).
Item {
  id: root

  property string icon: ""
  property string text: ""
  property bool active: false
  signal clicked()

  readonly property bool hot: mouseArea.containsMouse
  readonly property int iconSection: Style.spacing.controlHeight

  width: root.iconSection + (root.active ? Style.space(8) + labelText.implicitWidth : 0)
  height: root.iconSection
  Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

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
    font.pixelSize: Style.font.iconLarge
    color: root.active ? Color.accent : (root.hot ? Color.foreground : Color.menu.text)
  }

  // Sliding label: clipped and widened only while the tab is active.
  Item {
    id: labelBox
    x: root.iconSection + Style.space(4)
    width: root.active ? labelText.implicitWidth : 0
    height: parent.height
    clip: true
    Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

    Text {
      id: labelText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: root.text
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: root.active
      color: root.active ? Color.accent : Color.foreground
    }
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    onClicked: root.clicked()
  }
}