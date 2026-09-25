// Fallback routing for unflagged queries (the "auto" mode) and web helpers.
.pragma library

// Pick where to dispatch an Enter press when no flag was typed.
// "apps" tab: launch an app, else hand the query to Google.
// "files" tab: open a file, else hand the query to Google.
function decide(tabMode, appCount, fileCount) {
  if (tabMode === "apps") return appCount > 0 ? "apps" : "web"
  if (tabMode === "files") return fileCount > 0 ? "files" : "web"
  return "web"
}

function googleUrl(query) {
  return "https://www.google.com/search?q=" + encodeURIComponent(String(query || ""))
}

function imagesUrl(query) {
  return "https://www.google.com/search?q=" + encodeURIComponent(String(query || "")) + "&tbm=isch"
}

function pinterestUrl(query) {
  return "https://www.pinterest.com/search/pins/?q=" + encodeURIComponent(String(query || ""))
}

function artstationUrl(query) {
  return "https://www.artstation.com/search?query=" + encodeURIComponent(String(query || ""))
}

function sketchfabUrl(query) {
  return "https://sketchfab.com/search?type=models&q=" + encodeURIComponent(String(query || ""))
}

function youtubeUrl(query) {
  return "https://www.youtube.com/results?search_query=" + encodeURIComponent(String(query || ""))
}

function ddgUrl(query) {
  return "https://duckduckgo.com/?q=" + encodeURIComponent(String(query || ""))
}