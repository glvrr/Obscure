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
  "sf": "sketchfab",
  y: "youtube",
  ddg: "ddg",
  da: "deviantart"
}

// Object-literal prototypes expose broken "toString"/"constructor" keys, but
// they are unreachable here: parseQuery only ever hands us one-letter tokens
// or the explicit -as/-sf/-ddg/-da words, none of which collide with object
// members. (Verified loop this back into the parsed lookup with in/own checks
// — a mode key can never be "toString"; the regex guarantees it.)

// A leading flag token. Single letters plus the whole words -as/-sf/-ddg/-da;
// the alternation + backtracking keep unknown heads ("-af cats", "-ddu") as
// raw text and prevent "-ddg" from being split into "-d" + raw "dg".
const FLAG_RE = /^\s*-((?:ddg|da|as|sf|[a-z.]))(?:\s+|$)/

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
  // See FLAG_RE above; it also drives chip/prefix alignment in prefix().
  var re = FLAG_RE
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
// the actual query (e.g. "-g " or "-. -p "). Walked token-by-token instead of
// derived from the length of the (trimmed) query so trailing separators like
// "-p " keep the alignment: slicing by the trimmed length would leak the first
// query character into the prefix ("-p cat " -> "-p c") and duplicate it.
// Only REAL chip tokens (a known flag letter/word or "-.") are consumed: an
// invalid head ("-s", "-ss", "-af") is query text and must stay in the editable
// part. FLAG_RE would happily slurp a bare "-s" at the end of the string, which
// used to hide it behind the chip row as invisible, uneditable text.
function prefix(raw, parsed) {
  if (!parsed) parsed = parseQuery(raw)
  var s = String(raw || "")
  var re = FLAG_RE
  var n = 0
  var m
  while ((m = re.exec(s.slice(n)))) {
    if (m[1] !== "." && !MODES[m[1]]) break
    n += m[0].length
  }
  return s.slice(0, n)
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
  "sketchfab": "sketchfab",
  youtube: "youtube",
  ddg: "ddg",
  deviantart: "deviantart"
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