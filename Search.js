// Fallback routing for unflagged queries (the "auto" mode) and URL templating.
.pragma library

// Pick where to dispatch an Enter press when no flag was typed.
// "apps" tab: launch an app, else hand the query to Google.
// "files" tab: open a file, else hand the query to Google.
function decide(tabMode, appCount, fileCount) {
  if (tabMode === "apps") return appCount > 0 ? "apps" : "web"
  if (tabMode === "files") return fileCount > 0 ? "files" : "web"
  return "web"
}

// Render a {"token","url"} web-flag template. {q} is the query, URL-encoded;
// the whole template is validated (http(s) + a {q} hole) by FlagsConfig before
// it ever reaches the dispatch maps.
function templateUrl(template, query) {
  return String(template || "").replace(/\{q\}/g, encodeURIComponent(String(query || "")))
}

// "Type-to-front" rank: 0 when ANY of `names` starts with the query (case-
// insensitive), 1 otherwise. An empty query returns 0 for everything, so a
// caller can leave the incoming order untouched. Used to float results whose
// name begins with what the user typed above the fuzzy (substring) hits —
// apps pass [label, desktopIdLeaf] so "gimp" surfaces GIMP even though its
// label is "GNU Image Manipulation Program", files pass the basename.
function prefixRank(names, query) {
  var q = String(query || "").trim().toLowerCase()
  if (q === "") return 0
  var list = Array.isArray(names) ? names : [names]
  for (var i = 0; i < list.length; i++) {
    var n = String(list[i] === null || list[i] === undefined ? "" : list[i]).toLowerCase()
    if (n.indexOf(q) === 0) return 0
  }
  return 1
}