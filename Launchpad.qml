import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Full-screen application grid, macOS Launchpad / Ubuntu app drawer style.
//
// Data mirrors the Super+Space menu's Apps section. The shell normally injects
// its shared library as shell.appLibrary, but third-party panel/overlay/menu
// plugins currently receive a null appLibrary (the host's Instantiator converts
// the manifest's `kinds` array to a V4Sequence, so its Array.isArray() kind
// check fails). Launchpad therefore prefers shell.appLibrary when present and
// otherwise falls back to LocalAppLibrary.qml, a drop-in replica with the same
// public surface. If upstream fixes the injection, the fallback goes unused
// with no code change needed here.
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

  // ---- app library (official shell.appLibrary, local replica as fallback) --
  // LocalAppLibrary mirrors the official API surface, so the rest of this file
  // calls root.lib.* without caring which one is active.
  LocalAppLibrary { id: localAppLibrary }

  readonly property var lib: (root.shell && root.shell.appLibrary)
    ? root.shell.appLibrary
    : localAppLibrary

  function entryName(entry) {
    return root.lib ? root.lib.entryName(entry) : ""
  }

  function entrySubtext(entry) {
    return root.lib ? root.lib.entrySubtext(entry) : ""
  }

  function sortedEntries(query) {
    return root.lib ? root.lib.sortedEntries(query) : []
  }

  function iconSource(icon) {
    return root.lib ? root.lib.iconSource(icon) : ""
  }

  function refreshIcons() {
    if (root.lib && root.lib.refreshIcons) root.lib.refreshIcons()
  }

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

  // ---- list assembly ------------------------------------------------------
  function launch(desktopId, name) {
    var id = String(desktopId || "")
    if (!id) return
    root.recordLaunch(id)
    if (root.lib && root.lib.launch) root.lib.launch(id, name)
  }

  function remove(desktopId, name) {
    var id = String(desktopId || "")
    if (!id) return
    root.forgetUsage(id)
    if (root.lib && root.lib.remove) root.lib.remove(id, name)
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

  // ---- usage persistence --------------------------------------------------
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

  // The active library reports when the visible app set may have changed; when
  // the official library appears (shell injection lands) we rebuild once.
  Connections {
    target: root.lib
    function onAppsChanged() { root.rebuild() }
  }

  onLibChanged: root.rebuild()

  Component.onCompleted: {
    usageEnsureDir.running = true
    root.rebuild()
  }

  // ---- frosted backdrop ---------------------------------------------------
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
