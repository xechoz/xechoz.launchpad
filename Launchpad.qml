import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Full-screen application grid, macOS Launchpad / Ubuntu app drawer style.
//
// Data mirrors the Super+Space menu's Apps section: the same desktop-entry
// source, the same fuzzy sort, and the same hidden-entry filtering. The shell
// normally injects that library as shell.appLibrary, but third-party panel
// plugins receive a null appLibrary (the host's Instantiator converts the
// manifest's `kinds` array to a V4Sequence, so its Array.isArray() kind check
// fails). We therefore read DesktopEntries directly and reproduce the shell's
// AppSearch + hidden-entries.sh behaviour locally.
//
// Summon with:
//   omarchy-shell shell toggle xechoz.launchpad '{}'
// Optional payload: { "columns": 7, "recent": 4 }
//
// The first grid row surfaces recently/most launched apps. Launches are
// counted locally while the pad is open and persisted to
// ~/.local/state/omarchy/launchpad-usage.json. `recent` controls how many of
// that row are the newest distinct apps; the row is filled to `columns` with
// the most frequently launched ones. Those apps are not repeated below.
Item {
  id: root

  // ---- plugin lifecycle ---------------------------------------------------
  property bool closingFromHost: false
  // Read by the shell's isPluginOpen() so toggle() knows the real state.
  property bool opened: false

  function open(payloadJson) {
    closingFromHost = false
    var cols = 7
    var recent = -1
    if (payloadJson) {
      try {
        var parsed = JSON.parse(String(payloadJson))
        if (parsed && parsed.columns) cols = Math.max(1, Math.round(parsed.columns))
        if (parsed && parsed.recent !== undefined) recent = Math.max(0, Math.round(parsed.recent))
      } catch (e) { /* ignore */ }
    }
    root.columns = cols
    root.recentCount = recent >= 0 ? Math.min(recent, cols) : Math.ceil(cols / 2)
    root.filterText = ""
    root.rebuild()
    root.refreshIcons()
    root.captureBackground()
  }

  function close() {
    closingFromHost = true
    root.opened = false
    root.bgPending = false
    bgRevealTimer.stop()
    window.visible = false
    closingFromHost = false
  }

  function requestClose() {
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide("xechoz.launchpad")
    else window.visible = false
  }

  // ---- host injections ----------------------------------------------------
  property var shell: null
  property var manifest: null

  // ---- theme --------------------------------------------------------------
  readonly property color foreground: Color.foreground
  readonly property color background: Color.background
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property color scrim: Color.menu.scrim
  readonly property string fontFamily: Style.font.family

  // ---- state --------------------------------------------------------------
  property int columns: 7
  property int recentCount: Math.ceil(root.columns / 2)
  property string filterText: ""
  property var apps: []
  property var deleteTarget: null
  property bool deleteConfirmOpen: false
  // Usage map: { "<desktopId>": { count: int, lastUsed: epochMs } }.
  property var usage: ({})
  property bool favoritesRowFull: false

  // ---- frosted backdrop ---------------------------------------------------
  // Hyprland's layer blur is gated behind the globally-disabled
  // decoration:blur:enabled, so we grab the screen with grim and blur the
  // bitmap ourselves. The window stays hidden until the frame is ready.
  property string bgPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/xechoz-launchpad-bg.png"
  property int bgVersion: 0
  property bool bgPending: false

  function captureBackground() {
    root.bgPending = true
    bgRevealTimer.stop()
    var name = window.screen ? window.screen.name : ""
    bgGrim.command = name ? ["grim", "-o", name, root.bgPath] : ["grim", root.bgPath]
    bgGrim.running = true
    bgRevealTimer.start()
  }

  function revealIfPending() {
    if (!root.bgPending) return
    root.bgPending = false
    bgRevealTimer.stop()
    root.opened = true
    window.visible = true
    Qt.callLater(function() { if (searchField) searchField.forceActiveFocus() })
  }

  // ---- app library (local replica of shell.appLibrary) --------------------
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var configuredHiddenEntryIds: ({})
  property var desktopHiddenEntryIds: ({})
  property var iconIndex: ({})
  property var pendingIconIndex: ({})

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
    root.recordLaunch(id)
    Util.execDetached("uwsm-app -- gtk-launch " + Util.shellQuote(id + ".desktop"))
  }

  function remove(desktopId, name) {
    var id = String(desktopId || "")
    if (!id) return
    root.forgetUsage(id)
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
    root.rebuild()
  }

  function loadDesktopHiddenEntries(rawText) {
    var next = ({})
    var lines = String(rawText || "").split(/\n/)
    for (var i = 0; i < lines.length; i++) {
      var id = root.normalizeDesktopId(lines[i])
      if (id.length > 0) next[id] = true
    }
    root.desktopHiddenEntryIds = next
    root.rebuild()
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

  // ---- usage tracking (recents + frequents) -------------------------------
  function recordLaunch(desktopId) {
    var id = String(desktopId || "")
    if (!id) return
    var next = ({})
    for (var key in root.usage) next[key] = root.usage[key]
    var item = root.usage[id] || { count: 0, lastUsed: 0 }
    next[id] = { count: Number(item.count || 0) + 1, lastUsed: Date.now() }
    root.usage = next
    root.flushUsage()
  }

  function forgetUsage(desktopId) {
    var id = String(desktopId || "")
    if (!id || root.usage[id] === undefined) return
    var next = ({})
    for (var key in root.usage) if (key !== id) next[key] = root.usage[key]
    root.usage = next
    root.flushUsage()
  }

  function loadUsage(rawText) {
    var next = ({})
    try {
      var parsed = JSON.parse(String(rawText || ""))
      var map = parsed && parsed.apps ? parsed.apps : {}
      var cutoff = Date.now() - 90 * 24 * 60 * 60 * 1000
      for (var key in map) {
        var item = map[key] || {}
        var count = Number(item.count || 0)
        var lastUsed = Number(item.lastUsed || 0)
        if (count > 0 && lastUsed >= cutoff) next[key] = { count: count, lastUsed: lastUsed }
      }
    } catch (e) { /* malformed file -> start clean */ }
    root.usage = next
    root.rebuild()
  }

  function flushUsage() {
    var apps = ({})
    for (var key in root.usage) apps[key] = root.usage[key]
    usageFile.setText(JSON.stringify({ version: 1, apps: apps }, null, 2) + "\n")
  }

  // Ordered desktop ids for the first row: the `recentCount` newest distinct
  // apps, then the most frequently launched ones filling up to `columns`.
  function favoriteIds(base) {
    if (root.filterText !== "") return []
    var available = ({})
    for (var i = 0; i < base.length; i++) available[base[i].appId] = base[i]
    var candidates = []
    for (var key in root.usage) {
      if (available[key] === undefined) continue
      candidates.push({ id: key, count: Number(root.usage[key].count || 0),
        lastUsed: Number(root.usage[key].lastUsed || 0) })
    }
    candidates.sort(function(a, b) { return b.lastUsed - a.lastUsed })
    var used = ({})
    var ordered = []
    for (var r = 0; r < candidates.length && ordered.length < root.recentCount; r++) {
      ordered.push(candidates[r].id)
      used[candidates[r].id] = true
    }
    candidates.sort(function(a, b) {
      if (b.count !== a.count) return b.count - a.count
      if (b.lastUsed !== a.lastUsed) return b.lastUsed - a.lastUsed
      var an = String(available[a.id].label || "").toLowerCase()
      var bn = String(available[b.id].label || "").toLowerCase()
      if (an < bn) return -1
      if (an > bn) return 1
      return 0
    })
    for (var f = 0; f < candidates.length && ordered.length < root.columns; f++) {
      if (used[candidates[f].id] === true) continue
      ordered.push(candidates[f].id)
      used[candidates[f].id] = true
    }
    return ordered
  }

  function rebuild() {
    var rows = root.sortedEntries(root.filterText)
    var base = []
    for (var i = 0; i < rows.length; i++) {
      var entry = rows[i].entry
      var id = String(entry.id || "")
      if (!id) continue
      base.push({
        appId: id,
        label: root.entryName(entry),
        subtext: root.entrySubtext(entry),
        icon: String(entry.icon || "")
      })
    }
    var order = root.favoriteIds(base)
    root.favoritesRowFull = order.length >= root.columns
    if (order.length === 0) {
      root.apps = base
      return
    }
    var byId = ({})
    for (var b = 0; b < base.length; b++) byId[base[b].appId] = base[b]
    var out = []
    for (var f = 0; f < order.length; f++) {
      var fav = byId[order[f]]
      if (fav) out.push(fav)
    }
    for (var k = 0; k < base.length; k++) {
      if (order.indexOf(base[k].appId) < 0) out.push(base[k])
    }
    root.apps = out
  }

  function clearFilter() {
    root.filterText = ""
    if (searchField) searchField.text = ""
    root.rebuild()
  }

  function handleEscape() {
    if (root.filterText) root.clearFilter()
    else root.requestClose()
  }

  function launchApp(appId, label) {
    root.launch(appId, label)
    root.requestClose()
  }

  function requestDelete(appId, label) {
    root.deleteTarget = { appId: appId, label: label }
    root.deleteConfirmOpen = true
  }

  function confirmDelete() {
    var target = root.deleteTarget
    root.deleteConfirmOpen = false
    root.deleteTarget = null
    if (target) root.remove(target.appId, target.label)
  }

  function cancelDelete() {
    root.deleteConfirmOpen = false
    root.deleteTarget = null
    Qt.callLater(function() { if (searchField) searchField.forceActiveFocus() })
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

  Process {
    id: usageEnsureDir
    command: ["mkdir", "-p", Quickshell.env("HOME") + "/.local/state/omarchy"]
  }

  FileView {
    id: usageFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/launchpad-usage.json"
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadUsage(text())
    onLoadFailed: root.loadUsage("")
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() {
      hiddenEntryScan.running = true
      iconIndexDebounce.restart()
      root.rebuild()
    }
  }

  Component.onCompleted: {
    usageEnsureDir.running = true
    hiddenEntryScan.running = true
    iconIndexScan.running = true
    root.rebuild()
  }

  Process {
    id: bgGrim
    onExited: function(code) {
      if (code === 0) {
        root.bgVersion++
        bgImage.source = "file://" + root.bgPath + "?v=" + root.bgVersion
      } else {
        root.revealIfPending()
      }
    }
  }

  Timer {
    id: bgRevealTimer
    interval: 500
    repeat: false
    onTriggered: root.revealIfPending()
  }

  Image {
    id: bgImage
    cache: false
    asynchronous: true
    visible: false
    onStatusChanged: {
      if (status === Image.Ready) root.revealIfPending()
    }
  }

  PanelWindow {
    id: window
    visible: false
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "xechoz-launchpad"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    onVisibleChanged: {
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
        root.shell.hide("xechoz.launchpad")
    }

    Rectangle {
      anchors.fill: parent
      color: root.background
    }

    Image {
      id: bgLayer
      anchors.fill: parent
      source: bgImage.source
      fillMode: Image.PreserveAspectCrop
      cache: false
      layer.enabled: true
    }

    MultiEffect {
      anchors.fill: parent
      source: bgLayer
      blurEnabled: true
      blur: 1.0
      blurMax: 64
      opacity: 0
      Behavior on opacity { NumberAnimation { duration: 120 } }
      Component.onCompleted: opacity = 1
    }

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.requestClose()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (root.deleteConfirmOpen) {
          if (deleteConfirm.handleKey(event)) event.accepted = true
          return
        }
        // The panel holds exclusive keyboard focus, so Hyprland never sees the
        // SUPER+A bind while open — close on it here to make the hotkey toggle.
        if ((event.modifiers & Qt.MetaModifier) && event.key === Qt.Key_A) {
          root.requestClose()
          event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
          root.handleEscape()
          event.accepted = true
        }
      }

      Column {
        anchors.fill: parent
        anchors.margins: Style.space(48)
        spacing: Style.space(28)

        TextField {
          id: searchField
          width: Math.min(Style.space(420), parent.width)
          anchors.horizontalCenter: parent.horizontalCenter
          placeholderText: "Search apps…"
          foreground: root.foreground
          accent: root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading

          // The shell's shared TextField resolves its border color through
          // Border.controlSpec, which reads Style.styleOverrides (default
          // token "foreground") and ignores the per-instance accent — see
          // qs/Ui/TextField.qml. Override the background here so the border
          // is pinned to the theme accent instead of dim gray.
          readonly property real accentFill: activeFocus
            ? Style.focusFillAlpha
            : (hovered ? Style.hoverFillAlpha : Style.normalFillAlpha)

          background: BorderSurface {
            color: Util.alpha(root.accent, searchField.accentFill)
            borderSpec: Border.flat(root.accent, Math.max(1, Style.normalBorderWidth))
            radius: Style.cornerRadius
          }

          // The focused TextField swallows Escape before it bubbles to
          // keyCatcher, so intercept it here first.
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
              root.handleEscape()
              event.accepted = true
            }
          }
          onTextChanged: {
            root.filterText = text
            root.rebuild()
          }
        }

        GridView {
          id: grid
          width: parent.width
          height: parent.height - searchField.height - parent.spacing
          clip: true
          cellWidth: Math.floor(width / root.columns)
          cellHeight: Math.round(cellWidth * 0.92)
          model: root.apps
          boundsBehavior: Flickable.StopAtBounds

          delegate: Item {
            id: cell
            required property var modelData
            required property int index
            width: grid.cellWidth
            height: grid.cellHeight

            readonly property bool hot: cellMouse.containsMouse

            Rectangle {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              height: 1
              visible: root.favoritesRowFull && Math.floor(cell.index / root.columns) === 0
              color: Util.alpha(root.foreground, 0.14)
            }

            Rectangle {
              anchors.fill: parent
              anchors.margins: Style.space(6)
              radius: Style.cornerRadius
              color: cell.hot ? Style.hoverFill : "transparent"
            }

            Column {
              anchors.centerIn: parent
              width: parent.width - Style.space(16)
              spacing: Style.space(8)

              Image {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Style.space(56)
                height: Style.space(56)
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                sourceSize.width: width * Screen.devicePixelRatio
                sourceSize.height: height * Screen.devicePixelRatio
                source: root.iconSource(cell.modelData.icon)
              }

              Text {
                width: parent.width
                text: cell.modelData.label
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                maximumLineCount: 2
                wrapMode: Text.Wrap
              }
            }

            MouseArea {
              id: cellMouse
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              onClicked: function(mouse) {
                if (mouse.button === Qt.RightButton)
                  root.requestDelete(cell.modelData.appId, cell.modelData.label)
                else
                  root.launchApp(cell.modelData.appId, cell.modelData.label)
              }
            }
          }
        }
      }
    }

    ConfirmDialog {
      id: deleteConfirm
      anchors.fill: parent
      opened: root.deleteConfirmOpen
      message: root.deleteTarget ? "Uninstall " + root.deleteTarget.label + "?" : ""
      confirmText: "Uninstall"
      cancelText: "Cancel"
      background: root.background
      foreground: root.foreground
      fontFamily: root.fontFamily
      onConfirmed: root.confirmDelete()
      onCanceled: root.cancelDelete()
    }
  }
}
