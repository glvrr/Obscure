import QtQuick
import Quickshell
import Quickshell.Io

// User-defined web flags (obscure.flags.json, kept next to the settings file
// and out of the plugin checkout). Spotlight merges these with the built-in
// defaults in setupFlags(); the file WINS for the same token, so -g can be
// rebound to any engine and brand-new flags can be added.
//
// File shape: { "flags": [ { "token", "label", "url", "placeholder"?,
// "hint"?, "detail"? } ] }
//   - token: 1..4 lowercase letters ([a-z]{1,4}); built-in single-letter
//     flags (g/i/p/y) are overridable, the non-web ones (r/o/a/f/d/oc) are
//     reserved and ignored.
//   - url:   http(s):// template with a {q} hole, e.g.
//     "https://ecosia.org/search?q={q}". The {q} is URL-encoded on dispatch.
//   - label: short name shown on the chip, placeholder and multi-search hint.
//   - placeholder/hint/detail: optional; defaults are derived from label.
// Invalid entries (bad token, missing label, bad URL) are skipped, so a typo
// costs one flag instead of the whole file.
// Reading is a BLOCKING FileView (same reason as SettingsStore): the registry
// is needed on the very first open and a host of components read it at
// construction. reload() is the manual "Reload flags" path — the watcher is
// dead on this host.
Item {
  id: root

  visible: false

  // Validated, in file order: { token, label, url, placeholder, hint, detail }.
  property var flags: []
  // Human labels of the entries that were skipped by the last read (bad token,
  // missing label, bad URL, malformed JSON). The settings "Reload flags" path
  // reports them so a silently dropped flag is visible instead of just gone.
  property var dropped: []
  property bool ready: false

  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/obscure.flags.json"

  function reload() {
    file.reload()
    root.apply(file.text())
  }

  // Name a skipped entry for the Reload feedback: its own label when present,
  // else "-token", else its position in the file.
  function entryLabel(e, i) {
    var l = String((e && e.label) || "").trim()
    if (l !== "") return l
    var t = String((e && e.token) || "").trim()
    if (t !== "") return "-" + t
    return "entry " + (i + 1)
  }

  function apply(raw) {
    var text = String(raw || "")
    var o = {}
    var parseFailed = false
    try { o = JSON.parse(text) } catch (e) { parseFailed = true; o = {} }
    var arr = Array.isArray(o.flags) ? o.flags : []
    var out = []
    var dropped = []
    // Empty/absent file is not an error (it just means "no custom flags"); a
    // non-empty file that does not parse is worth reporting.
    if (parseFailed && text.trim() !== "") dropped.push("(invalid JSON)")
    for (var i = 0; i < arr.length; i++) {
      var e = arr[i]
      if (!e || typeof e !== "object") { dropped.push(root.entryLabel(e, i)); continue }
      var token = String(e.token || "").toLowerCase()
      // tokens must be raw letters only: the regex alternation interpolates
      // them and the chip filter is /^-[a-z.]+$/ — anything else could inject
      // or render oddly.
      if (!/^[a-z]{1,4}$/.test(token)) { dropped.push(root.entryLabel(e, i)); continue }
      var label = String(e.label || "").trim()
      if (label === "") { dropped.push(root.entryLabel(e, i)); continue }
      var url = String(e.url || "").trim()
      if (!/^https?:\/\//.test(url) || url.indexOf("{q}") < 0) { dropped.push(root.entryLabel(e, i)); continue }
      out.push({
        token: token,
        label: label,
        url: url,
        placeholder: String(e.placeholder || "").trim(),
        hint: String(e.hint || "").trim(),
        detail: String(e.detail || "").trim()
      })
    }
    root.dropped = dropped
    root.flags = out
    root.ready = true
  }

  // The config is read BLOCKING at construction so the first open already sees
  // the full registry. No onFileChanged: the watcher never fires on this host,
  // updates come from the settings "Reload flags" button (or a shell restart).
  //
  // blockAllReads (not just blockLoading) is REQUIRED: with blockLoading alone,
  // reload() returns immediately and text() keeps serving the old snapshot until
  // the async load finishes — so the first "Reload flags" click applied stale
  // content and only the second one showed the edit. blockAllReads makes
  // reload() block until the read completes, so apply(file.text()) right after
  // is always fresh. The file is tiny and the read is a user action, so the
  // blocking stutter the docs warn about does not matter here.
  FileView {
    id: file
    path: root.configPath
    blockLoading: true
    blockAllReads: true
    watchChanges: false
  }

  Component.onCompleted: root.apply(file.text())
}