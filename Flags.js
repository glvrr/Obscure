// Query-line parser and text ranking helpers for the spotlight.
.pragma library

const MODES = {
  f: "files",
  d: "dirs",
  g: "web",
  a: "apps",
  o: "menu",
  r: "run"
}

// Splits "text" into { mode, flag, query }.
// A leading `-x` token (x a known flag letter) selects the mode and is
// stripped from the query; anything else keeps "auto".
function parseQuery(text) {
  var raw = String(text || "")
  var m = /^\s*-([a-z])(?:\s+|$)/.exec(raw)
  if (m && MODES[m[1]]) {
    return { mode: MODES[m[1]], flag: m[1], query: raw.replace(m[0], "").trim() }
  }
  return { mode: "auto", flag: "", query: raw.trim() }
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