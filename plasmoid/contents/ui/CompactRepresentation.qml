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
        // devialet_icon_currentColor_tray.svg uses fill="currentColor" -
        // confirmed empirically that loading it as a plain file path (no
        // isMask) does NOT get automatic theme recoloring the way a real
        // icon-theme "-symbolic" name would: it rendered as a barely-
        // visible near-black shape on this dark panel (screenshotted and
        // sampled the actual pixel values - not assumed). Kirigami.Icon's
        // isMask+color is the real mechanism for a theme-adaptive
        // monochrome icon (confirmed via its qmltypes: dedicated isMask/
        // color properties exist precisely for this) - treats the SVG's
        // alpha as a mask and fills it with `color`, which is what
        // actually makes a symbolic-style icon follow the panel's
        // light/dark foreground automatically. Kirigami.Theme.textColor
        // is the same color real Plasma panel/tray icons use for this.
        // Trade-off worth knowing: this collapses
        // devialet_icon_filled.svg's two-tone copper shading into a
        // single flat theme color, by design - that's what a symbolic/
        // tray-style icon is.
        isMask: true
        color: Kirigami.Theme.textColor
    }
}
