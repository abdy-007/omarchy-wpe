import QtQuick
import Quickshell
import Quickshell.Hyprland

// Brings back the last applied wallpaper when the shell starts, and keeps it
// on top of the background layer. wpe.sh leaves monitors that are already
// right alone, so running either command repeatedly is harmless.
Item {
  id: root

  // Injected by omarchy-shell.
  property var shell: null

  readonly property string scriptPath: decodeURIComponent(String(Qt.resolvedUrl("wpe.sh")).replace(/^file:\/\//, ""))

  // Bounded like the overlay's actions so a stuck backend can't pile up.
  function run(command) {
    Quickshell.execDetached(["timeout", "-k", "2", "60", scriptPath, command])
  }

  function restack() {
    run("restack")
  }

  Component.onCompleted: {
    run("restore")
    // The shell's own background may map after this service loads.
    startupRestack.start()
  }

  Timer {
    id: startupRestack
    interval: 2000
    onTriggered: root.restack()
  }

  // Another surface opening on the background layer (Omarchy's background
  // after a shell restart or monitor change) stacks above the wallpaper.
  // Debounced because one restart maps a surface per monitor.
  Timer {
    id: restackDebounce
    interval: 500
    onTriggered: root.restack()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "openlayer" && event.data !== "linux-wallpaperengine")
        restackDebounce.restart()
    }
  }
}
