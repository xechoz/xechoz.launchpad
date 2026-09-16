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

  // Absolute executables. Resolving these through the ambient PATH would let a
  // shadowed binary run in the long-lived shell context, so every spawn below
  // uses a verified absolute path instead.
  readonly property string bashPath: "/usr/bin/bash"
  readonly property string uwsmAppPath: "/usr/bin/uwsm-app"
  readonly property string gtkLaunchPath: "/usr/bin/gtk-launch"

  // Bundled scan runner. It caps the producer stream before any parser sees it
  // and runs each scan in its own process group so the deadline can TERM/KILL
  // the whole tree. Resolved relative to this file so it travels with the
  // plugin; the file:// prefix is stripped for the argv vector.
  readonly property string scanGuardPath: {
    var url = String(Qt.resolvedUrl("scan-guard.sh"))
    if (url.indexOf("file://") === 0) url = url.slice(7)
    try { url = decodeURIComponent(url) } catch (e) { /* keep raw */ }
    return url
  }

  // OMARCHY_PATH is ambient environment, so it is untrusted until validated.
  // Only the installed Omarchy tree is accepted; anything else disables the
  // removal action rather than building a command from attacker-controlled
  // input.
  readonly property string omarchyPath: {
    var value = String(Quickshell.env("OMARCHY_PATH") || "")
    if (value.charAt(0) !== "/") return ""
    if (value.indexOf("..") >= 0) return ""
    return value
  }
  readonly property bool omarchyPathValid: root.omarchyPath === "/usr/share/omarchy"

  // Environment allowlist for spawned processes. The process environment is
  // cleared and only these keys are re-added, so a polluted parent environment
  // cannot influence the child. Values come from the session via
  // Quickshell.env(); empty keys are omitted.
  readonly property var spawnEnvironment: {
    var env = {
      "PATH": "/usr/local/bin:/usr/bin:/bin",
      "HOME": Quickshell.env("HOME") || "",
      "XDG_DATA_HOME": Quickshell.env("XDG_DATA_HOME") || "",
      "XDG_DATA_DIRS": Quickshell.env("XDG_DATA_DIRS") || "/usr/local/share:/usr/share",
      "XDG_CONFIG_HOME": Quickshell.env("XDG_CONFIG_HOME") || "",
      "XDG_CACHE_HOME": Quickshell.env("XDG_CACHE_HOME") || "",
      "XDG_RUNTIME_DIR": Quickshell.env("XDG_RUNTIME_DIR") || "",
      "XDG_CURRENT_DESKTOP": Quickshell.env("XDG_CURRENT_DESKTOP") || "",
      "XDG_SESSION_DESKTOP": Quickshell.env("XDG_SESSION_DESKTOP") || "",
      "DESKTOP_SESSION": Quickshell.env("DESKTOP_SESSION") || "",
      "WAYLAND_DISPLAY": Quickshell.env("WAYLAND_DISPLAY") || "",
      "DISPLAY": Quickshell.env("DISPLAY") || "",
      "DBUS_SESSION_BUS_ADDRESS": Quickshell.env("DBUS_SESSION_BUS_ADDRESS") || "",
      "LANG": Quickshell.env("LANG") || "",
      "LC_ALL": Quickshell.env("LC_ALL") || ""
    }
    var out = ({})
    for (var key in env) if (env[key] !== "") out[key] = env[key]
    return out
  }

  // Icon roots that desktop-entry icon metadata may reference. Anything outside
  // these is rejected so a crafted entry cannot make Image load an arbitrary
  // file:// or image:// resource.
  readonly property var iconRoots: {
    var roots = [Quickshell.env("HOME") + "/.icons", Quickshell.env("HOME") + "/.local/share/icons"]
    var dataDirs = String(Quickshell.env("XDG_DATA_DIRS") || "/usr/local/share:/usr/share").split(":")
    for (var i = 0; i < dataDirs.length; i++) if (dataDirs[i]) roots.push(dataDirs[i] + "/icons")
    roots.push("/usr/share/pixmaps")
    return roots
  }

  function isAllowedIconPath(path) {
    var value = String(path || "")
    if (value.charAt(0) !== "/") return false
    if (value.indexOf("..") >= 0) return false
    for (var i = 0; i < root.iconRoots.length; i++) {
      var base = root.iconRoots[i]
      if (base && (value === base || value.indexOf(base + "/") === 0)) return true
    }
    return false
  }

  property var configuredHiddenEntryIds: ({})
  property var desktopHiddenEntryIds: ({})
  property var iconIndex: ({})
  property var pendingIconIndex: ({})
  property int pendingIconIndexCount: 0
  property bool hiddenEntriesTruncated: false
  property bool iconIndexTruncated: false
  readonly property int maxIconIndexEntries: 5000
  readonly property int maxHiddenEntryBytes: 262144
  readonly property int maxIconIndexBytes: 1048576
  readonly property int scanDeadlineMs: 10000
  readonly property int scanKillGraceMs: 2000
  // The helper enforces scanDeadlineMs/scanKillGraceMs itself; this later
  // backstop only fires if the helper is wedged, and its TERM is forwarded to
  // the scan's process group by the helper's trap.
  readonly property int scanBackstopMs: 15000
  readonly property string truncationMarker: "__launchpad_scan_truncated__"

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
    // Desktop-entry icon metadata is untrusted. Only file:// URLs and absolute
    // paths under a known icon root are honored; image:// providers are refused
    // outright because they can load arbitrary resources.
    if (value.indexOf("file://") === 0) {
      var decoded = decodeURIComponent(value.slice(7))
      return root.isAllowedIconPath(decoded) ? value : Quickshell.iconPath("application-x-executable", true)
    }
    if (value.indexOf("image://") === 0) return Quickshell.iconPath("application-x-executable", true)
    if (value.charAt(0) === "/") return root.isAllowedIconPath(value) ? Util.fileUrl(value) : Quickshell.iconPath("application-x-executable", true)
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
    // argv vector, not a shell string: the untrusted id never gets re-tokenized.
    // uwsm-app resolves gtk-launch by absolute path and the environment is
    // cleared to the allowlist, so a shadowed binary cannot be picked up.
    Quickshell.execDetached({
      command: [root.uwsmAppPath, "--", root.gtkLaunchPath, id + ".desktop"],
      clearEnvironment: true,
      environment: root.spawnEnvironment
    })
  }

  function remove(desktopId, name) {
    var id = String(desktopId || "")
    if (!id) return
    if (!root.omarchyPathValid) return
    Quickshell.execDetached({
      command: [root.omarchyPath + "/bin/omarchy-remove-launcher-entry", id, String(name || id)],
      clearEnvironment: true,
      environment: root.spawnEnvironment
    })
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
    var truncated = false
    var lines = String(rawText || "").split(/\n/)
    for (var i = 0; i < lines.length; i++) {
      if (lines[i] === root.truncationMarker) { truncated = true; continue }
      var id = root.normalizeDesktopId(lines[i])
      if (id.length > 0) next[id] = true
    }
    root.hiddenEntriesTruncated = truncated
    if (truncated) console.warn("Launchpad: hidden-entry scan truncated at " + root.maxHiddenEntryBytes + " bytes")
    root.desktopHiddenEntryIds = next
    root.appsChanged()
  }

  function iconIndexScanCommand() {
    // `head` bounds the producer side so a huge icon tree cannot stream an
    // unbounded amount of output into the parser.
    return [
      'dirs="$HOME/.icons $HOME/.local/share/icons";',
      'IFS=":"; for d in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do dirs="$dirs $d/icons"; done; unset IFS;',
      'for ext in svg png; do',
      '  for base in $dirs; do',
      '    [[ -d $base ]] && find "$base" \\( -path "*/apps/*" -o -path "*/devices/*" \\) -name "*.$ext" 2>/dev/null;',
      '  done;',
      '  find /usr/share/pixmaps -maxdepth 1 -name "*.$ext" 2>/dev/null;',
      'done | head -n ' + root.maxIconIndexEntries
    ].join(' ')
  }

  function indexIconLine(path) {
    var value = String(path || "").trim()
    if (value.length === 0) return
    if (value === root.truncationMarker) {
      root.iconIndexTruncated = true
      console.warn("Launchpad: icon-index scan truncated at " + root.maxIconIndexBytes + " bytes")
      return
    }
    // Producer-side bound: a pathological scan cannot grow the index without
    // limit and exhaust memory in the long-lived shell.
    if (root.pendingIconIndexCount >= root.maxIconIndexEntries) return
    var slash = value.lastIndexOf("/")
    var file = slash >= 0 ? value.slice(slash + 1) : value
    var dot = file.lastIndexOf(".")
    var name = dot > 0 ? file.slice(0, dot) : file
    if (name.length > 0 && root.pendingIconIndex[name] === undefined) {
      root.pendingIconIndex[name] = value
      root.pendingIconIndexCount++
    }
  }

  function hiddenEntryScanCommand() {
    if (!root.omarchyPathValid) return ""
    var desktop = [Quickshell.env("XDG_CURRENT_DESKTOP"), Quickshell.env("XDG_SESSION_DESKTOP"),
      Quickshell.env("DESKTOP_SESSION")].filter(function(v) {
        return String(v || "").length > 0
      }).join(":")
    var script = root.omarchyPath + "/shell/services/hidden-entries.sh"
    return Util.shellQuote(script) + " " + Util.shellQuote(desktop)
  }

  // Wraps a scan command in the bundled guard: the guard caps the raw byte
  // stream before any parser and owns the process group / deadline lifecycle.
  function guardedScanCommand(limitBytes, command) {
    return [root.bashPath, root.scanGuardPath, String(limitBytes), String(root.scanDeadlineMs / 1000),
      String(root.scanKillGraceMs / 1000), root.truncationMarker, command]
  }

  QtObject {
    id: hiddenEntryOutput
    property string text: ""
  }

  // Both scans run under a cleared allowlisted environment with an absolute
  // bash, wrapped by scan-guard.sh: the guard caps the raw producer stream
  // before SplitParser sees it and runs the scan in its own process group, so
  // the deadline TERMs then KILLs the whole tree (not just the direct child)
  // and reaps it. The QML timers below are only a backstop for a wedged guard.
  Process {
    id: hiddenEntryScan
    command: root.guardedScanCommand(root.maxHiddenEntryBytes, root.hiddenEntryScanCommand())
    clearEnvironment: true
    environment: root.spawnEnvironment
    stdout: SplitParser {
      onRead: function(line) {
        hiddenEntryOutput.text += line + "\n"
      }
    }
    onStarted: {
      hiddenEntryOutput.text = ""
      hiddenEntryScanBackstop.restart()
    }
    onExited: {
      hiddenEntryScanBackstop.stop()
      root.loadDesktopHiddenEntries(hiddenEntryOutput.text)
    }
  }

  Timer {
    id: hiddenEntryScanBackstop
    interval: root.scanBackstopMs
    onTriggered: if (hiddenEntryScan.running) hiddenEntryScan.signal(15)
  }

  Process {
    id: iconIndexScan
    command: root.guardedScanCommand(root.maxIconIndexBytes, root.iconIndexScanCommand())
    clearEnvironment: true
    environment: root.spawnEnvironment
    stdout: SplitParser { onRead: function(line) { root.indexIconLine(line) } }
    onStarted: {
      root.pendingIconIndex = ({})
      root.pendingIconIndexCount = 0
      root.iconIndexTruncated = false
      iconIndexScanBackstop.restart()
    }
    onExited: {
      iconIndexScanBackstop.stop()
      root.iconIndex = root.pendingIconIndex
    }
  }

  Timer {
    id: iconIndexScanBackstop
    interval: root.scanBackstopMs
    onTriggered: if (iconIndexScan.running) iconIndexScan.signal(15)
  }

  Timer {
    id: iconIndexDebounce
    interval: 750
    onTriggered: if (!iconIndexScan.running) iconIndexScan.running = true
  }

  FileView {
    path: root.omarchyPathValid ? root.omarchyPath + "/default/omarchy/launcher.hides" : ""
    watchChanges: true
    printErrors: false
    onLoaded: root.loadConfiguredHides(text())
    onFileChanged: root.loadConfiguredHides(text())
    onLoadFailed: root.loadConfiguredHides("")
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() {
      if (root.omarchyPathValid) hiddenEntryScan.running = true
      iconIndexDebounce.restart()
      root.appsChanged()
    }
  }

  Component.onCompleted: {
    if (root.omarchyPathValid) hiddenEntryScan.running = true
    iconIndexScan.running = true
  }
}
