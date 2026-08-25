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
    Plasmoid.icon: Qt.resolvedUrl("../icons/devialet_icon_currentColor_tray.svg")

    compactRepresentation: CompactRepresentation {
        plasmoidItem: root
    }

    fullRepresentation: FullRepresentation {}
}
