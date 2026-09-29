import QtQuick
import qs.Commons
import qs.Ui

// Bar button that opens the Wallpaper Engine picker overlay.
BarWidget {
  id: root
  moduleName: "lbarto12.omarchy-wpe"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function openPicker() {
    // The overlay is owned by the shell's panel loader, not the bar, so go
    // through the same summon route a keybinding uses.
    if (root.bar) root.bar.run("omarchy-shell shell toggle lbarto12.omarchy-wpe '{}'")
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\u{f02e9}"
    tooltipText: "Wallpaper Engine"
    onPressed: root.openPicker()
  }
}
