import QtQuick
import Quickshell.Io
import qs.Ui

// Clipboard-safe single-line editor (marketplace review #11229).
//
// Affected Qt builds (6.11.2 / 6.12.0) connect QClipboard::dataChanged to
// QQuickTextInput::q_canPasteChanged(), which calls QMimeData::text() and pulls
// the ENTIRE foreign clipboard offer on every change — with no byte cap and no
// overall deadline — even when nothing is pasted, and before any validator or
// maximumLength runs. A read-only editor is skipped by both that path and the
// canPaste getter, so the shared shell can never be stalled or exhausted by a
// clipboard provider. This field therefore stays read-only for its whole
// lifetime; text edits and paste are bounded and go through this file. Mirrors
// the approved Oma Edge fix (marketplace #10880).
TextField {
  id: root

  // Emitted for every text change this component performs itself. The built-in
  // TextInput.textEdited only fires for native edits, which never happen here.
  signal manualEdited()

  readOnly: true
  // Keep a pasted payload from being interpreted as rich
  // text: the content item of the underlying QQC TextField would otherwise
  // fetch remote resources embedded in <img> on AutoText.
  Component.onCompleted: if (root.contentItem) root.contentItem.textFormat = Text.PlainText
  maximumLength: 1024
  cursorVisible: activeFocus
  // Qt's read-only path calls setCursorVisible(false) at construction
  // (QQuickTextInput::setReadOnly), and the built-in caret is drawn only for
  // editable fields, so a delegate is the one cursor that renders here. Its
  // visibility follows focus; width/colour mirror the kit's caret.
  cursorDelegate: Rectangle {
    id: caret
    width: 2
    radius: 1
    height: Math.max(1, root.height - root.topPadding - root.bottomPadding)
    color: root.color
    visible: root.activeFocus
    opacity: 1
    // Match the platform blink (QStyleHints::cursorFlashTime; 0 disables the
    // flash). The native caret animated this on its own, the delegate must not.
    SequentialAnimation on opacity {
      running: caret.visible && Qt.styleHints.cursorFlashTime > 0
      loops: Animation.Infinite
      NumberAnimation { to: 0.0; duration: Math.max(1, Qt.styleHints.cursorFlashTime / 2) }
      NumberAnimation { to: 1.0; duration: Math.max(1, Qt.styleHints.cursorFlashTime / 2) }
    }
  }
  selectByMouse: true
  clip: true

  // Insert text at the caret, replacing the selection, without splitting a
  // surrogate pair (QML's JS strings expose UTF-16 code units).
  function replaceSelection(replacement) {
    var start = selectionStart
    var end = selectionEnd
    var room = Math.max(0, maximumLength - (text.length - (end - start)))
    var bounded = replacement.slice(0, room)
    var last = bounded.charCodeAt(bounded.length - 1)
    if (last >= 0xd800 && last <= 0xdbff) bounded = bounded.slice(0, -1)
    text = text.slice(0, start) + bounded + text.slice(end)
    cursorPosition = start + bounded.length
    root.manualEdited()
  }

  function isPasteGesture(event) {
    if (event.key === Qt.Key_V && (event.modifiers & (Qt.ControlModifier | Qt.MetaModifier)))
      return true
    // Shift+Insert, with no other modifier held.
    if (event.key === Qt.Key_Insert && (event.modifiers & Qt.ShiftModifier)
        && !(event.modifiers & (Qt.ControlModifier | Qt.MetaModifier | Qt.AltModifier)))
      return true
    return false
  }

  // Bounded clipboard read: one child process, only on an explicit paste
  // gesture, with a hard wall-clock deadline and a fixed byte budget. No native
  // editor ever touches the dataChanged path.
  function requestPaste() {
    pasteProc.running = false
    pasteProc.running = true
  }

  // Overridable: a derived field returns true for keys it handles itself
  // (QueryBar routes Esc, Ctrl hotkeys, chip Backspace, empty-line arrows and
  // Tab). Returning false lets the shared text editing below run.
  function handleSpecialKey(event) { return false }

  function handleKey(event) {
    if (root.handleSpecialKey(event)) return
    if (isPasteGesture(event)) {
      requestPaste()
      event.accepted = true
      return
    }
    var shortcut = event.modifiers & (Qt.ControlModifier | Qt.MetaModifier | Qt.AltModifier)
    if (shortcut) {
      if (event.key === Qt.Key_A && (event.modifiers & Qt.ControlModifier)) {
        selectAll()
        event.accepted = true
      }
      // Everything else (cut, copy, ...) is left to native read-only handling,
      // which neither edits the field nor reads a foreign clipboard offer.
      return
    }
    if (event.key === Qt.Key_Backspace || event.key === Qt.Key_Delete) {
      if (selectionStart === selectionEnd) {
        var position = cursorPosition
        if (event.key === Qt.Key_Backspace && position > 0) {
          var previous = text.charCodeAt(position - 1)
          var count = previous >= 0xdc00 && previous <= 0xdfff && position > 1 ? 2 : 1
          select(position - count, position)
        } else if (event.key === Qt.Key_Delete && position < text.length) {
          var next = text.charCodeAt(position)
          var count = next >= 0xd800 && next <= 0xdbff && position + 1 < text.length ? 2 : 1
          select(position, position + count)
        }
      }
      replaceSelection("")
    } else if (event.text && !/[\x00-\x1f\x7f]/.test(event.text)) {
      replaceSelection(event.text)
    } else {
      return
    }
    event.accepted = true
  }

  // BeforeItem: the focused field must see Return before the native editor can
  // swallow it (a single-line editor emits `accepted` there); unhandled keys
  // still reach the native navigation/selection handling.
  Keys.priority: Keys.BeforeItem
  Keys.onPressed: function(event) { root.handleKey(event) }

  Process {
    id: pasteProc
    running: false
    command: ["sh", "-c", "timeout -k 1 2 wl-paste -n 2>/dev/null | head -c 512"]
    stdout: StdioCollector {
      id: pasteOut
      waitForEnd: true
      onStreamFinished: {
        // Single-line field: collapse control/whitespace runs, trim the ends.
        var t = pasteOut.text.replace(/[\x00-\x1f\x7f]+/g, " ").replace(/^\s+|\s+$/g, "")
        if (t.length > 0) root.replaceSelection(t)
      }
    }
  }
}
