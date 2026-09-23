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

// Splits "text" into { mode, flag, query, hidden }.
// Leading `-x` tokens (x a known flag letter) select the mode, `-.` toggles
// hidden files; both are stripped from the query. Anything else keeps "auto".
function parseQuery(text) {
  var raw = String(text || "")
  var flag = ""
  var hidden = false
  var m
  var re = /^\s*-([a-z.])(?:\s+|$)/
  while ((m = re.exec(raw))) {
    var token = m[1]
    if (token === ".") {
      hidden = true
      raw = raw.replace(m[0], "").trim()
      continue
    }
    if (MODES[token]) {
      if (flag === "") flag = token
      raw = raw.replace(m[0], "").trim()
      continue
    }
    break
  }
  return { mode: flag ? MODES[flag] : "auto", flag: flag, query: raw.trim(), hidden: hidden }
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