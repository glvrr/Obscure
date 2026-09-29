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