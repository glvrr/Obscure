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
//
// Fresh installs get a starter file (see seedJson): a missing file is created
// with -git and -ddg, so the feature is not empty out of the box. An existing
// file is never written by the plugin, not even an empty one.
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
  // True when the last read found no file on disk. That is the fresh-install
  // case, not an error: it seeds the starter set below (see onMissing).
  property bool missing: false

  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/obscure.flags.json"

  // Starter set written to a FRESH install, so the flags feature is useful out
  // of the box instead of shipping empty. Deliberately generic and minimal
  // (only the token/label/url that are required — placeholder/hint/detail derive
  // from the label) and deliberately NOT a copy of anyone's personal file: an
  // existing config is never rewritten, only a missing one is created.
  readonly property string seedJson: '{\n'
    + '  "flags": [\n'
    + '    { "token": "git", "label": "GitHub", "url": "https://github.com/search?q={q}" },\n'
    + '    { "token": "ddg", "label": "DuckDuckGo", "url": "https://duckduckgo.com/?q={q}" }\n'
    + '  ]\n'
    + '}\n'

  // Fired after a fresh-install seed, so the shell can rebuild its registry
  // without waiting for a restart. The seed is written asynchronously relative
  // to the caller's read, so setupFlags() at startup can run before this.
  signal seeded()

  function reload() {
    root.afterRead()
  }

  // The file is not on disk: this is a fresh install, so write the starter set
  // and use it. Called from the FileNotFound handler, which may fire before OR
  // after afterRead's own read — so it must be safe to run at any point, and
  // must leave the same end state either way (that is why it applies the seed
  // itself instead of relying on a flag the reader checks). Idempotent: the
  // write makes the file exist, so the notification cannot loop.
  function onMissing() {
    root.missing = true
    file.setText(root.seedJson)
    // Apply the string we just wrote rather than reading it back, so the
    // registry is correct even if the write failed (read-only config dir).
    root.apply(root.seedJson)
    root.seeded()
  }

  // One blocking read, then seed-or-validate. An empty read while the file is
  // known to be missing is the fresh-install gap around the seed, and onMissing
  // applies the starter set a moment later — do not clobber it with an empty
  // registry in the meantime.
  function afterRead() {
    file.reload()
    var text = file.text()
    if (text === "" && root.missing) return
    root.missing = false
    root.apply(text)
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
  // reload() block until the read completes, so the content is always fresh.
  // blockWrites is the same idea for the seed write, which must be on disk
  // before the next start reads it.
  FileView {
    id: file
    path: root.configPath
    // No background load: every read goes through afterRead()'s synchronous
    // reload(), which is what makes the missing-file seed deterministic.
    preload: false
    blockLoading: true
    blockAllReads: true
    blockWrites: true
    // A missing file is the expected state on a fresh install (it gets seeded
    // below), so the stock "read failed" warning would be noise. Genuine
    // problems still surface: a failed seed write is logged in onSaveFailed.
    printErrors: false
    onLoadFailed: (error) => {
      if (error === 2) root.onMissing() // FileNotFound
    }
    onSaveFailed: (error) => {
      console.warn("obscure: cannot write " + root.configPath + " (error " + error + ")")
    }
  }

  Component.onCompleted: root.afterRead()
}