// Pure helpers for the overlay: parsing `wpe.sh list` output, filtering,
// and working out which monitors currently show a wallpaper.

function parseList(text) {
  var data = {}
  try { data = JSON.parse(String(text || "")) || {} } catch (e) { data = {} }

  return {
    active: data.active && typeof data.active === "object" ? data.active : {},
    wallpapers: Array.isArray(data.wallpapers) ? data.wallpapers : []
  }
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
    matches: matches,
    filter: filter,
    screensShowing: screensShowing,
    indexOfDir: indexOfDir,
    typeLabel: typeLabel
  }
}
