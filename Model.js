// Pure helpers for the overlay: parsing `wpe.sh list` output, filtering,
// and working out which monitors currently show a wallpaper.

// ok is false when the text isn't a complete list, e.g. cut off at the size cap.
function parseList(text) {
  var data = null
  try { data = JSON.parse(String(text || "")) } catch (e) { data = null }
  var ok = !!data && typeof data === "object" && Array.isArray(data.wallpapers)

  return {
    ok: ok,
    active: ok && data.active && typeof data.active === "object" ? data.active : {},
    wallpapers: ok ? data.wallpapers : [],
    truncated: ok && data.truncated === true
  }
}

// Message for a failed `wpe.sh list`, from the exit status of its wrapper.
function listError(exitCode) {
  if (exitCode === 124 || exitCode === 137) return "Timed out listing wallpapers"
  if (exitCode === 3 || exitCode === 141 || exitCode === 0) return "Wallpaper library is too large to list"
  return "Couldn't list wallpapers (exit " + exitCode + ")"
}

// Message for a failed apply/stop: the last line the backend printed.
function actionError(exitCode, text) {
  if (exitCode === 124 || exitCode === 137) return "Timed out; the wallpaper may not have changed"
  var lines = String(text || "").trim().split("\n")
  return lines[lines.length - 1] || ("wpe.sh exited with " + exitCode)
}

function matches(wallpaper, filterText) {
  var needle = String(filterText || "").toLowerCase().trim()
  if (!needle) return true

  var haystack = (String(wallpaper.title || "") + " " + String(wallpaper.type || "") + " " + String(wallpaper.id || "")).toLowerCase()
  var words = needle.split(/\s+/)
  for (var i = 0; i < words.length; i++) {
    if (haystack.indexOf(words[i]) === -1) return false
  }
  return true
}

function filter(wallpapers, filterText) {
  var out = []
  for (var i = 0; i < wallpapers.length; i++) {
    if (matches(wallpapers[i], filterText)) out.push(wallpapers[i])
  }
  return out
}

function screensShowing(active, dir) {
  var out = []
  for (var screen in active) {
    if (active[screen] === dir) out.push(screen)
  }
  return out.sort()
}

function indexOfDir(wallpapers, dir) {
  for (var i = 0; i < wallpapers.length; i++) {
    if (wallpapers[i].dir === dir) return i
  }
  return -1
}

function typeLabel(type) {
  var value = String(type || "")
  return value ? value.charAt(0).toUpperCase() + value.slice(1) : ""
}

if (typeof module !== "undefined") {
  module.exports = {
    parseList: parseList,
    listError: listError,
    actionError: actionError,
    matches: matches,
    filter: filter,
    screensShowing: screensShowing,
    indexOfDir: indexOfDir,
    typeLabel: typeLabel
  }
}
