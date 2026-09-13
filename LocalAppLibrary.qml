import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Local fallback for shell.appLibrary.
//
// The shell normally injects its shared AppLibrary as shell.appLibrary, but
// third-party panel/overlay/menu plugins receive null: the host's Instantiator
// converts the manifest's `kinds` array to a V4Sequence, so its
// Array.isArray() kind check fails. This component reproduces AppLibrary.qml's
// public surface (entryName / entrySubtext / sortedEntries / iconSource /
// refreshIcons / launch / remove / appsChanged) so Launchpad can call either
// implementation interchangeably. It is only instantiated as a fallback; when
// the official library is available it is never called.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  property var configuredHiddenEntryIds: ({})
  property var desktopHiddenEntryIds: ({})
  property var iconIndex: ({})
  property var pendingIconIndex: ({})

  // Mirrors AppLibrary.appsChanged: the visible app set may have changed.
  signal appsChanged()

  function entryName(entry) {
    return String((entry && entry.name) || (entry && entry.id) || "")
  }

  function entrySubtext(entry) {
    return String((entry && entry.genericName) || "")
  }

  function isHiddenEntry(entry) {
    var id = String((entry && entry.id) || "")
    return root.configuredHiddenEntryIds[id] === true || root.desktopHiddenEntryIds[id] === true
  }

  function keywordText(entry) {
    try {
      if (entry && entry.keywords && typeof entry.keywords.join === "function")
        return entry.keywords.join(" ")
    } catch (e) { /* ignore */ }
    return ""
  }

  function entrySearchText(entry) {
    if (!entry) return ""
    return [entry.name, entry.genericName, entry.comment, root.keywordText(entry), entry.id]
      .join(" ").toLowerCase()
  }

  function wordText(value) {
    return String(value || "")
      .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
      .replace(/[._:/\\-]+/g, " ")
      .toLowerCase()
  }

  function words(value) {
    var values = root.wordText(value).split(/[^a-z0-9]+/)
    var result = []
    for (var i = 0; i < values.length; i++) if (values[i]) result.push(values[i])
    return result
  }

  function entryAcronym(entry) {
    var values = root.words([entry && entry.name, entry && entry.genericName,
      root.keywordText(entry), entry && entry.id].join(" "))
    var result = ""
    for (var i = 0; i < values.length; i++) result += values[i].charAt(0)
    return result
  }

  function termMatches(entry, term) {
    if (!term) return true
    var name = root.entryName(entry).toLowerCase()
    var id = String((entry && entry.id) || "").toLowerCase()
    var haystack = root.entrySearchText(entry)
    if (name.indexOf(term) >= 0) return true
    if (id.indexOf(term) >= 0) return true
    if (haystack.indexOf(term) >= 0) return true
    return term.length <= 5 && root.entryAcronym(entry).indexOf(term) >= 0
  }

  function allTermsMatch(entry, query) {
    var terms = String(query || "").toLowerCase().trim().split(/\s+/)
    for (var i = 0; i < terms.length; i++)
      if (terms[i] && !root.termMatches(entry, terms[i])) return false
    return true
  }

  function fuzzyScore(entry, query) {
    var q = String(query || "").trim().toLowerCase()
    if (!q) return 0
    if (!root.allTermsMatch(entry, q)) return -1
    var name = root.entryName(entry).toLowerCase()
    var id = String((entry && entry.id) || "").toLowerCase()
    var haystack = root.entrySearchText(entry)
    var directName = name.indexOf(q)
    var directId = id.indexOf(q)
    if (directName === 0) return 10000 - name.length
    if (directId === 0) return 9500 - id.length
    if (directName > 0) return 8000 - directName * 10 - name.length
    if (directId > 0) return 7600 - directId * 10 - id.length
    var hayIndex = haystack.indexOf(q)
    if (hayIndex >= 0) return 6000 - hayIndex
    var acronym = root.entryAcronym(entry)
    var acronymIndex = acronym.indexOf(q)
    if (acronymIndex === 0) return 5000 - acronym.length
    if (acronymIndex > 0) return 4600 - acronymIndex * 10 - acronym.length
    return 4000 - name.length
  }

  function sortedEntries(query) {
    var values = DesktopEntries.applications.values || []
    var q = String(query || "").trim()
    var rows = []
    for (var i = 0; i < values.length; i++) {
      var entry = values[i]
      if (!entry || entry.noDisplay) continue
      if (root.isHiddenEntry(entry)) continue
      var name = root.entryName(entry)
      if (!name) continue
      var score = root.fuzzyScore(entry, q)
      if (score < 0) continue
      rows.push({ entry: entry, score: score, key: name.toLowerCase(), name: name.toLowerCase() })
    }
    rows.sort(function(a, b) {
      if (q && a.score !== b.score) return b.score - a.score
      if (a.key < b.key) return -1
      if (a.key > b.key) return 1
      if (a.name < b.name) return -1
      if (a.name > b.name) return 1
      return 0
    })
    return rows
  }

  function iconSource(icon) {
    var value = String(icon || "")
    if (value.length === 0) return Quickshell.iconPath("application-x-executable", true)
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    var found = root.iconIndex[value]
    if (found) return Util.fileUrl(found)
    var themed = Quickshell.iconPath(value, true)
    if (themed.length > 0) return themed
    return Quickshell.iconPath("application-x-executable", true)
  }

  function refreshIcons() {
    if (!iconIndexScan.running) iconIndexScan.running = true
  }

  function launch(desktopId, name) {
    var id = String(desktopId || "")
    if (!id) return
    Util.execDetached("uwsm-app -- gtk-launch " + Util.shellQuote(id + ".desktop"))
  }

  function remove(desktopId, name) {
    var id = String(desktopId || "")
    if (!id) return
    Util.execDetached(Util.shellQuote(root.omarchyPath + "/bin/omarchy-remove-launcher-entry")
      + " " + Util.shellQuote(id) + " " + Util.shellQuote(String(name || id)))
  }

  function normalizeDesktopId(id) {
    var value = String(id || "").trim()
    if (value.slice(-8) === ".desktop") value = value.slice(0, -8)
    return value
  }

  function loadConfiguredHides(rawText) {
    var next = ({})
    var lines = String(rawText || "").split(/\n/)
    for (var i = 0; i < lines.length; i++) {
      var id = root.normalizeDesktopId(lines[i])
      if (id.length > 0) next[id] = true
    }
    root.configuredHiddenEntryIds = next
    root.appsChanged()
  }

  function loadDesktopHiddenEntries(rawText) {
    var next = ({})
    var lines = String(rawText || "").split(/\n/)
    for (var i = 0; i < lines.length; i++) {
      var id = root.normalizeDesktopId(lines[i])
      if (id.length > 0) next[id] = true
    }
    root.desktopHiddenEntryIds = next
    root.appsChanged()
  }

  function iconIndexScanCommand() {
    return [
      'dirs="$HOME/.icons $HOME/.local/share/icons";',
      'IFS=":"; for d in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do dirs="$dirs $d/icons"; done; unset IFS;',
      'for ext in svg png; do',
      '  for base in $dirs; do',
      '    [[ -d $base ]] && find "$base" \\( -path "*/apps/*" -o -path "*/devices/*" \\) -name "*.$ext" 2>/dev/null;',
      '  done;',
      '  find /usr/share/pixmaps -maxdepth 1 -name "*.$ext" 2>/dev/null;',
      'done'
    ].join(' ')
  }

  function indexIconLine(path) {
    var value = String(path || "").trim()
    if (value.length === 0) return
    var slash = value.lastIndexOf("/")
    var file = slash >= 0 ? value.slice(slash + 1) : value
    var dot = file.lastIndexOf(".")
    var name = dot > 0 ? file.slice(0, dot) : file
    if (name.length > 0 && root.pendingIconIndex[name] === undefined)
      root.pendingIconIndex[name] = value
  }

  function hiddenEntryScanCommand() {
    var desktop = [Quickshell.env("XDG_CURRENT_DESKTOP"), Quickshell.env("XDG_SESSION_DESKTOP"),
      Quickshell.env("DESKTOP_SESSION")].filter(function(v) {
        return String(v || "").length > 0
      }).join(":")
    var script = root.omarchyPath + "/shell/services/hidden-entries.sh"
    return Util.shellQuote(script) + " " + Util.shellQuote(desktop)
  }

  QtObject {
    id: hiddenEntryOutput
    property string text: ""
  }

  Process {
    id: hiddenEntryScan
    command: ["bash", "-c", root.hiddenEntryScanCommand()]
    stdout: SplitParser { onRead: function(line) { hiddenEntryOutput.text += line + "\n" } }
    onStarted: hiddenEntryOutput.text = ""
    onExited: root.loadDesktopHiddenEntries(hiddenEntryOutput.text)
  }

  Process {
    id: iconIndexScan
    command: ["bash", "-c", root.iconIndexScanCommand()]
    stdout: SplitParser { onRead: function(line) { root.indexIconLine(line) } }
    onStarted: root.pendingIconIndex = ({})
    onExited: root.iconIndex = root.pendingIconIndex
  }

  Timer {
    id: iconIndexDebounce
    interval: 750
    onTriggered: if (!iconIndexScan.running) iconIndexScan.running = true
  }

  FileView {
    path: root.omarchyPath + "/default/omarchy/launcher.hides"
    watchChanges: true
    printErrors: false
    onLoaded: root.loadConfiguredHides(text())
    onFileChanged: root.loadConfiguredHides(text())
    onLoadFailed: root.loadConfiguredHides("")
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() {
      hiddenEntryScan.running = true
      iconIndexDebounce.restart()
      root.appsChanged()
    }
  }

  Component.onCompleted: {
    hiddenEntryScan.running = true
    iconIndexScan.running = true
  }
}
