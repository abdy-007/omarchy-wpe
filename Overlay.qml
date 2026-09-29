import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Centered picker for Wallpaper Engine projects. Everything that touches
// Steam or the renderer process lives in wpe.sh; this file only draws the
// grid and forwards the choice.
Item {
  id: root

  // Injected by omarchy-shell.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: (manifest && manifest.id) || "lbarto12.omarchy-wpe"
  readonly property string scriptPath: decodeURIComponent(String(Qt.resolvedUrl("wpe.sh")).replace(/^file:\/\//, ""))

  property bool opened: false
  property bool loaded: false
  property bool busy: false
  property bool truncated: false
  property string statusText: ""
  property string listError: ""

  // Everything the backend prints lands in this long-lived shell process, so
  // both processes run behind `timeout` and a byte cap (head/tail), with a QML
  // deadline as a backstop in case even the wrapper hangs.
  readonly property int listTimeoutSeconds: 20
  readonly property int maxListBytes: 4194304
  readonly property int actionTimeoutSeconds: 60
  readonly property int maxErrorBytes: 4096
  property string filterText: ""
  property int selectedIndex: 0
  property int targetIndex: 0
  property string preferredTarget: ""
  property var active: ({})
  property var wallpapers: []
  readonly property var filtered: Model.filter(wallpapers, filterText)
  readonly property var targets: {
    var out = ["all"]
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) out.push(screens[i].name)
    return out
  }
  readonly property string target: targets[Math.min(targetIndex, targets.length - 1)] || "all"
  readonly property var current: filtered.length > 0 ? filtered[Math.min(selectedIndex, filtered.length - 1)] : null

  onSelectedIndexChanged: if (!busy) statusText = ""

  // Shares the [menu] surface tokens so themes that style the menu also
  // style this picker, like the built-in emoji overlay.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color accent: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int contentSpacing: Style.spacing.xxl
  property int headerHeight: Math.max(Style.space(34), Style.font.heading + Style.spacing.controlPaddingY * 2)
  property int footerHeight: Style.spacing.controlHeight
  property int cardWidth: Math.min(Style.space(1040), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(720), panel.height - Style.gapsOut * 2)
  property int minTileWidth: Style.space(180)
  property int labelHeight: Style.font.body * 2 + Style.spacing.md

  // Lifecycle hooks called by `omarchy-shell shell summon/hide`. The optional
  // payload {"screen": "DP-1"} preselects which monitor Enter applies to.
  function open(payloadJson) {
    var args = {}
    try { args = JSON.parse(payloadJson || "{}") || {} } catch (e) { args = {} }

    preferredTarget = String(args.screen || "")
    filterText = ""
    statusText = ""
    busy = false
    opened = true
    pointerGate.reset()
    selectTarget(preferredTarget)
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    opened = false
  }

  function dismiss() {
    opened = false
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
  }

  function refresh() {
    if (listProc.running) return
    listProc.output = null
    listProc.code = null
    listProc.running = true
    listDeadline.restart()
  }

  // Output and exit status arrive separately; act once both are in.
  function finishList() {
    if (listProc.output === null || listProc.code === null) return
    listDeadline.stop()
    var code = listProc.code
    var data = code === 0 ? Model.parseList(listProc.output) : null
    listProc.output = null
    listProc.code = null
    loaded = true

    if (!data || !data.ok) {
      listError = Model.listError(code)
      statusText = listError
      return
    }
    listError = ""
    loadList(data)
  }

  function loadList(data) {
    var previousDir = current ? current.dir : ""
    pointerGate.reset()
    active = data.active
    wallpapers = data.wallpapers
    truncated = data.truncated

    var index = Model.indexOfDir(filtered, previousDir)
    if (index < 0) index = Model.indexOfDir(filtered, active[target === "all" ? firstActiveScreen() : target] || "")
    selectedIndex = Math.max(0, index)
    Qt.callLater(function() { if (filtered.length > 0) grid.positionViewAtIndex(selectedIndex, GridView.Contain) })
  }

  function firstActiveScreen() {
    for (var screen in active) return screen
    return ""
  }

  function selectTarget(name) {
    var index = targets.indexOf(name)
    targetIndex = index >= 0 ? index : 0
  }

  function cycleTarget(delta) {
    targetIndex = (targetIndex + delta + targets.length) % targets.length
  }

  function setFilter(text) {
    var previousDir = current ? current.dir : ""
    pointerGate.reset()
    filterText = text
    selectedIndex = Math.max(0, Model.indexOfDir(filtered, previousDir))
    Qt.callLater(function() { if (filtered.length > 0) grid.positionViewAtIndex(selectedIndex, GridView.Contain) })
  }

  function move(delta) {
    if (filtered.length === 0) return
    pointerGate.reset()
    selectedIndex = Math.max(0, Math.min(filtered.length - 1, selectedIndex + delta))
    grid.positionViewAtIndex(selectedIndex, GridView.Contain)
  }

  // The picker opening (or the grid scrolling) under a still pointer counts as
  // hovering a tile. Only real pointer movement may change the selection, or
  // Enter would apply whatever the cursor happened to rest on.
  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    selectedIndex = index
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  function runAction(args, closeOnSuccess) {
    if (busy) return
    busy = true
    statusText = ""
    actionProc.closeOnSuccess = closeOnSuccess
    actionProc.output = null
    actionProc.code = null
    actionProc.command = ["bash", "-c",
      "set -o pipefail; max=$1 secs=$2; shift 2; timeout -k 2 \"$secs\" \"$@\" 2>&1 >/dev/null | tail -c \"$max\"",
      "wpe-action", String(maxErrorBytes), String(actionTimeoutSeconds), scriptPath].concat(args)
    actionProc.running = true
    actionDeadline.restart()
  }

  function finishAction() {
    if (actionProc.output === null || actionProc.code === null) return
    actionDeadline.stop()
    var code = actionProc.code
    var text = actionProc.output
    actionProc.output = null
    actionProc.code = null
    busy = false

    if (code !== 0) statusText = Model.actionError(code, text)
    else if (actionProc.closeOnSuccess) dismiss()
    else refresh()
  }

  function applyIndex(index) {
    if (index < 0 || index >= filtered.length) return
    selectedIndex = index
    if (filtered[index].unsupported) {
      statusText = filtered[index].unsupported
      return
    }
    runAction(["apply", filtered[index].dir, target], true)
  }

  function stopTarget() {
    runAction(["stop", target], false)
  }

  // head -c passes at most one byte past the cap, so an oversized list reaches
  // QML cut off (and fails to parse) instead of whole. pipefail keeps the
  // backend's status: 124 timed out, 3 over the cap, 141 cut off by head.
  Process {
    id: listProc
    property var output: null
    property var code: null
    command: ["bash", "-c", "set -o pipefail; timeout -k 2 \"$1\" \"$2\" list 2>/dev/null | head -c \"$3\"",
      "wpe-list", String(root.listTimeoutSeconds), root.scriptPath, String(root.maxListBytes + 1)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        listProc.output = text
        root.finishList()
      }
    }
    onExited: function(exitCode) {
      listProc.code = exitCode
      root.finishList()
    }
  }

  Timer {
    id: listDeadline
    interval: (root.listTimeoutSeconds + 5) * 1000
    onTriggered: {
      if (!listProc.running) return
      listProc.running = false
      root.loaded = true
      root.listError = Model.listError(124)
      root.statusText = root.listError
    }
  }

  // Only the backend's stderr is kept, and only its last maxErrorBytes; stdout
  // is discarded.
  Process {
    id: actionProc
    property bool closeOnSuccess: false
    property var output: null
    property var code: null
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        actionProc.output = text
        root.finishAction()
      }
    }
    onExited: function(exitCode) {
      actionProc.code = exitCode
      root.finishAction()
    }
  }

  Timer {
    id: actionDeadline
    interval: (root.actionTimeoutSeconds + 5) * 1000
    onTriggered: {
      if (!actionProc.running) return
      actionProc.running = false
      root.busy = false
      root.statusText = Model.actionError(124, "")
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-wpe"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.dismiss()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.applyIndex(root.selectedIndex)
            event.accepted = true
          } else if (event.key === Qt.Key_Tab) {
            root.cycleTarget(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Backtab) {
            root.cycleTarget(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Delete) {
            root.stopTarget()
            event.accepted = true
          } else if (event.key === Qt.Key_Left) {
            root.move(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Right) {
            root.move(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.move(-grid.columns)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.move(grid.columns)
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.move(-grid.columns * grid.visibleRows)
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.move(grid.columns * grid.visibleRows)
            event.accepted = true
          } else if (event.key === Qt.Key_Home) {
            root.move(-root.filtered.length)
            event.accepted = true
          } else if (event.key === Qt.Key_End) {
            root.move(root.filtered.length)
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127
                     && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        // Header: live filter on the left, current selection on the right.
        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: countLabel.left
            anchors.rightMargin: Style.spacing.xxl
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || "Search wallpapers…"
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }

          Text {
            id: countLabel
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.loaded ? root.filtered.length + " / " + root.wallpapers.length + (root.truncated ? "+" : "") : ""
            color: root.foreground
            opacity: 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.footerHeight - root.contentSpacing * 2

          GridView {
            id: grid
            anchors.fill: parent
            clip: true
            model: root.filtered
            boundsBehavior: Flickable.StopAtBounds

            readonly property int columns: Math.max(2, Math.floor(width / root.minTileWidth))
            readonly property int visibleRows: Math.max(1, Math.floor(height / cellHeight))
            cellWidth: Math.floor(width / columns)
            cellHeight: cellWidth - Style.spacing.lg + root.labelHeight

            delegate: Item {
              id: tile
              required property int index
              required property var modelData

              readonly property bool isCurrent: index === root.selectedIndex
              readonly property bool supported: !modelData.unsupported
              readonly property var showingOn: Model.screensShowing(root.active, modelData.dir)
              readonly property string previewUrl: Util.fileUrl(modelData.preview)
              readonly property bool animated: /\.gif$/i.test(modelData.preview || "")

              width: grid.cellWidth
              height: grid.cellHeight

              Rectangle {
                id: frame
                anchors.fill: parent
                anchors.margins: Style.spacing.sm
                radius: root.cornerRadius
                color: tile.isCurrent ? root.selectedBackground : "transparent"
                border.color: tile.isCurrent ? root.accent : "transparent"
                border.width: Math.max(1, Style.space(2))

                Item {
                  id: thumb
                  anchors.top: parent.top
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.margins: Style.spacing.md
                  height: width
                  clip: true
                  opacity: tile.supported ? 1 : 0.35

                  Rectangle {
                    anchors.fill: parent
                    color: Util.alpha(root.foreground, 0.06)
                  }

                  Image {
                    anchors.fill: parent
                    visible: !tile.animated
                    source: tile.animated ? "" : tile.previewUrl
                    sourceSize.width: width
                    sourceSize.height: height
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    smooth: true
                  }

                  // Only the highlighted tile animates; the rest hold their
                  // first frame so a large library stays cheap to scroll.
                  AnimatedImage {
                    anchors.fill: parent
                    visible: tile.animated
                    source: tile.animated ? tile.previewUrl : ""
                    playing: tile.isCurrent && root.opened
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    smooth: true
                  }

                  Rectangle {
                    visible: tile.showingOn.length > 0
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.margins: Style.spacing.md
                    width: activeLabel.implicitWidth + Style.spacing.lg * 2
                    height: activeLabel.implicitHeight + Style.spacing.sm * 2
                    radius: height / 2
                    color: root.accent

                    Text {
                      id: activeLabel
                      textFormat: Text.PlainText
                      anchors.centerIn: parent
                      text: tile.showingOn.join(" · ")
                      color: root.background
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.weight: Font.DemiBold
                    }
                  }

                  Rectangle {
                    anchors.bottom: parent.bottom
                    anchors.right: parent.right
                    anchors.margins: Style.spacing.md
                    width: typeLabel.implicitWidth + Style.spacing.lg * 2
                    height: typeLabel.implicitHeight + Style.spacing.sm * 2
                    radius: height / 2
                    color: Util.alpha(root.background, 0.8)

                    Text {
                      id: typeLabel
                      textFormat: Text.PlainText
                      anchors.centerIn: parent
                      text: tile.supported ? Model.typeLabel(tile.modelData.type) : "Unsupported"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.top: thumb.bottom
                  anchors.left: thumb.left
                  anchors.right: thumb.right
                  anchors.bottom: parent.bottom
                  anchors.topMargin: Style.spacing.sm
                  text: tile.modelData.title
                  color: tile.isCurrent ? root.accent : root.foreground
                  opacity: tile.supported ? 1 : 0.5
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  wrapMode: Text.Wrap
                  maximumLineCount: 2
                  elide: Text.ElideRight
                  horizontalAlignment: Text.AlignHCenter
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPositionChanged: function(mouse) { root.selectFromPointer(tile.index, tile, mouse) }
                onClicked: root.applyIndex(tile.index)
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            width: parent.width * 0.7
            visible: root.filtered.length === 0
            text: !root.loaded ? "Loading wallpapers…"
              : root.listError && root.wallpapers.length === 0 ? root.listError
              : root.filterText ? "No matches for “" + root.filterText + "”"
              : "No Wallpaper Engine projects found.\nInstall Wallpaper Engine in Steam and subscribe to wallpapers on the Workshop."
            color: root.foreground
            opacity: 0.7
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
          }
        }

        // Footer: which monitor(s) Enter applies to, plus key hints.
        Item {
          width: parent.width
          height: root.footerHeight

          Row {
            id: targetRow
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.md

            Repeater {
              model: root.targets

              delegate: Rectangle {
                required property int index
                required property string modelData
                readonly property bool chosen: index === root.targetIndex

                width: chipLabel.implicitWidth + Style.spacing.controlPaddingX * 2
                height: root.footerHeight
                radius: root.cornerRadius
                color: chosen ? root.selectedBackground : "transparent"
                border.color: chosen ? root.accent : Util.alpha(root.foreground, 0.25)
                border.width: 1

                Text {
                  id: chipLabel
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: modelData === "all" ? "All monitors" : modelData
                  color: chosen ? root.accent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.targetIndex = index
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            anchors.left: targetRow.right
            anchors.leftMargin: Style.spacing.xxl
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            readonly property string warning: root.statusText || (root.current && root.current.unsupported) || ""
            text: root.busy ? "Starting wallpaper…"
              : warning || "Enter apply  ·  Tab monitor  ·  Del stop  ·  Esc close"
            color: warning && !root.busy ? Color.urgent : root.foreground
            opacity: warning && !root.busy ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideLeft
          }
        }
      }
    }
  }
}
