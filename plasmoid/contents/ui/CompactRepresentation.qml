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
        // Phase 4.2.5: devialet_icon_glow_dot.svg uses hardcoded copper
        // fill/stroke (not currentColor), unlike the previous
        // devialet_icon_currentColor_tray.svg this replaced - isMask is
        // deliberately off so the SVG's own colors (and the outer ring's
        // opacity, the "glow") render as designed, rather than being
        // collapsed into a flat Kirigami.Theme.textColor mask the way the
        // old currentColor icon needed. Trade-off: this icon no longer
        // adapts to a light panel theme the way a true symbolic/mask icon
        // would - not yet verified against a light Plasma theme.
        isMask: false
    }
}
