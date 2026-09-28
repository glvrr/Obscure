import QtQuick
import qs.Commons
import qs.Ui

// Labeled segmented row: title (+ optional description) on the left, a
// ButtonGroup chip row (param1|param2|param3) on the right — the form-style
// "pick one of N" replacement for a Dropdown in the settings panel. The chip
// row is focusable:false on purpose: keyboard focus stays on the settings
// PanelKeyCatcher, and this control keeps whatever the caller feeds into
// `value`; the settings keyboard steps the draft with Left/Right/Enter and
// the chips just mirror it (same contract as the Dropdown's keyboard path).
//
// No cursorIndex on the group: chips already light themselves through their
// internal hover MouseArea, and a keyboard-driven cursorIndex chasing the
// selected chip made the row "blink" while stepping — the hover fill overrode
// the selected fill and jumped between chips on every keystroke. The selected
// chip carries the selected fill, the row carries the panel cursor chrome.
BorderSurface {
  id: root

  property string label: ""
  property string description: ""
  property var options: []
  property string value: ""
  // Panel-cursor flag, same role as Toggle.hasCursor: the settings keyboard
  // binds this to settingsIndex and the row gets the hover-cursor chrome.
  property bool hasCursor: false

  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property real titleSize: Style.font.subtitle
  property real descriptionSize: Style.font.caption

  signal changed(string value)
  signal hovered(bool isHovered)

  property bool _hovered: false

  implicitHeight: Math.max(54, content.implicitHeight + Style.spacing.huge)
  implicitWidth: Style.space(240)
  radius: Style.cornerRadius

  readonly property bool _hot: hasCursor || _hovered
  readonly property var _borderSpec: Border.controlSpec(_hot ? "hover-cursor" : "normal", foreground, accent)

  color: Style.controlFill(false, _hot, foreground, accent)
  borderSpec: _borderSpec

  Behavior on color { ColorAnimation { duration: 100 } }

  Row {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: root.borderLeft + Style.spacing.rowPaddingX
    anchors.rightMargin: root.borderRight + Style.spacing.rowPaddingX
    spacing: Style.spacing.rowPaddingX

    Column {
      width: parent.width - group.width - parent.spacing
      spacing: Style.spacing.xs
      anchors.verticalCenter: parent.verticalCenter

      Text {
        textFormat: Text.PlainText
        text: root.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: root.titleSize
        font.bold: true
        elide: Text.ElideRight
        width: parent.width
      }

      Text {
        textFormat: Text.PlainText
        visible: root.description !== ""
        text: root.description
        color: Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: root.descriptionSize
        wrapMode: Text.WordWrap
        width: parent.width
      }
    }

    ButtonGroup {
      id: group
      options: root.options
      value: root.value
      focusable: false
      anchors.verticalCenter: parent.verticalCenter
      onChanged: function(v) { root.changed(v) }
    }
  }

  HoverHandler {
    onHoveredChanged: {
      root._hovered = hovered
      root.hovered(hovered)
    }
  }
}