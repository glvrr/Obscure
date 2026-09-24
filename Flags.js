// Query-line parser and text ranking helpers for the spotlight.
.pragma library

const MODES = {
  f: "files",
  d: "dirs",
  g: "web",
  p: "pinterest",
  i: "images",
  a: "apps",
  o: "menu",
  r: "run",
  "as": "artstation",
  "sf": "sketchfab"
}

// Splits "text" into { mode, flag, query, hidden, flags }.
// Leading `-x` tokens (x a known flag letter) select the mode, `-.` toggles
// hidden files; both are stripped from the query. Anything else keeps "auto".
// `flag`/`mode` stay the FIRST flag (drives the UI), `flags` lists every mode
// flag present in oder without repeats so multiple requests can all dispatch.
function parseQuery(text) {
  var raw = String(text || "")
  var flag = ""
  var flags = []
  var hidden = false
  var m
  // Tokens are single letters plus the two-letter flags (-as/-sf); the
  // alternation + backtracking keep "-af cats" and "-a ca..." as raw text.
  var re = /^\s*-((?:as|sf|[a-z.]))(?:\s+|$)/
  while ((m = re.exec(raw))) {
    var token = m[1]
    if (token === ".") {
      hidden = true
      raw = raw.replace(m[0], "").trim()
      continue
    }
    if (MODES[token]) {
      if (flag === "") flag = token
      if (flags.indexOf(token) < 0) flags.push(token)
      raw = raw.replace(m[0], "").trim()
      continue
    }
    break
  }
  return { mode: flag ? MODES[flag] : "auto", flag: flag, query: raw.trim(), hidden: hidden, flags: flags }
}

// Ctrl-key dispatch for in-card hotkeys (Qt key codes == ASCII). Returns a
// command token for the spotlight or "" when the combo is not a hotkey.
// Digits: 1 menu, 2 apps, 3 files, 4 g, 5 p, 6 i, 0 r.
// Letters: D files-dir flag, F files, G g, I i, K settings, O menu, P p, R r.
function ctrlCommand(key, ctrl) {
  if (!ctrl) return ""
  var digits = { 49: "menu", 50: "apps", 51: "files", 52: "g", 53: "p", 54: "i", 48: "r" }
  if (digits[key]) return digits[key]
  var letters = { 68: "d", 70: "files", 71: "g", 73: "i", 75: "settings", 79: "menu", 80: "p", 82: "r" }
  return letters[key] || ""
}

// Simple text rank for extra result ordering. Lower is better; -1 = no match.
function score(text, query) {
  var hay = String(text || "").toLowerCase()
  var q = String(query || "").toLowerCase()
  if (!q) return 0
  if (hay === q) return -2
  if (hay.indexOf(q) === 0) return hay.length
  var idx = hay.indexOf(q)
  if (idx >= 0) return hay.length + idx
  // subsequence match
  var i = 0
  for (var j = 0; j < hay.length && i < q.length; j++) {
    if (hay[j] === q[i]) i++
  }
  if (i === q.length) return hay.length * 2 + 50
  return -1
}

// Raw leading-flag prefix of "raw", i.e. everything parseQuery consumed before
// the actual query (e.g. "-g " or "-. -p "), derived from the trimmed rest.
function prefix(raw, parsed) {
  if (!parsed) parsed = parseQuery(raw)
  return String(raw || "").slice(0, String(raw || "").length - String(parsed.query).length)
}

// A leading flag becomes a chip once it is followed by a separator space or
// by query text. A bare "-g" with nothing after it is still being typed and
// stays raw text.
function swallowed(raw, parsed) {
  if (!parsed) parsed = parseQuery(raw)
  if (parsed.flag === "" && !parsed.hidden) return false
  var p = prefix(raw, parsed)
  if (p === "") return false
  return parsed.query !== "" || /\s+$/.test(p)
}

const CHIP_NAMES = {
  files: "files",
  dirs: "dirs",
  web: "google",
  pinterest: "pinterest",
  images: "images",
  apps: "apps",
  menu: "omarchy",
  run: "run",
  hidden: "hidden",
  "artstation": "artstation",
  "sketchfab": "sketchfab"
}

// Full-name labels for the confirmed leading flags, in typed order.
function chipLabels(raw, parsed) {
  if (!parsed) parsed = parseQuery(raw)
  if (!swallowed(raw, parsed)) return []
  var toks = prefix(raw, parsed).trim().split(/\s+/)
  var labels = []
  for (var i = 0; i < toks.length; i++) {
    var t = toks[i]
    if (!/^-[a-z.]+$/.test(t)) continue
    if (t === "-.") {
      labels.push("hidden")
      continue
    }
    var mode = MODES[t.substring(1)]
    if (mode && CHIP_NAMES[mode]) labels.push(CHIP_NAMES[mode])
  }
  return labels
}