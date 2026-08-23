// Minimal panel icon: click to open/close the flyout. No status glyph,
// no drag-and-drop - that's what org.kde.kdeconnect's CompactRepresentation
// (the real, shipped reference this pattern was taken from) adds on top for
// its own feature set; not needed here yet. Same structure works whether
// the applet ends up tray-hosted or panel-pinned - this plasmoid is
// panel-pinned (see CLAUDE.md).

pragma ComponentBehavior: Bound

import QtQuick
import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid

MouseArea {
    id: root

    required property PlasmoidItem plasmoidItem

    onClicked: root.plasmoidItem.expanded = !root.plasmoidItem.expanded

    Kirigami.Icon {
        anchors.fill: parent
        source: Plasmoid.icon
    }
}
