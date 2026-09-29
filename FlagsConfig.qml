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
  property bool ready: false

  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/obscure.flags.json"

  function reload() {
    file.reload()
    root.apply(file.text())
  }

  function apply(raw) {
    var o = {}
    try { o = JSON.parse(String(raw || "")) } catch (e) { o = {} }
    var arr = Array.isArray(o.flags) ? o.flags : []
    var out = []
    for (var i = 0; i < arr.length; i++) {
      var e = arr[i]
      if (!e || typeof e !== "object") continue
      var token = String(e.token || "").toLowerCase()
      // tokens must be raw letters only: the regex alternation interpolates
      // them and the chip filter is /^-[a-z.]+$/ — anything else could inject
      // or render oddly.
      if (!/^[a-z]{1,4}$/.test(token)) continue
      var label = String(e.label || "").trim()
      if (label === "") continue
      var url = String(e.url || "").trim()
      if (!/^https?:\/\//.test(url) || url.indexOf("{q}") < 0) continue
      out.push({
        token: token,
        label: label,
        url: url,
        placeholder: String(e.placeholder || "").trim(),
        hint: String(e.hint || "").trim(),
        detail: String(e.detail || "").trim()
      })
    }
    root.flags = out
    root.ready = true
  }

  // The config is read BLOCKING at construction so the first open already sees
  // the full registry. No onFileChanged: the watcher never fires on this host,
  // updates come from the settings "Reload flags" button (or a shell restart).
  FileView {
    id: file
    path: root.configPath
    blockLoading: true
    watchChanges: false
  }

  Component.onCompleted: root.apply(file.text())
}