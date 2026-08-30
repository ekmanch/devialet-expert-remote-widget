// Phase 2: minimal working skeleton, proving the plasmoid loads as a
// panel-pinned applet and the D-Bus/executable-engine plumbing works
// end-to-end. No visual design from the mockup yet - see CLAUDE.md's
// phased roadmap.
//
// Panel-pinned, not tray-hosted (see CLAUDE.md's "why not a system tray
// plasmoid" note) - PlasmoidItem + compactRepresentation/fullRepresentation
// is the same standard structure either way (confirmed against
// com.github.tilorenz.compact_pager, a real panel-pinnable applet), so
// nothing here needed to change for that switch.

pragma ComponentBehavior: Bound

import QtQuick
import org.kde.plasma.plasmoid

PlasmoidItem {
    id: root

    // Phase 4.11: custom panel icon, replacing the Phase 2 Breeze
    // placeholder. `Plasmoid.icon` accepts an arbitrary resolvable path,
    // not just an icon-theme name - confirmed via a real precedent
    // (org.kde.desktopcontainment's ConfigIcons.qml binds a user-browsed
    // KIconThemes.IconDialog file path straight to Plasmoid.icon/
    // Plasmoid.configuration.icon), not assumed. Bundled the same way
    // Phase 4.0 bundled its fonts (contents/icons/, Qt.resolvedUrl,
    // matching the real luisbocanegra.panel.colorizer precedent of a
    // plasmoid shipping its own contents/icons/ directory) rather than
    // requiring a system/user icon-theme install step.
    //
    // This is the asset CompactRepresentation.qml's Kirigami.Icon actually
    // renders on the panel - the *other* icon reference in this package,
    // metadata.json's KPlugin.Icon (used by the "Add Widgets" list), is a
    // separate, more limited mechanism: KPluginMetaData::iconName()'s own
    // header doc says "\sa QIcon::fromTheme()" - a system icon-theme name
    // only, confirmed by checking a real KPackage precedent
    // (org.kde.plasma.folder's "Icon": "org.kde.plasma.folder" resolves to
    // an actual Breeze-shipped .../breeze/applets/256/org.kde.plasma.
    // folder.svg, not a bundled package file). Getting our own SVG into
    // that list too would mean installing it into the system/user
    // hicolor icon theme - real packaging work that belongs with Phase
    // 4.5's install script, not this self-contained visual change -
    // metadata.json's Icon is left as a real Breeze name (unchanged) so
    // the "Add Widgets" entry stays a valid, if generic, icon rather than
    // silently breaking.
    // Phase 4.2.5: switched to the "Glow Dot" variant
    // (design/icon/A - Glow Dot/devialet_icon_A_filled.svg). Its artwork's
    // own bounding box (outer ring at r=11, stroke-width=2, centered in a
    // 34x34 viewBox) sits 5 units in from each edge - a 14.7% inset,
    // matching the Breeze symbolic-icon convention (~13-14%) measured
    // during Phase 4.1's triangle-icon fix, so no scale/margin correction
    // was needed here. Unlike devialet_icon_currentColor_tray.svg, this
    // artwork uses hardcoded copper fill/stroke (not currentColor) by
    // design - see CompactRepresentation.qml for why isMask is off for
    // this icon.
    Plasmoid.icon: Qt.resolvedUrl("../icons/devialet_icon_glow_dot.svg")

    compactRepresentation: CompactRepresentation {
        plasmoidItem: root
    }

    fullRepresentation: FullRepresentation {}

    // Phase 4.5.0: custom hover content for the panel icon, shown by the
    // shell's own native tooltip dialog (see VolumeHoverTooltip.qml's
    // header comment). Reads live off compactRepresentationItem - the
    // instance CompactRepresentation.qml above becomes once created -
    // rather than FullRepresentation, since only the compact
    // representation is guaranteed to exist when a hover can happen (see
    // CompactRepresentation.qml's header comment on preload timing).
    // Optional chaining here mirrors the real org.kde.plasma.volume
    // applet's own `fullRepresentationItem?.microphoneTestPage` pattern
    // for reaching into a dynamically-typed representation item.
    toolTipItem: VolumeHoverTooltip {
        iconSource: root.compactRepresentationItem?.iconSource ?? ""
        ampName: root.compactRepresentationItem?.tooltipAmpName ?? ""
        volumeDb: root.compactRepresentationItem?.volumeDb
        hasAmp: (root.compactRepresentationItem?.ampIp ?? "") !== ""
    }
}
